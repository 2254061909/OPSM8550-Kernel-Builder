#!/usr/bin/env bash
#
# Clone the kernel (and, for non-ingres layouts, the matching -modules repo).
#
set -euo pipefail

: "${KERNEL_REPO:?}"
: "${KERNEL_BRANCH:?}"
: "${KERNEL_CLONE_DIR:?}"
: "${SOURCE_LAYOUT:?}"
: "${SOC:?}"
: "${GITHUB_WORKSPACE:?}"

MODULES_REPO="${MODULES_REPO:-}"
MODULES_CLONE_DIR="${MODULES_CLONE_DIR:-}"

clone_repo() {
  local repo="$1"
  local branch="$2"
  local dest="$3"
  local label="$4"

  echo "[clone] $label -> $repo ($branch) into $dest"
  mkdir -p "$(dirname "$dest")"
  git clone --depth=1 --no-tags -b "$branch" "$repo" "$dest" \
    || { echo "::error::Failed to clone $label for branch '$branch': $repo"; exit 1; }
}

# ingres: single kernel tree, no separate modules repo.
if [[ "$SOURCE_LAYOUT" == "ingres-flat" ]]; then
  clone_repo "$KERNEL_REPO" "$KERNEL_BRANCH" "$KERNEL_CLONE_DIR" "kernel repo"
  echo "[clone] ingres-flat layout: skipping modules repo (defconfig fragments are in-tree)"
  exit 0
fi

# Kick off modules clone in background; kernel clone in foreground.
clone_repo "$MODULES_REPO" "$KERNEL_BRANCH" "$MODULES_CLONE_DIR" "modules repo" &
MODULES_PID=$!

clone_repo "$KERNEL_REPO"  "$KERNEL_BRANCH" "$KERNEL_CLONE_DIR"  "kernel repo"

if ! wait "$MODULES_PID"; then
  echo "::error::Background modules repo clone failed."
  exit 1
fi

if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  rm -rf "${SOC}"
  ln -sfn "${GITHUB_WORKSPACE}/${KERNEL_CLONE_DIR}" "${SOC}"
fi
