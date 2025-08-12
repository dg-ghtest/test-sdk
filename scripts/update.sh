#!/bin/bash

set -euo pipefail

# GitHub PR Automation Demo Script with GitHub App Authentication
# This script creates a timestamp update PR to demonstrate end-to-end automation capabilities
# In production, replace this logic with actual business requirements

echo "=== GitHub PR Automation Script ==="
echo "Project ID: ${PROJECT_ID}"
echo "GitHub App ID: ${GITHUB_APP_ID}"
echo "Repository: ${GITHUB_REPOSITORY}"
echo "Timestamp: $(date)"

# Copy utility scripts to workspace and source them
# In the inline trigger context, scripts are in the cloned repository
cp ./scripts/jwt-utils.sh /tmp/jwt-utils.sh
cp ./scripts/installation-helper.sh /tmp/installation-helper.sh
source /tmp/jwt-utils.sh

# Create temporary files for secrets
PRIVATE_KEY_FILE="/tmp/github-app-private-key.pem"
trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT

echo "Retrieving GitHub App private key from Secret Manager..."
gcloud secrets versions access latest --secret="${GITHUB_APP_PRIVATE_KEY_SECRET}" --project="${PROJECT_ID}" > "$PRIVATE_KEY_FILE"

if [[ ! -s "$PRIVATE_KEY_FILE" ]]; then
    echo "ERROR: Failed to retrieve GitHub App private key!"
    exit 1
fi

echo "Retrieving installation ID from Secret Manager..."
INSTALLATION_ID=$(gcloud secrets versions access latest --secret="${INSTALLATION_ID_SECRET}" --project="${PROJECT_ID}" 2>/dev/null || echo "")

if [[ -z "$INSTALLATION_ID" ]]; then
    echo "Installation ID not found in Secret Manager. Discovering automatically..."
    
    # Use installation helper to find the installation ID for this repository
    source /tmp/installation-helper.sh
    INSTALLATION_ID=$(find_installation_for_repository "${GITHUB_APP_ID}" "$PRIVATE_KEY_FILE" "$GITHUB_REPOSITORY")
    
    if [[ $? -ne 0 || -z "$INSTALLATION_ID" ]]; then
        echo "ERROR: Failed to discover installation ID for repository ${GITHUB_REPOSITORY}!"
        echo "Make sure the GitHub App is installed on this repository."
        exit 1
    fi
    
    echo "Discovered installation ID: ${INSTALLATION_ID}"
    echo "Storing installation ID in Secret Manager for future use..."
    echo -n "$INSTALLATION_ID" | gcloud secrets versions add "${INSTALLATION_ID_SECRET}" --data-file=- --project="${PROJECT_ID}"
    
    if [[ $? -eq 0 ]]; then
        echo "Successfully stored installation ID in Secret Manager."
    else
        echo "WARNING: Failed to store installation ID in Secret Manager. Will rediscover next time."
    fi
else
    echo "Installation ID retrieved from Secret Manager: ${INSTALLATION_ID}"
fi

echo "Generating GitHub App authentication token..."
GITHUB_TOKEN=$(authenticate_github_app "${GITHUB_APP_ID}" "$PRIVATE_KEY_FILE" "$INSTALLATION_ID")

if [[ $? -ne 0 || -z "$GITHUB_TOKEN" ]]; then
    echo "ERROR: Failed to authenticate with GitHub App!"
    exit 1
fi

TOKEN_LENGTH=${#GITHUB_TOKEN}
echo "GitHub App token retrieved successfully (length: ${TOKEN_LENGTH} characters, expires in 1 hour)"

# Test the token by validating repository access
echo "Testing repository access..."
if ! test_github_app_auth "$GITHUB_TOKEN" "$GITHUB_REPOSITORY"; then
    echo "ERROR: Repository access test failed!"
    exit 1
fi

# Generate timestamp for display and branch naming
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Create Git-safe branch name with randomization to avoid collisions
BRANCH_TIMESTAMP=$(date -u +"%Y-%m-%d-%H-%M-%S")
RANDOM_SUFFIX=$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $RANDOM)
BRANCH_NAME="timestamp-update-${BRANCH_TIMESTAMP}-${RANDOM_SUFFIX}"

# Extract repo name from the current directory or environment
REPO_NAME=$(basename "${PWD}")
echo "Repository: ${REPO_NAME}"

# Get the default branch (usually main or master)
DEFAULT_BRANCH=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}" | \
  grep -o '"default_branch": *"[^"]*"' | \
  sed 's/"default_branch": *"\([^"]*\)"/\1/')

echo "Default branch: ${DEFAULT_BRANCH}"

# Configure git
git config --global user.name "SDK Automation"
git config --global user.email "sdk-automation@company.com"
git config --global init.defaultBranch main

# Clone the repository
echo "Cloning repository..."
git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" repo
cd repo

# Check for existing open PRs and close them
echo "Checking for existing timestamp update PRs..."
EXISTING_PRS=$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls?state=open" | \
  grep -A 5 -B 5 '"title".*timestamp update' | \
  grep -o '"number": *[0-9]*' | sed 's/"number": *//' || true)

if [[ -n "${EXISTING_PRS}" ]]; then
    echo "Found existing timestamp update PRs, closing them..."
    for PR_NUMBER in ${EXISTING_PRS}; do
        echo "Closing PR #${PR_NUMBER}..."
        curl -X PATCH \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github.v3+json" \
          "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
          -d '{"state": "closed"}'
        echo "Closed PR #${PR_NUMBER}"
    done
fi

echo "Creating new branch for fresh PR: ${BRANCH_NAME}"

# Delete the remote branch if it exists (cleanup from failed previous runs)
git push origin ":${BRANCH_NAME}" 2>/dev/null || true

git checkout -b "${BRANCH_NAME}"

# Create or update timestamp.txt file with both template change time and PR creation time
echo "Updating timestamp file..."
TEMPLATE_CHANGE_TIME="2025-08-12T16:30:00Z"  # Time when template schedule was changed from 5 minutes to 1 hour
cat > timestamp.txt << EOF
Template changed: ${TEMPLATE_CHANGE_TIME}
PR created: ${TIMESTAMP}
EOF

# Add and commit the changes
git add timestamp.txt
git commit -m "Update timestamp - Template changed: ${TEMPLATE_CHANGE_TIME}, PR created: ${TIMESTAMP}"

# Push the branch
echo "Pushing branch ${BRANCH_NAME}..."
# Configure git to use the token for push operations
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
git push origin "${BRANCH_NAME}"

# Create new PR (always, since we closed any existing ones)
echo "Creating new PR..."
PR_TITLE="Automated timestamp update for ${REPO_NAME}"
PR_BODY="Automated timestamp update for ${REPO_NAME} - ${TIMESTAMP}"

curl -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
  -d "{
    \"title\": \"${PR_TITLE}\",
    \"body\": \"${PR_BODY}\",
    \"head\": \"${BRANCH_NAME}\",
    \"base\": \"${DEFAULT_BRANCH}\"
  }"

echo "PR created successfully"

# Cleanup
cd ..
rm -rf repo
rm -f /workspace/token.txt
echo "GitHub PR automation completed successfully"
echo "=== Script finished ==="