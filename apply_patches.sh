#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Apply patches to Android source tree using repo tool.
# Also can export new commits as patch files to a temporary directory.
#
# Usage: ./apply_patches.sh [--revert-missing] [--branch BRANCH_NAME] [--export]

set -e

# ---------- Configuration ----------
MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then MY_DIR="${PWD}"; fi
MY_DIR="$(cd "$MY_DIR" && pwd)"
MANIFEST="$MY_DIR/.patches_applied"
EXPORT_DIR="${TMPDIR:-/tmp}/patches_export_$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------- Helper Functions ----------

# Find repo root
get_repo_root() {
    repo --show-toplevel 2>/dev/null || {
        echo -e "${RED}Error: Not inside a repo client or repo command not found.${NC}" >&2
        exit 1
    }
}

# Get absolute path of a project given its relative path (e.g., frameworks/base)
get_project_path() {
    local project="$1"
    # Try to find the project in repo manifest by exact relative path
    local rel_path=$(repo list -p 2>/dev/null | grep -x "$project" | head -1)
    if [[ -n "$rel_path" ]]; then
        echo "$ANDROID_ROOT/$rel_path"
    elif [[ -d "$ANDROID_ROOT/$project" ]]; then
        # Fallback: the directory exists even if not tracked by repo
        echo "$ANDROID_ROOT/$project"
    else
        return 1
    fi
}

# Check if a commit exists in the current git repo
commit_exists() {
    local commit_hash="$1"
    git cat-file -t "$commit_hash" 2>/dev/null | grep -q "commit"
}

# Apply a single patch and record it
apply_patch() {
    local project="$1"
    local patch_file="$2"
    local patch_name=$(basename "$patch_file")

    echo -e "  Applying $patch_name ..."
    if git am --signoff "$patch_file"; then
        local commit_hash=$(git rev-parse HEAD)
        echo -e "  ${GREEN}Applied as $commit_hash${NC}"
        echo "$project|$patch_name|$commit_hash" >> "$MANIFEST"
    else
        echo -e "  ${RED}Failed to apply $patch_name. Aborting.${NC}"
        git am --abort
        return 1
    fi
    return 0
}

# Revert a previously applied patch
revert_patch() {
    local project="$1"
    local patch_name="$2"
    local commit_hash="$3"
    local project_path=$(get_project_path "$project")

    if [[ -z "$project_path" || ! -d "$project_path" ]]; then
        echo -e "${YELLOW}Warning: Project $project no longer exists. Skipping revert of $patch_name.${NC}"
        return 0
    fi

    cd "$project_path"
    if ! commit_exists "$commit_hash"; then
        echo -e "${YELLOW}  Commit $commit_hash not found in $project. Removing from manifest.${NC}"
        cd - >/dev/null
        return 0
    fi

    echo -e "  Reverting $patch_name ($commit_hash) in $project ..."
    if git revert --no-edit "$commit_hash"; then
        echo -e "  ${GREEN}Reverted successfully.${NC}"
        cd - >/dev/null
    else
        echo -e "  ${RED}Failed to revert $commit_hash. Manual intervention required.${NC}"
        cd - >/dev/null
        return 1
    fi
    return 0
}

# Export new commits (not in manifest) as patch files to a temporary directory
export_new_commits() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo -e "${YELLOW}No manifest found. Cannot determine which commits are new.${NC}"
        return 0
    fi

    mkdir -p "$EXPORT_DIR"
    echo -e "${GREEN}Exporting new commits to $EXPORT_DIR${NC}"

    # Build a map of the latest recorded commit per project
    declare -A last_commits
    while IFS='|' read -r project patch_name commit_hash; do
        # Keep the last commit for each project (assuming manifest is in order)
        last_commits["$project"]="$commit_hash"
    done < <(sort -t '|' -k1,1 -k3,3 "$MANIFEST" | uniq)

    for project in "${!last_commits[@]}"; do
        local last_commit="${last_commits[$project]}"
        local project_path=$(get_project_path "$project")

        if [[ -z "$project_path" || ! -d "$project_path" ]]; then
            echo -e "${YELLOW}Warning: Project $project not found. Skipping export.${NC}"
            continue
        fi

        cd "$project_path"
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning: $project_path is not a git repo. Skipping.${NC}"
            cd - >/dev/null
            continue
        fi

        if ! commit_exists "$last_commit"; then
            echo -e "${YELLOW}Warning: Last commit $last_commit for $project not found. Skipping export.${NC}"
            cd - >/dev/null
            continue
        fi

        # Get new commits after last recorded commit
        local new_commits=$(git rev-list --reverse "$last_commit..HEAD" 2>/dev/null)
        if [[ -z "$new_commits" ]]; then
            echo -e "${GREEN}No new commits in $project.${NC}"
            cd - >/dev/null
            continue
        fi

        local count=0
        for commit in $new_commits; do
            count=$((count+1))
            local patch_dir="$EXPORT_DIR/$project"
            mkdir -p "$patch_dir"
            git format-patch -1 "$commit" --stdout > "$patch_dir/$(printf "%04d" $count)-$(git show -s --format=%f $commit).patch"
            echo -e "  Exported $commit to $patch_dir"
        done

        cd - >/dev/null
    done

    echo -e "${GREEN}Export completed. Patches saved in $EXPORT_DIR${NC}"
}

