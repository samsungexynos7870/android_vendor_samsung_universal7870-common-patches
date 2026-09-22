#!/bin/bash
# Apply patches to Android source tree using repo tool.
# Also can export new commits as patch files to a temporary directory.
# Usage: ./apply_patches.sh [--revert-missing] [--branch BRANCH_NAME] [--export]

set -e

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then MY_DIR="${PWD}"; fi
MY_DIR="$(cd "$MY_DIR" && pwd)"
MANIFEST="$MY_DIR/.patches_applied"
EXPORT_DIR="${TMPDIR:-/tmp}/patches_export_$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

get_repo_root() {
    repo --show-toplevel 2>/dev/null || {
        echo -e "${RED}Error: Not inside a repo client or repo command not found.${NC}" >&2
        exit 1
    }
}

get_project_path() {
    local project="$1"
    local rel_path=$(repo list -p 2>/dev/null | grep -x "$project" | head -1)
    if [ -n "$rel_path" ]; then
        echo "$rel_path"
    else
        echo "$project"
    fi
}

REPO_ROOT=$(get_repo_root 2>/dev/null || echo "")

# Mapping from patch directory (relative to this repo) to repo project path
declare -A PATCH_MAP=(
    ["build/make"]="build/make"
    ["frameworks/av"]="frameworks/av"
    ["frameworks/base"]="frameworks/base"
    ["frameworks/native"]="frameworks/native"
    ["hardware/interfaces"]="hardware/interfaces"
    ["packages/modules/Connectivity"]="packages/modules/Connectivity"
    ["packages/modules/Dns"]="packages/modules/Dns"
    ["packages/modules/DnsResolver"]="packages/modules/DnsResolver"
    ["packages/modules/NetworkStack"]="packages/modules/NetworkStack"
    ["system/bpf"]="system/bpf"
    ["system/core"]="system/core"
    ["system/netd"]="system/netd"
    ["system/security"]="system/security"
)

apply_patch_dir() {
    local patch_dir="$1"
    local project="$2"
    local project_path
    project_path=$(get_project_path "$project")
    local abs_project_path="$REPO_ROOT/$project_path"
    if [ ! -d "$abs_project_path/.git" ]; then
        echo -e "${YELLOW}Warning: Project $project not found at $abs_project_path, skipping${NC}"
        return 0
    fi
    local patch_path="$MY_DIR/$patch_dir"
    if [ ! -d "$patch_path" ]; then
        return 0
    fi
    echo -e "${GREEN}Applying patches for $project from $patch_dir${NC}"
    for patch in "$patch_path"/*.patch; do
        [ -e "$patch" ] || continue
        echo "  Applying $(basename "$patch")"
        (cd "$abs_project_path" && git am --3way --signoff < "$patch") || {
            echo -e "${RED}Failed to apply $patch to $project${NC}"
            echo -e "${YELLOW}Aborting and cleaning up${NC}"
            (cd "$abs_project_path" && git am --abort 2>/dev/null || true)
            exit 1
        }
    done
}

if [[ "$1" == "--export" ]]; then
    mkdir -p "$EXPORT_DIR"
    echo "Exporting patches to $EXPORT_DIR"
    for patch_dir in "${!PATCH_MAP[@]}"; do
        project="${PATCH_MAP[$patch_dir]}"
        project_path=$(get_project_path "$project")
        abs_project_path="$REPO_ROOT/$project_path"
        if [ ! -d "$abs_project_path/.git" ]; then continue; fi
        (cd "$abs_project_path" && git format-patch origin --stdout > "$EXPORT_DIR/${patch_dir//\//_}.patch" 2>/dev/null || true)
    done
    exit 0
fi

for patch_dir in "${!PATCH_MAP[@]}"; do
    apply_patch_dir "$patch_dir" "${PATCH_MAP[$patch_dir]}"
done

echo -e "${GREEN}All patches applied successfully${NC}"
