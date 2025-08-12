#!/bin/bash

# GitHub App Health Check Script
# Validates GitHub App authentication and repository access

set -euo pipefail

# Source JWT utilities
source /tmp/jwt-utils.sh

echo "=== GitHub App Health Check ==="
echo "Timestamp: $(date)"
echo "Repository: ${GITHUB_REPOSITORY}"
echo "GitHub App ID: ${GITHUB_APP_ID}"

# Health check metrics
HEALTH_STATUS="HEALTHY"
ERROR_COUNT=0
WARNINGS=()

# Function to record error
record_error() {
    local message="$1"
    echo "ERROR: $message" >&2
    HEALTH_STATUS="UNHEALTHY"
    ((ERROR_COUNT++))
}

# Function to record warning
record_warning() {
    local message="$1"
    echo "WARNING: $message" >&2
    WARNINGS+=("$message")
}

# Check 1: Validate environment variables
echo "Checking environment variables..."
if [[ -z "${GITHUB_APP_ID:-}" ]]; then
    record_error "GITHUB_APP_ID environment variable not set"
fi

if [[ -z "${GITHUB_APP_PRIVATE_KEY_SECRET:-}" ]]; then
    record_error "GITHUB_APP_PRIVATE_KEY_SECRET environment variable not set"
fi

if [[ -z "${INSTALLATION_ID_SECRET:-}" ]]; then
    record_error "INSTALLATION_ID_SECRET environment variable not set"
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    record_error "GITHUB_REPOSITORY environment variable not set"
fi

if [[ -z "${PROJECT_ID:-}" ]]; then
    record_error "PROJECT_ID environment variable not set"
fi

# Check 2: Validate secret access
echo "Checking secret accessibility..."
PRIVATE_KEY_FILE="/tmp/health-check-private-key.pem"
trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT

if ! gcloud secrets versions access latest --secret="${GITHUB_APP_PRIVATE_KEY_SECRET}" --project="${PROJECT_ID}" > "$PRIVATE_KEY_FILE" 2>/dev/null; then
    record_error "Failed to access GitHub App private key secret"
else
    if [[ ! -s "$PRIVATE_KEY_FILE" ]]; then
        record_error "GitHub App private key secret is empty"
    elif ! grep -q "BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY" "$PRIVATE_KEY_FILE"; then
        record_error "GitHub App private key secret does not contain valid private key"
    fi
fi

INSTALLATION_ID=""
if ! INSTALLATION_ID=$(gcloud secrets versions access latest --secret="${INSTALLATION_ID_SECRET}" --project="${PROJECT_ID}" 2>/dev/null); then
    record_error "Failed to access installation ID secret"
elif [[ -z "$INSTALLATION_ID" ]]; then
    record_error "Installation ID secret is empty"
elif ! [[ "$INSTALLATION_ID" =~ ^[0-9]+$ ]]; then
    record_error "Installation ID is not a valid number: $INSTALLATION_ID"
fi

# Check 3: JWT Generation
echo "Testing JWT generation..."
if [[ -f "$PRIVATE_KEY_FILE" && -n "$INSTALLATION_ID" ]]; then
    if ! JWT=$(generate_github_app_jwt "${GITHUB_APP_ID}" "$PRIVATE_KEY_FILE" 2>/dev/null); then
        record_error "Failed to generate JWT"
    elif [[ -z "$JWT" ]]; then
        record_error "Generated JWT is empty"
    else
        # Validate JWT format (should have 3 parts separated by dots)
        if [[ $(echo "$JWT" | tr '.' '\n' | wc -l) -ne 3 ]]; then
            record_error "Generated JWT has invalid format"
        fi
    fi
fi

# Check 4: Token Exchange
echo "Testing installation token exchange..."
if [[ -n "${JWT:-}" && -n "$INSTALLATION_ID" ]]; then
    if ! INSTALLATION_TOKEN=$(get_installation_token "$JWT" "$INSTALLATION_ID" 2>/dev/null); then
        record_error "Failed to exchange JWT for installation token"
    elif [[ -z "$INSTALLATION_TOKEN" ]]; then
        record_error "Installation token is empty"
    fi
