#!/bin/bash
# Ensure the script exits on errors
set -e

# Help message
usage() {
    echo "Usage: $0 [-r <repo_links>] [-v <build_file>] [-t <tag_prefix>] [-M <major>] [-m <minor>] [-r <revert_to_tag>]"
    echo " -r: Space-separated list of repository links or paths"
    echo " -v: Build version file name (default: build_version.txt)"
    echo " -t: Tag prefix (default: build)"
    echo " -M: Major version number (default: 1)"
    echo " -m: Minor version number (default: 0)"
    echo " -R: Revert to a specific tag (e.g., 'release-2.1.5')"
    exit 1
}

# Default values
BUILD_FILE="build_version.txt"
TAG_PREFIX="build"
MAJOR=1
MINOR=0
REVERT_TO_TAG=""

# Parse options
while getopts ":r:v:t:M:m:R:" opt; do
    case $opt in
    r) REPOS=$OPTARG ;;
    v) BUILD_FILE=$OPTARG ;;
    t) TAG_PREFIX=$OPTARG ;;
    M) MAJOR=$OPTARG ;;
    m) MINOR=$OPTARG ;;
    R) REVERT_TO_TAG=$OPTARG ;;
    *) usage ;;
    esac
done

# Check if repositories are provided
if [ -z "$REPOS" ]; then
    echo "Error: No repositories specified."
    usage
    exit
fi

# Function to update git submodules
update_submodules() {
    local repo_path=$1
    # Check if .gitmodules exists
    if [ -f "$repo_path/.gitmodules" ]; then
        echo "Updating submodules in $repo_path"
        cd "$repo_path"
        # Update submodules
        git submodule update --init --remote --rebase
        # Pull latest changes for submodules
        cd -
    else
        echo "No submodules found in $repo_path"
    fi
}
# Function to get the latest tag
get_latest_git_tag() {
    local TAG_PREFIX=$1

    # Find the latest tag matching the prefix
    local LATEST_TAG=$(git tag --list "${TAG_PREFIX}-*" | sort -V | tail -n 1)
    echo "$LATEST_TAG"
}

# Parse the latest tag
LATEST_TAG=$(get_latest_git_tag "$TAG_PREFIX")

if [[ -n "$LATEST_TAG" ]]; then
    # Extract version numbers from the tag
    MAJOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f1)
    MINOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f2)
    BUILD=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f3)
    BUILD=$((BUILD + 1)) # Increment the build number
else
    # No existing tags, start with default
    MAJOR=1
    MINOR=0
    BUILD=0
fi

echo "Tagging with version: ${MAJOR}.${MINOR}.${BUILD}"
TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${BUILD}"

# Function to find next available tag version
find_next_tag_version() {
    local TAG_PREFIX=$1
    local MAJOR=$2
    local MINOR=$3
    local BASE_BUILD=$4

    local NEW_BUILD=$BASE_BUILD
    local TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"

    # Keep incrementing build number until we find an unused tag
    while git tag | grep -q "^$TAG$"; do
        NEW_BUILD=$((NEW_BUILD + 1))
        TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"
    done

    echo "$NEW_BUILD"
}

# Function to revert to a specific tag
revert_to_tag() {
    local REPO=$1
    local TARGET_TAG=$2

    # Check if the target tag exists
    if git show-ref --tags --verify --quiet "refs/tags/$TARGET_TAG"; then
        echo "Reverting $REPO to tag $TARGET_TAG"
        git checkout "$TARGET_TAG"
    else
        echo "Tag $TARGET_TAG not found in $REPO. Skipping revert."
    fi
}

# Function to process each repository
process_repo() {
    local REPO=$1
    echo "Processing repository: $REPO"

    # Clone or navigate to the repository  delete git clone
    if [[ "$REPO" == http* ]]; then
        TMP_DIR=$(mktemp -d)
        git clone "$REPO" "$TMP_DIR"
        cd "$TMP_DIR"
    else
        cd "$REPO"
    fi

    # Attempt to update submodules first
    update_submodules "."

    # Revert to the specified tag, if provided
    if [ -n "$REVERT_TO_TAG" ]; then
        revert_to_tag "$REPO" "$REVERT_TO_TAG"
        return 1
    fi
    # change to develop branch
    # Attempt to checkout `main` branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if git branch -a | grep -q "remotes/origin/main"; then
        BRANCH="main"

        # Only switch branches if not already on main
        if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
            git checkout "$BRANCH"
            echo "Switched to branch: $BRANCH"
        fi
    else
        echo "No 'main' branch found. Staying on the current branch: $CURRENT_BRANCH"
    fi

    # Increment build version
    if [[ -f "$BUILD_FILE" ]]; then
        # debug here
        # Parse the last build number
        LAST_BUILD=$(grep "Version:" "$BUILD_FILE" | tail -n 1 | awk -F'.' '{print $NF}'| tr -cd '0-9')
        BUILD=${LAST_BUILD:-0}

        # Find next available build number
        NEW_BUILD=$(find_next_tag_version "$TAG_PREFIX" "$MAJOR" "$MINOR" "$BUILD")

        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S") # Human-readable format

        # Append the new version log
        echo "$TIMESTAMP, ${MAJOR}.${MINOR}.${NEW_BUILD}" >> "$BUILD_FILE"
        echo "Appended new version log to $BUILD_FILE."
        # Prepare tag
        TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"
    else
        echo "Error: $BUILD_FILE not found in $REPO!"
        cd -
        return 1
    fi

    # Commit and tag changes
    git add "$BUILD_FILE"
    git commit -m "Increment version to ${MAJOR}.${MINOR}.${NEW_BUILD}"

    echo "Creating tag: $TAG" # Debug output
    if [ -n "$TAG" ]; then
        # Create tag
        git tag "$TAG"

        # Push tag
        if ! git push origin "$TAG"; then
            echo "Failed to push tag $TAG to remote"
            exit 1
        fi
    else
        echo "Error: Tag name is empty"
        exit 1
    fi

    # Return to original directory
    cd -
}

# Process each repository
for REPO in $REPOS; do
    process_repo "$REPO"
done

echo "Tagging completed for all repositories."