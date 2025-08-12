#!/bin/bash

# GitHub App Installation ID Discovery Helper
# This script helps discover installation IDs for repositories

set -euo pipefail

# Source JWT utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/jwt-utils.sh"

# List all GitHub App installations
list_installations() {
    local app_id="$1"
    local private_key_path="$2"
    
    echo "Generating JWT for GitHub App ID: $app_id" >&2
    local jwt=$(generate_github_app_jwt "$app_id" "$private_key_path")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to generate JWT" >&2
        return 1
    fi
    
    echo "Fetching GitHub App installations..." >&2
    
    # Get all installations for this GitHub App
    local response=$(curl -s \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: SDK-Automation/1.0" \
        "https://api.github.com/app/installations")
    
    # Check for errors
    if echo "$response" | grep -q '"message"'; then
        echo "ERROR: GitHub API error: $(echo "$response" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)" >&2
        return 1
    fi
    
    echo "$response"
}

# Get installation details for a specific installation ID
get_installation_details() {
    local app_id="$1"
    local private_key_path="$2"
    local installation_id="$3"
    
    echo "Generating JWT for GitHub App ID: $app_id" >&2
    local jwt=$(generate_github_app_jwt "$app_id" "$private_key_path")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to generate JWT" >&2
        return 1
    fi
    
    echo "Fetching installation details for ID: $installation_id" >&2
    
    # Get specific installation details
    local response=$(curl -s \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: SDK-Automation/1.0" \
        "https://api.github.com/app/installations/$installation_id")
    
    # Check for errors
    if echo "$response" | grep -q '"message"'; then
        echo "ERROR: GitHub API error: $(echo "$response" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)" >&2
        return 1
    fi
    
    echo "$response"
}

# Get repositories accessible to a specific installation
get_installation_repositories() {
    local app_id="$1"
    local private_key_path="$2"
    local installation_id="$3"
    
    echo "Getting installation token for ID: $installation_id" >&2
    local token=$(authenticate_github_app "$app_id" "$private_key_path" "$installation_id")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to get installation token" >&2
        return 1
    fi
    
    echo "Fetching repositories for installation ID: $installation_id" >&2
    
    # Get repositories accessible to this installation
    local response=$(curl -s \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: SDK-Automation/1.0" \
        "https://api.github.com/installation/repositories")
    
    # Check for errors
    if echo "$response" | grep -q '"message"'; then
        echo "ERROR: GitHub API error: $(echo "$response" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)" >&2
        return 1
    fi
    
    echo "$response"
}

# Find installation ID for a specific repository
find_installation_for_repository() {
    local app_id="$1"
    local private_key_path="$2"
    local target_repo="$3"  # Format: "owner/repo"
    
    echo "Searching for installation ID for repository: $target_repo" >&2
    
    # Get all installations
    local installations=$(list_installations "$app_id" "$private_key_path")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to list installations" >&2
        return 1
    fi
    
    # Extract installation IDs from the response
    local installation_ids=$(echo "$installations" | grep -o '"id": *[0-9]*' | cut -d':' -f2 | tr -d ' ')
    
    if [[ -z "$installation_ids" ]]; then
        echo "ERROR: No installations found for this GitHub App" >&2
        return 1
    fi
    
    # Check each installation for the target repository
    for installation_id in $installation_ids; do
        echo "Checking installation ID: $installation_id" >&2
        
        local repos=$(get_installation_repositories "$app_id" "$private_key_path" "$installation_id" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            # Check if target repository is in this installation's repositories
            if echo "$repos" | grep -q "\"full_name\": *\"$target_repo\""; then
                echo "Found installation ID $installation_id for repository $target_repo" >&2
                echo "$installation_id"
                return 0
            fi
        fi
    done
    
    echo "ERROR: Repository $target_repo not found in any installation" >&2
    return 1
}

# Print human-readable summary of all installations
print_installation_summary() {
    local app_id="$1"
    local private_key_path="$2"
    
    echo "=== GitHub App Installation Summary ===" >&2
    echo "App ID: $app_id" >&2
    echo "" >&2
    
    # Get all installations
    local installations=$(list_installations "$app_id" "$private_key_path")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to list installations" >&2
        return 1
    fi
    
    # Extract installation IDs
    local installation_ids=$(echo "$installations" | grep -o '"id": *[0-9]*' | cut -d':' -f2 | tr -d ' ')
    
    if [[ -z "$installation_ids" ]]; then
        echo "No installations found for this GitHub App" >&2
        return 1
    fi
    
    # Print details for each installation
    for installation_id in $installation_ids; do
        echo "Installation ID: $installation_id" >&2
        
        local repos=$(get_installation_repositories "$app_id" "$private_key_path" "$installation_id" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            local repo_names=$(echo "$repos" | grep -o '"full_name": *"[^"]*"' | cut -d'"' -f4)
            echo "  Repositories:" >&2
            for repo in $repo_names; do
                echo "    - $repo" >&2
            done
        else
            echo "  Failed to fetch repositories" >&2
        fi
        
        echo "" >&2
    done
}

# Generate secret creation commands for found repositories
generate_secret_commands() {
    local app_id="$1"
    local private_key_path="$2"
    local project_id="$3"
    local target_repos="$4"  # Space-separated list like "python-sdk go-sdk"
    
    echo "=== Secret Creation Commands ===" >&2
    echo "" >&2
    
    for repo in $target_repos; do
        # Try to find installation ID for this repository
        local full_repo_name
        if [[ "$repo" == *"/"* ]]; then
            full_repo_name="$repo"
        else
            # Assume same owner as in environment
            full_repo_name="${GITHUB_OWNER:-}/$repo"
        fi
        
        if [[ -z "${GITHUB_OWNER:-}" && "$repo" != *"/"* ]]; then
            echo "WARNING: GITHUB_OWNER not set and repository '$repo' doesn't include owner" >&2
            continue
        fi
        
        local installation_id=$(find_installation_for_repository "$app_id" "$private_key_path" "$full_repo_name" 2>/dev/null)
        
        if [[ $? -eq 0 && -n "$installation_id" ]]; then
            echo "# $full_repo_name (Installation ID: $installation_id)"
            echo "echo -n \"$installation_id\" | gcloud secrets versions add ${repo}-installation-id --data-file=- --project=$project_id"
            echo ""
        else
            echo "# ERROR: Could not find installation ID for $full_repo_name" >&2
            echo ""
        fi
    done
}

# Test if a GitHub App private key is working
test_key() {
    local app_id="$1"
    local private_key_path="$2"
    
    echo "Testing GitHub App private key..." >&2
    echo "App ID: $app_id" >&2
    
    # Check if private key file exists
    if [[ ! -f "$private_key_path" ]]; then
        echo "ERROR: Private key file not found: $private_key_path" >&2
        return 1
    fi
    
    # Verify it's a valid PEM file
    if ! grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" "$private_key_path"; then
        echo "ERROR: File does not appear to be a valid private key" >&2
        return 1
    fi
    
    # Try to generate a JWT
    echo "Generating JWT..." >&2
    local jwt=$(generate_github_app_jwt "$app_id" "$private_key_path" 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$jwt" ]]; then
        echo "ERROR: Failed to generate JWT. Check app ID and private key." >&2
        return 1
    fi
    
    # Try to list installations
    echo "Testing GitHub API access..." >&2
    local response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/app/installations")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    case "$http_code" in
        "200")
            local count=$(echo "$body" | grep -c '"id":' || echo "0")
            echo "✅ SUCCESS: Key is valid and working!" >&2
            echo "   Found $count installation(s)" >&2
            return 0
            ;;
        "401")
            echo "❌ ERROR: Authentication failed (401)" >&2
            echo "   The private key may be invalid or revoked" >&2
            return 1
            ;;
        "403")
            echo "❌ ERROR: Access forbidden (403)" >&2
            echo "   Check if the GitHub App is properly configured" >&2
            return 1
            ;;
        *)
            echo "❌ ERROR: Unexpected response (HTTP $http_code)" >&2
            echo "   Response: $body" >&2
            return 1
            ;;
    esac
}

# Main function for command-line usage
main() {
    local command="$1"
    shift
    
    case "$command" in
        "list")
            if [[ $# -ne 2 ]]; then
                echo "Usage: $0 list <app_id> <private_key_path>" >&2
                exit 1
            fi
            list_installations "$1" "$2"
            ;;
        "summary")
            if [[ $# -ne 2 ]]; then
                echo "Usage: $0 summary <app_id> <private_key_path>" >&2
                exit 1
            fi
            print_installation_summary "$1" "$2"
            ;;
        "find")
            if [[ $# -ne 3 ]]; then
                echo "Usage: $0 find <app_id> <private_key_path> <owner/repo>" >&2
                exit 1
            fi
            find_installation_for_repository "$1" "$2" "$3"
            ;;
        "generate-secrets")
            if [[ $# -ne 4 ]]; then
                echo "Usage: $0 generate-secrets <app_id> <private_key_path> <project_id> '<repo1 repo2 repo3>'" >&2
                exit 1
            fi
            generate_secret_commands "$1" "$2" "$3" "$4"
            ;;
        "test-key")
            if [[ $# -ne 2 ]]; then
                echo "Usage: $0 test-key <app_id> <private_key_path>" >&2
                exit 1
            fi
            test_key "$1" "$2"
            ;;
        *)
            echo "Usage: $0 {list|summary|find|generate-secrets|test-key} [args...]" >&2
            echo "" >&2
            echo "Commands:" >&2
            echo "  list <app_id> <private_key_path>                     - List all installations" >&2
            echo "  summary <app_id> <private_key_path>                  - Print installation summary" >&2
            echo "  find <app_id> <private_key_path> <owner/repo>        - Find installation ID for repository" >&2
            echo "  generate-secrets <app_id> <private_key_path> <project_id> '<repos>' - Generate secret commands" >&2
            echo "  test-key <app_id> <private_key_path>                 - Test if private key is working" >&2
            exit 1
            ;;
    esac
}

# Run main function if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        main "summary" 
    else
        main "$@"
    fi
fi