fi

# Check 5: Repository Access
echo "Testing repository access..."
if [[ -n "${INSTALLATION_TOKEN:-}" ]]; then
    if ! test_github_app_auth "$INSTALLATION_TOKEN" "$GITHUB_REPOSITORY" 2>/dev/null; then
        record_error "Repository access test failed"
    fi
fi

# Check 6: Token Permissions
echo "Testing token permissions..."
if [[ -n "${INSTALLATION_TOKEN:-}" ]]; then
    # Test contents permission
    CONTENTS_RESPONSE=$(curl -s -w "%{http_code}" \
        -H "Authorization: Bearer $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/contents" 2>/dev/null | tail -n1)
    
    if [[ "$CONTENTS_RESPONSE" != "200" ]]; then
        if [[ "$CONTENTS_RESPONSE" == "403" ]]; then
            record_error "Token lacks contents permission"
        elif [[ "$CONTENTS_RESPONSE" == "404" ]]; then
            record_warning "Repository not found or not accessible"
        else
            record_warning "Unexpected response testing contents permission: $CONTENTS_RESPONSE"
        fi
    fi
    
    # Test pull requests permission
    PR_RESPONSE=$(curl -s -w "%{http_code}" \
        -H "Authorization: Bearer $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/pulls?state=open&per_page=1" 2>/dev/null | tail -n1)
    
    if [[ "$PR_RESPONSE" != "200" ]]; then
        if [[ "$PR_RESPONSE" == "403" ]]; then
            record_error "Token lacks pull requests permission"
        else
            record_warning "Unexpected response testing pull requests permission: $PR_RESPONSE"
        fi
    fi
fi

# Check 7: Rate Limiting
echo "Checking API rate limits..."
if [[ -n "${INSTALLATION_TOKEN:-}" ]]; then
    RATE_LIMIT_RESPONSE=$(curl -s \
        -H "Authorization: Bearer $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/rate_limit" 2>/dev/null)
    
    if echo "$RATE_LIMIT_RESPONSE" | grep -q '"rate"'; then
        REMAINING=$(echo "$RATE_LIMIT_RESPONSE" | grep -o '"remaining": *[0-9]*' | head -1 | cut -d':' -f2 | tr -d ' ')
        LIMIT=$(echo "$RATE_LIMIT_RESPONSE" | grep -o '"limit": *[0-9]*' | head -1 | cut -d':' -f2 | tr -d ' ')
        
        if [[ -n "$REMAINING" && -n "$LIMIT" ]]; then
            echo "Rate limit: $REMAINING/$LIMIT remaining"
            
            # Warn if rate limit is getting low
            if [[ "$REMAINING" -lt 100 ]]; then
                record_warning "Rate limit is low: $REMAINING/$LIMIT remaining"
            fi
        fi
    fi
fi

# Summary
echo ""
echo "=== Health Check Summary ==="
echo "Status: $HEALTH_STATUS"
echo "Errors: $ERROR_COUNT"
echo "Warnings: ${#WARNINGS[@]}"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo "Warning details:"
    for warning in "${WARNINGS[@]}"; do
        echo "  - $warning"
    done
fi

# Generate metrics for monitoring (Cloud Logging format)
cat <<EOF

=== Monitoring Metrics ===
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "repository": "$GITHUB_REPOSITORY",
  "github_app_id": "$GITHUB_APP_ID",
  "health_status": "$HEALTH_STATUS",
  "error_count": $ERROR_COUNT,
  "warning_count": ${#WARNINGS[@]},
  "check_duration_seconds": $SECONDS
}
EOF

# Exit with error if unhealthy
if [[ "$HEALTH_STATUS" == "UNHEALTHY" ]]; then
    exit 1
fi

echo "Health check completed successfully"