# Process all patches in a directory (apply new ones)
process_patch_dir() {
    local rel_path="$1"   # e.g., "frameworks/base"
    local project_path=$(get_project_path "$rel_path")

    if [[ -z "$project_path" ]]; then
        echo -e "${YELLOW}Warning: Project $rel_path not found in repo manifest or filesystem. Skipping.${NC}"
        return 0
    fi

    echo -e "${GREEN}Processing $rel_path ($project_path)${NC}"
    cd "$project_path"

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: $project_path is not a git repository. Skipping.${NC}"
        cd - >/dev/null
        return 0
    fi

    # Optional: start a branch if --branch was given
    if [[ -n "$BRANCH" ]]; then
        if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
            repo start "$BRANCH" . || {
                echo -e "${YELLOW}Could not create branch $BRANCH in $rel_path. Continuing anyway.${NC}"
            }
        fi
    fi

    # Gather patches, sorted naturally
    local patches=($(ls "$MY_DIR/$rel_path"/*.patch 2>/dev/null | sort -V))
    if [[ ${#patches[@]} -eq 0 ]]; then
        cd - >/dev/null
        return 0
    fi

    for patch_file in "${patches[@]}"; do
        local patch_name=$(basename "$patch_file")
        echo -e "Checking $patch_name ..."

        local commit_hash=$(head -1 "$patch_file" | cut -d' ' -f2)
        if [[ -z "$commit_hash" ]]; then
            echo -e "${YELLOW}  Could not extract commit hash. Applying blindly.${NC}"
        else
            if commit_exists "$commit_hash"; then
                echo -e "  ${GREEN}Commit $commit_hash already present. Skipping.${NC}"
                continue
            fi
        fi

        apply_patch "$rel_path" "$patch_file" || {
            cd - >/dev/null
            exit 1
        }
    done

    cd - >/dev/null
}

# Revert patches whose files are missing
revert_missing_patches() {
    if [[ ! -f "$MANIFEST" ]]; then
        echo -e "${YELLOW}No manifest found. Nothing to revert.${NC}"
        return 0
    fi

    local tmp_manifest=$(mktemp)
    local any_failure=0

    while IFS='|' read -r project patch_name commit_hash; do
        patch_file="$MY_DIR/$project/$patch_name"
        if [[ ! -f "$patch_file" ]]; then
            echo -e "${YELLOW}Missing patch: $patch_name in $project${NC}"
            if ! revert_patch "$project" "$patch_name" "$commit_hash"; then
                any_failure=1
                # Keep entry for retry
                echo "$project|$patch_name|$commit_hash" >> "$tmp_manifest"
            fi
        else
            echo "$project|$patch_name|$commit_hash" >> "$tmp_manifest"
        fi
    done < "$MANIFEST"

    mv "$tmp_manifest" "$MANIFEST"
    return $any_failure
}

# ---------- Main ----------
cd "$MY_DIR"

# Parse arguments
REVERT_MISSING=false
EXPORT=false
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --revert-missing)
            REVERT_MISSING=true
            shift
            ;;
        --export)
            EXPORT=true
            shift
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Usage: $0 [--revert-missing] [--branch BRANCH_NAME] [--export]"
            exit 1
            ;;
    esac
done

# Find repo root
ANDROID_ROOT="$(get_repo_root)"
echo -e "${GREEN}Repo root: $ANDROID_ROOT${NC}"

# If export requested, do it and exit
if $EXPORT; then
    export_new_commits
    exit 0
fi

# If revert requested, do it first
if $REVERT_MISSING; then
    echo -e "${GREEN}Reverting missing patches...${NC}"
    revert_missing_patches || {
        echo -e "${RED}Some reverts failed. Please resolve manually.${NC}"
        exit 1
    }
fi

# Recursively find all directories containing .patch files, and extract unique relative paths
PATCH_DIRS=()
while IFS= read -r dir; do
    # Remove leading "./" to get the relative path
    rel="${dir#./}"
    PATCH_DIRS+=("$rel")
done < <(find . -name "*.patch" -printf "%h\n" | sort -u)

if [[ ${#PATCH_DIRS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No patch directories found. Exiting.${NC}"
    exit 0
fi

echo -e "${GREEN}Found patch directories: ${PATCH_DIRS[*]}${NC}"

# Apply patches in each directory
for rel_path in "${PATCH_DIRS[@]}"; do
    process_patch_dir "$rel_path"
done

echo -e "${GREEN}All patches processed.${NC}"