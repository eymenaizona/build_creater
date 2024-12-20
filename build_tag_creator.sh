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

# Function to get the latest tag
get_latest_git_tag() {
    local TAG_PREFIX=$1
    local LATEST_TAG=$(git tag --list "${TAG_PREFIX}-*" | sort -V | tail -n 1)
    echo "$LATEST_TAG"
}

# Function to sync repository with remote
sync_with_remote() {
    local BRANCH=$1
    git fetch origin
    if git diff-index --quiet HEAD --; then
        git reset --hard "origin/$BRANCH"
    else
        git stash
        git reset --hard "origin/$BRANCH"
        git stash pop || true
    fi
}

# Function to ensure build file exists
ensure_build_file() {
    local BUILD_FILE=$1
    if [ ! -f "$BUILD_FILE" ]; then
        echo "Creating $BUILD_FILE"
        touch "$BUILD_FILE"
        git add "$BUILD_FILE"
        git commit -m "Initialize $BUILD_FILE"
    fi
}

# Function to update git submodules
update_submodules() {
    local repo_path=$1
    if [ -f "$repo_path/.gitmodules" ]; then
        echo "Updating submodules in $repo_path"
        cd "$repo_path"
        git submodule update --init --remote --rebase

        # Sync each submodule with its remote
        git submodule foreach '
            if git rev-parse --verify origin/main >/dev/null 2>&1; then
                git checkout main
                git fetch origin
                git reset --hard origin/main
            elif git rev-parse --verify origin/master >/dev/null 2>&1; then
                git checkout master
                git fetch origin
                git reset --hard origin/master
            fi
        '
        cd -
    else
        echo "No submodules found in $repo_path"
    fi
}

# Determine initial version based on inputs or existing tags
if [[ -z "$(git tag --list "${TAG_PREFIX}-*")" ]]; then
    if [[ -n "$MAJOR" && -n "$MINOR" ]]; then
        VERSION="${MAJOR}.${MINOR}.0"
        echo "No tags found. Using provided version: $VERSION"
    else
        VERSION="1.0.0"
        echo "No tags found. Using default version: $VERSION"
    fi
else
    LATEST_TAG=$(get_latest_git_tag "$TAG_PREFIX")
    MAJOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f1)
    MINOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f2)
    BUILD=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f3)
    BUILD=$((BUILD + 1))
    VERSION="${MAJOR}.${MINOR}.${BUILD}"
    echo "Latest tag found: $LATEST_TAG. Incrementing to: $VERSION"
fi

# Function to find next available tag version
find_next_tag_version() {
    local TAG_PREFIX=$1
    local MAJOR=$2
    local MINOR=$3
    local BASE_BUILD=$4

    local NEW_BUILD=$BASE_BUILD
    local TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"

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

    if git show-ref --tags --verify --quiet "refs/tags/$TARGET_TAG"; then
        echo "Reverting $REPO to tag $TARGET_TAG"
        git checkout "$TARGET_TAG"
    else
        echo "Tag $TARGET_TAG not found in $REPO. Skipping revert."
    fi
}

# Function to update submodule versions
update_submodule_versions() {
    local VERSION=$1
    local BUILD_FILE=$2
    local TAG=$3

    ensure_build_file "$BUILD_FILE"
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$TIMESTAMP, $VERSION" >> "$BUILD_FILE"
    git add "$BUILD_FILE"
    git commit -m "Increment version to $VERSION"
    git tag -f "$TAG"
    git push origin HEAD --force
    git push origin "$TAG" --force
}

# Function to process each repository
process_repo() {
    local REPO=$1
    echo "Processing repository: $REPO"

    if [[ "$REPO" == http* ]]; then
        TMP_DIR=$(mktemp -d)
        git clone "$REPO" "$TMP_DIR"
        cd "$TMP_DIR"
    else
        cd "$REPO"
    fi

    # Update and sync submodules first
    update_submodules "."

    # Revert to the specified tag, if provided
    if [ -n "$REVERT_TO_TAG" ]; then
        revert_to_tag "$REPO" "$REVERT_TO_TAG"
        return 1
    fi

    # Switch to main branch if available
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if git branch -a | grep -q "remotes/origin/main"; then
        BRANCH="main"
        if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
            git checkout "$BRANCH"
            sync_with_remote "$BRANCH"
            echo "Switched to branch: $BRANCH"
        fi
    else
        echo "No 'main' branch found. Staying on the current branch: $CURRENT_BRANCH"
    fi

    # Ensure build file exists and increment version
    ensure_build_file "$BUILD_FILE"

    if [[ -f "$BUILD_FILE" ]]; then
        LAST_BUILD=$(grep "Version:" "$BUILD_FILE" | tail -n 1 | awk -F'.' '{print $NF}'| tr -cd '0-9')
        BUILD=${LAST_BUILD:-0}
        NEW_BUILD=$(find_next_tag_version "$TAG_PREFIX" "$MAJOR" "$MINOR" "$BUILD")
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        echo "$TIMESTAMP, ${MAJOR}.${MINOR}.${NEW_BUILD}" >> "$BUILD_FILE"
        echo "Appended new version log to $BUILD_FILE."
        TAG="${TAG_PREFIX}-${MAJOR}.${MINOR}.${NEW_BUILD}"

        # Update versions in submodules
        if [ -f ".gitmodules" ]; then
            git submodule foreach "$(declare -f update_submodule_versions); update_submodule_versions '${MAJOR}.${MINOR}.${NEW_BUILD}' '$BUILD_FILE' '$TAG'"
        fi

        # Commit and tag changes in main repository
        git add "$BUILD_FILE"
        git commit -m "Increment version to ${MAJOR}.${MINOR}.${NEW_BUILD}"
        git tag "$TAG"


        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if ! git push origin "$CURRENT_BRANCH"; then
            echo "Failed to push changes to remote branch $CURRENT_BRANCH"
            exit 1
        fi
        if ! git push origin "$TAG"; then
            echo "Failed to push tag $TAG to remote"
            exit 1
        fi
    else
        echo "Error: $BUILD_FILE not found in $REPO!"
        cd -
        return 1
    fi

    cd -
}

# Process each repository
for REPO in $REPOS; do
    process_repo "$REPO"
done

echo "Tagging completed for all repositories."