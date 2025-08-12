#!/bin/bash

# JWT Generation Utilities for GitHub App Authentication
# Requires: openssl, base64, date

set -euo pipefail

# Generate base64url encoded string (URL-safe base64 without padding)
base64url_encode() {
    local input="$1"
    echo -n "$input" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# Create JWT for GitHub App authentication
generate_github_app_jwt() {
    local app_id="$1"
    local private_key_path="$2"
    
    # Validate inputs
    if [[ -z "$app_id" ]]; then
        echo "ERROR: GitHub App ID is required" >&2
        return 1
    fi
    
    if [[ ! -f "$private_key_path" ]]; then
        echo "ERROR: Private key file not found: $private_key_path" >&2
        return 1
    fi
    
    # JWT header
    local header=$(cat <<EOF
{
  "alg": "RS256",
  "typ": "JWT"
}
EOF
)
    
    # JWT payload with timestamps
    local now=$(date +%s)
    local exp=$((now + 600))  # 10 minutes expiry (GitHub max)
    local iat=$((now - 60))   # 1 minute ago to handle clock skew
    
    local payload=$(cat <<EOF
{
  "iat": $iat,
  "exp": $exp,
  "iss": "$app_id"
}
EOF
)
    
    # Encode header and payload
    local encoded_header=$(base64url_encode "$header")
    local encoded_payload=$(base64url_encode "$payload")
    
    # Create signature
    local signature_input="${encoded_header}.${encoded_payload}"
    local signature=$(echo -n "$signature_input" | \
        openssl dgst -sha256 -sign "$private_key_path" | \
        openssl base64 -A | \
        tr '+/' '-_' | \
        tr -d '=')
    
    # Combine to create JWT
    local jwt="${encoded_header}.${encoded_payload}.${signature}"
    echo "$jwt"
}

# Exchange JWT for installation access token
get_installation_token() {
    local jwt="$1"
    local installation_id="$2"
    
    if [[ -z "$jwt" ]]; then
        echo "ERROR: JWT is required" >&2
        return 1
    fi
    
    if [[ -z "$installation_id" ]]; then
        echo "ERROR: Installation ID is required" >&2
        return 1
    fi
    
    # Make API call to get installation token
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: SDK-Automation/1.0" \
        "https://api.github.com/app/installations/$installation_id/access_tokens")
    
    # Check for errors
    if echo "$response" | grep -q '"message"'; then
        echo "ERROR: GitHub API error: $(echo "$response" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)" >&2
        return 1
    fi
    
    # Extract token from response
    local token=$(echo "$response" | grep -o '"token": *"[^"]*"' | cut -d'"' -f4)
    
    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to extract token from GitHub API response" >&2
        return 1
    fi
    
    echo "$token"
}

# Complete authentication flow: JWT generation + token exchange
authenticate_github_app() {
    local app_id="$1"
    local private_key_path="$2" 
    local installation_id="$3"
    
    echo "Generating JWT for GitHub App ID: $app_id" >&2
    local jwt=$(generate_github_app_jwt "$app_id" "$private_key_path")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to generate JWT" >&2
        return 1
    fi
    
    echo "Exchanging JWT for installation token (Installation ID: $installation_id)" >&2
    local token=$(get_installation_token "$jwt" "$installation_id")
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to get installation token" >&2
        return 1
    fi
    
    echo "$token"
}

# Test GitHub App authentication
test_github_app_auth() {
    local token="$1"
    local repo_full_name="$2"  # e.g., "owner/repo"
    
    if [[ -z "$token" ]]; then
        echo "ERROR: Token is required for testing" >&2
        return 1
    fi
    
    if [[ -z "$repo_full_name" ]]; then
        echo "ERROR: Repository full name is required for testing" >&2
        return 1
    fi
    
    echo "Testing GitHub App authentication for repository: $repo_full_name" >&2
    
    # Test API access by getting repository information
    local response=$(curl -s \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "User-Agent: SDK-Automation/1.0" \
        "https://api.github.com/repos/$repo_full_name")
    
    # Check for errors
    if echo "$response" | grep -q '"message"'; then
        echo "ERROR: API test failed: $(echo "$response" | grep -o '"message": *"[^"]*"' | cut -d'"' -f4)" >&2
        return 1
    fi
    
    # Check if we got repository data
    if echo "$response" | grep -q '"full_name"'; then
        echo "SUCCESS: GitHub App authentication test passed" >&2
        return 0
    else
        echo "ERROR: Unexpected API response format" >&2
        return 1
    fi
}