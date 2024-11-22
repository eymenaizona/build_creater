#!/bin/bash

# Ensure the script exits on errors
set -e

# Help message
usage() {
    echo "Usage: $0 [-r <repo_links>] [-v <build_file>] [-t <tag_prefix>] [-M <major>] [-m <minor>]"
    echo "  -r: Space-separated list of repository links or paths"
    echo "  -v: Build version file name (default: build_version.txt)"
    echo "  -t: Tag prefix (default: build)"
    echo "  -M: Major version number (default: 1)"
    echo "  -m: Minor version number (default: 0)"
    exit 1
}

# Default values
BUILD_FILE="build_version.txt"
TAG_PREFIX="build"
MAJOR=1
MINOR=0

# Parse options
while getopts ":r:v:t:M:m:" opt; do
  case $opt in
    r) REPOS=$OPTARG ;;
    v) BUILD_FILE=$OPTARG ;;
    t) TAG_PREFIX=$OPTARG ;;
    M) MAJOR=$OPTARG ;;
    m) MINOR=$OPTARG ;;
    *) usage ;;
  esac
done

# Check if repositories are provided
if [ -z "$REPOS" ]; then
    echo "Error: No repositories specified."
    usage
fi

# Function to process each repository
process_repo() {
    REPO=$1
    echo "Processing repository: $REPO"

    # Clone or navigate to the repository
    if [[ "$REPO" == http* ]]; then
        TMP_DIR=$(mktemp -d)
        git clone "$REPO" "$TMP_DIR"
        cd "$TMP_DIR"
    else
        cd "$REPO"
    fi

    # Increment build version
    if [[ -f "$BUILD_FILE" ]]; then
        # Parse the last build number
        LAST_BUILD=$(grep "Version:" "$BUILD_FILE" | tail -n 1 | awk -F'.' '{print $NF}')
        BUILD=${LAST_BUILD:-0}
        NEW_BUILD=$((BUILD + 1))

        # Get the current timestamp and last commit message
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S") # Human-readable format
        LAST_COMMIT_MSG=$(git log -1 --pretty=%B | tr -d '\n')

        # Append the new version log
        echo "Version: ${MAJOR}.${MINOR}.${NEW_BUILD}, Timestamp: $TIMESTAMP, Last Commit: $LAST_COMMIT_MSG" >> "$BUILD_FILE"

        echo "Appended new version log to $BUILD_FILE."
    else
        echo "Error: $BUILD_FILE not found in $REPO!"
        cd - > /dev/null
        return 1
    fi

    # Commit and tag changes
    git add "$BUILD_FILE"
    git commit -m "Increment version to ${MAJOR}.${MINOR}.${NEW_BUILD}"
    TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"
    git tag -a "$TAG" -m "Version ${MAJOR}.${MINOR}.${NEW_BUILD} - $LAST_COMMIT_MSG"
    git push origin main --tags

    # Return to original directory
    cd - > /dev/null
}

# Process each repository
for REPO in $REPOS; do
    process_repo "$REPO"
done

echo "Tagging completed for all repositories."
