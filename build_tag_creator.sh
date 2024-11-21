#!/bin/bash

# Ensure the script exits on errors
set -e

# Help message
usage() {
    echo "Usage: $0 [-r <repo_links>] [-v <build_file>] [-t <tag_prefix>]"
    echo "  -r: Space-separated list of repository links or paths"
    echo "  -v: Build version file name (default: build_version.txt)"
    echo "  -t: Tag prefix (default: build)"
    exit 1
}

# Default values
BUILD_FILE="build_version.txt"
TAG_PREFIX="build"

# Parse options
while getopts ":r:v:t:" opt; do
  case $opt in
    r) REPOS=$OPTARG ;;
    v) BUILD_FILE=$OPTARG ;;
    t) TAG_PREFIX=$OPTARG ;;
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
        VERSION=$(cat "$BUILD_FILE")
        NEW_VERSION=$((VERSION + 1))
        echo $NEW_VERSION > "$BUILD_FILE"
        echo "Build version incremented to $NEW_VERSION in $REPO."
    else
        echo "Error: $BUILD_FILE not found in $REPO!"
        cd - > /dev/null
        return 1
    fi

    # Commit and tag changes
    git add "$BUILD_FILE"
    git commit -m "Increment build version to $NEW_VERSION"
    TAG="${TAG_PREFIX}-${NEW_VERSION}"
    git tag -a "$TAG" -m "Build version $NEW_VERSION"
    git push origin main --tags

    # Return to original directory
    cd - > /dev/null
}

# Process each repository
for REPO in $REPOS; do
    process_repo "$REPO"
done

echo "Tagging completed for all repositories."
