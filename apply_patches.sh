#!/bin/bash
# Apply LineageOS 24.0 platform patches for Samsung Exynos 7870 (universal7870-common).
# Invoked automatically by device/samsung/universal7870-common/vendorsetup.sh
# or manually from anywhere inside the Android repo tree:
#   ./vendor/samsung/universal7870-common-patches/apply_patches.sh [--revert] [--export]

set -e

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then MY_DIR="${PWD}"; fi
MY_DIR="$(cd "$MY_DIR" && pwd)"
EXPORT_DIR="${TMPDIR:-/tmp}/patches_export_$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

find_repo_root() {
    if command -v repo >/dev/null 2>&1; then
        local root
        root=$(repo --show-toplevel 2>/dev/null || true)
        if [[ -n "$root" ]]; then
            echo "$root"
            return 0
        fi
    fi
    # Fallback: walk up from MY_DIR or PWD looking for .repo or build/envsetup.sh
    local dir="$PWD"
    for candidate in "$PWD" "$(cd "$MY_DIR/../../.." 2>/dev/null && pwd)"; do
        [[ -n "$candidate" ]] || continue
        dir="$candidate"
        while [[ "$dir" != "/" ]]; do
            if [[ -d "$dir/.repo" ]] || [[ -f "$dir/build/make/core/main.mk" ]]; then
                echo "$dir"
                return 0
            fi
            dir=$(dirname "$dir")
        done
    done
    echo -e "${RED}Error: Could not locate Android repo root.${NC}" >&2
    exit 1
}

get_project_path() {
    local project="$1"
    if command -v repo >/dev/null 2>&1; then
        local rel_path
        rel_path=$(repo list -p 2>/dev/null | grep -x "$project" | head -1 || true)
        if [[ -n "$rel_path" ]]; then
            echo "$rel_path"
            return 0
        fi
    fi
    echo "$project"
}

REPO_ROOT=$(find_repo_root)

# Patch directory (relative to this repo) -> Android source path
PATCH_DIRS=(
    "bionic"
    "build/soong"
    "vendor/lineage"
    "packages/modules/Bluetooth"
)

extract_subject() {
    python3 - "$1" << 'PY'
import email, re, sys
with open(sys.argv[1], "rb") as f:
    msg = email.message_from_binary_file(f)
subj = msg.get("Subject", "")
subj = " ".join(subj.splitlines())
subj = re.sub(r"^\[PATCH[^\]]*\]\s*", "", subj).strip()
print(subj)
PY
}

apply_patch_dir() {
    local patch_dir="$1"
    local project_path
    project_path=$(get_project_path "$patch_dir")
    local abs_project_path="$REPO_ROOT/$project_path"

    if [[ ! -d "$abs_project_path/.git" ]] && [[ ! -f "$abs_project_path/.git" ]]; then
        echo -e "${YELLOW}Warning: Project $patch_dir not found at $abs_project_path, skipping${NC}"
        return 0
    fi

    local patch_path="$MY_DIR/$patch_dir"
    [[ -d "$patch_path" ]] || return 0

    echo -e "${GREEN}Checking patches for $patch_dir${NC}"
    for patch in "$patch_path"/*.patch; do
        [[ -e "$patch" ]] || continue
        local bn subj
        bn=$(basename "$patch")
        subj=$(extract_subject "$patch")

        # Skip if commit subject is already present in recent history (idempotent re-runs)
        if [[ -n "$subj" ]] && git -C "$abs_project_path" log -n 30 --format=%s | grep -Fqx "$subj"; then
            echo -e "  ${YELLOW}[SKIP] Already applied: $bn${NC}"
            continue
        fi

        echo "  Applying $bn"
        if ! (cd "$abs_project_path" && git am --3way --signoff < "$patch"); then
            echo -e "${RED}Failed to apply $patch to $patch_dir${NC}"
            (cd "$abs_project_path" && git am --abort 2>/dev/null || true)
            exit 1
        fi
    done
}

if [[ "${1:-}" == "--export" ]]; then
    mkdir -p "$EXPORT_DIR"
    echo "Exporting patches to $EXPORT_DIR"
    for patch_dir in "${PATCH_DIRS[@]}"; do
        project_path=$(get_project_path "$patch_dir")
        abs_project_path="$REPO_ROOT/$project_path"
        [[ -e "$abs_project_path/.git" ]] || continue
        (cd "$abs_project_path" && git format-patch origin --stdout > "$EXPORT_DIR/${patch_dir//\//_}.patch" 2>/dev/null || true)
    done
    exit 0
fi

if [[ "${1:-}" == "--revert" ]]; then
    for patch_dir in "${PATCH_DIRS[@]}"; do
        project_path=$(get_project_path "$patch_dir")
        abs_project_path="$REPO_ROOT/$project_path"
        [[ -e "$abs_project_path/.git" ]] || continue
        echo -e "${YELLOW}Reverting $patch_dir via git am --abort / repo sync...${NC}"
        (cd "$abs_project_path" && git am --abort 2>/dev/null || true)
        if command -v repo >/dev/null 2>&1; then
            (cd "$REPO_ROOT" && repo sync -d "$project_path")
        fi
    done
    exit 0
fi

for patch_dir in "${PATCH_DIRS[@]}"; do
    apply_patch_dir "$patch_dir"
done

echo -e "${GREEN}All universal7870-common LineageOS 24.0 patches applied successfully.${NC}"
