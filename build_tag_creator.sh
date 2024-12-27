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
    git fetch --tags
    local LATEST_TAG=$(git tag --list "${TAG_PREFIX}-*" | sort -V | tail -n 1)
    echo "$LATEST_TAG"
}

parse_version_from_tag() {
    local TAG=$1
    if [[ -n "$TAG" ]]; then
        echo "$TAG" | sed -n "s/^${TAG_PREFIX}-\([0-9]\+\)\.\([0-9]\+\)\.\([0-9]\+\)$/\1 \2 \3/p"
    fi
}


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
# Function to revert to a specific tag
revert_to_tag() {
    local REPO=$1
    local TARGET_TAG=$2

    if git show-ref --tags --verify --quiet "refs/tags/$TARGET_TAG"; then
        echo "Reverting $REPO to tag $TARGET_TAG"
        git checkout "$TARGET_TAG"
        if [ -f ".gitmodules" ]; then
            echo "Reverting direct submodules to tag $TARGET_TAG"
            # Initialize submodules if they haven't been initialized
            git submodule init
            # For each direct submodule, checkout the same tag
            git submodule foreach "
                echo 'Processing submodule: \$name';
                if git show-ref --tags --verify --quiet 'refs/tags/$TARGET_TAG'; then
                    git checkout '$TARGET_TAG';
                    echo 'Successfully reverted \$name to tag $TARGET_TAG';
                else
                    echo 'Warning: Tag $TARGET_TAG not found in submodule \$name';
                fi
            "
            # Verify final status
            echo "Final submodule status:"
            git submodule status
        fi
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
    echo "$TIMESTAMP, $TAG, $USER, $CURRENT_BRANCH" >> "$BUILD_FILE"
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

    # Switch to the current branch and sync with remote
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git checkout "$CURRENT_BRANCH"
    sync_with_remote "$CURRENT_BRANCH"
    echo "Staying on the current branch: $CURRENT_BRANCH"
    # Determine version after entering the repository
    LATEST_TAG=$(get_latest_git_tag "$TAG_PREFIX")
    if [[ -n "$LATEST_TAG" ]]; then
        if [[ -n "$MAJOR" && -n "$MINOR" ]]; then
            TAG_MAJOR=$MAJOR
            TAG_MINOR=$MINOR
            BASE_BUILD=0
        else
            TAG_MAJOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f1)
            TAG_MINOR=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f2)
            BASE_BUILD=$(echo "$LATEST_TAG" | cut -d'-' -f2 | cut -d. -f3)
        fi
    else
        TAG_MAJOR=${MAJOR:-1}
        TAG_MINOR=${MINOR:-0}
        BASE_BUILD=0
    fi

    # Find the next available build number
    NEW_BUILD=$(find_next_tag_version "$TAG_PREFIX" "$TAG_MAJOR" "$TAG_MINOR" "$BASE_BUILD")
    VERSION="${TAG_MAJOR}.${TAG_MINOR}.${NEW_BUILD}"
    echo "Using version: $VERSION"
    TAG="${TAG_PREFIX}-${VERSION}"

    # Ensure build file exists and increment version
    ensure_build_file "$BUILD_FILE"

    if [[ -f "$BUILD_FILE" ]]; then
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        USER=$(pwd -P)
        echo "$TIMESTAMP, $TAG, $USER, $CURRENT_BRANCH" >> "$BUILD_FILE"
        echo "Appended new version log to $BUILD_FILE."

        # Update versions in submodules
        if [ -f ".gitmodules" ]; then
            git submodule foreach "$(declare -f update_submodule_versions); update_submodule_versions '${TAG_MAJOR}.${TAG_MINOR}.${NEW_BUILD}' '$BUILD_FILE' '$TAG'"
        fi

        # Commit and tag changes in main repository
        git add "$BUILD_FILE"
        git commit -m "Increment version to ${TAG_MAJOR}.${TAG_MINOR}.${NEW_BUILD}"
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