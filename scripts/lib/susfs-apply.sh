#!/usr/bin/env bash
#
# susfs integration. Sourced, not executed. Depends on lib/kernel-helpers.sh.
#
# How susfs actually gets in:
#
#   1. The KSU tree must already know about susfs (CONFIG_KSU_SUSFS in its own
#      Kconfig). SukiSU-Ultra's `builtin` branch and ReSukiSU both do.
#   2. Only the KERNEL-TREE patch is applied here
#      (50_add_susfs_in_gki-*.patch), which adds fs/susfs.c and the hooks in
#      fs/, mm/ and security/selinux/.
#   3. CONFIG_KSU_SUSFS=y is set by kernel-helpers.sh.
#
# The KernelSU-side patch (10_enable_susfs_for_ksu.patch) is deliberately NOT
# used. It is cut against whatever SukiSU snapshot the susfs author had, and
# forcing it onto a modern tree silently deletes #include lines and
# declarations that the tree still needs, leaving files that are valid to
# neither side. Trees that ship susfs natively do not need it at all.
#
# NOTE: compile-kernel.sh runs under `set -euo pipefail`.
#

# ---------------------------------------------------------------------------
# PINNED SUSFS REVISION
#
# SUSFS_REF (the branch) comes from resolve-profile.sh and must match the
# kernel version, e.g. gki-android13-5.10.
#
# SUSFS_COMMIT pins the exact revision on that branch. susfs and SukiSU-Ultra
# evolve independently; a branch tip that works today can break tomorrow. This
# commit is the one verified on ingres: susfs v2.2.0, initialising at boot,
# 58 susfs functions live in the running kernel.
#
# Set SUSFS_COMMIT="" to track the branch tip instead.
# ---------------------------------------------------------------------------
SUSFS_COMMIT="${SUSFS_COMMIT-178a43676a6f607ee053ec5aeb2aa7153c273281}"

apply_susfs_task_mmu_fix() {
  local file="fs/proc/task_mmu.c"

  if grep -q 'susfs_def.h' "$file"; then
    echo "[+] task_mmu.c already includes susfs_def.h."
    return 0
  fi

  if grep -q '^#include <linux/pkeys.h>$' "$file"; then
    sed -i '/^#include <linux\/pkeys.h>$/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' "$file"
    echo "[+] Applied fallback susfs include fix to task_mmu.c."
    return 0
  fi

  echo "[-] Could not find a stable insertion point in $file."
  return 1
}

patch_susfs_kernelsu_layout() {
  local file="fs/susfs.c"
  local driver_dir
  local target_include

  [[ -f "$file" ]] || return 0

  driver_dir="$(detect_kernelsu_driver_dir)" || return 0
  target_include="../${driver_dir}/kernelsu/hook/core_hook.h"

  if [[ -f "${driver_dir}/kernelsu/hook/core_hook.h" ]] && [[ ! -f "${driver_dir}/kernelsu/core_hook.h" ]]; then
    sed -i "s|\"\\.\\./drivers/kernelsu/core_hook.h\"|\"${target_include}\"|" "$file"
    echo "[+] Patched susfs core_hook include for nested KernelSU layout."
  fi
}

# Does the KSU tree ship susfs support itself? This is a hard requirement.
ksu_tree_has_native_susfs() {
  local ksu_kernel_dir="$1"
  grep -q 'KSU_SUSFS' "${ksu_kernel_dir}/Kconfig" 2>/dev/null
}

require_native_susfs_support() {
  local ksu_kernel_dir="$1"

  if ksu_tree_has_native_susfs "$ksu_kernel_dir"; then
    echo "[+] KSU tree has native susfs support; only the kernel-tree patch is needed."
    return 0
  fi

  echo "::error::The installed KSU tree has no CONFIG_KSU_SUSFS in its Kconfig,"
  echo "::error::so it does not support susfs natively."
  echo "::error::"
  echo "::error::Forcing susfs4ksu's KernelSU-side patch onto such a tree does"
  echo "::error::not work: it deletes includes and declarations the tree still"
  echo "::error::uses and leaves files that compile as neither version."
  echo "::error::"
  echo "::error::Use a KSU revision that ships susfs (SukiSU-Ultra 'builtin',"
  echo "::error::ReSukiSU 'main') instead."
  exit 1
}

# Check out an exact commit in an already-cloned shallow repo. A stale pin
# warns rather than fails.
pin_susfs_to_commit() {
  local repo_dir="$1"
  local commit="$2"

  [[ -z "$commit" ]] && return 0

  if git -C "$repo_dir" fetch --depth=1 origin "$commit" 2>/dev/null \
     && git -C "$repo_dir" checkout -q FETCH_HEAD 2>/dev/null; then
    echo "[+] susfs4ksu: pinned to ${commit}"
  else
    echo "::warning::susfs4ksu: could not check out pinned commit ${commit};"
    echo "::warning::staying on the branch tip. The build may differ from the"
    echo "::warning::verified configuration."
  fi
}

apply_susfs_full() {
  local susfs_ref="$1"
  local susfs_patch_file="$2"
  local ksu_driver_dir ksu_kernel_dir ksu_repo_dir

  ksu_driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found before applying susfs"
    exit 1
  }
  ksu_kernel_dir="$(readlink -f "${ksu_driver_dir}/kernelsu")"
  ksu_repo_dir="$(dirname "${ksu_kernel_dir}")"

  require_native_susfs_support "$ksu_kernel_dir"

  git clone --depth=1 --no-tags -b "$susfs_ref" \
    https://gitlab.com/simonpunk/susfs4ksu.git susfs
  pin_susfs_to_commit susfs "$SUSFS_COMMIT"

  echo "==== SUSFS SOURCE ===="
  echo "branch: $susfs_ref"
  ( cd susfs && git log -1 --format='commit: %H%ncommit date: %ci' ) || true
  grep -E '^#define SUSFS_VERSION' ./susfs/kernel_patches/include/linux/susfs.h 2>/dev/null || true
  echo "==== KSU SOURCE ===="
  git -C "$ksu_repo_dir" log -1 --format='commit: %H%ncommit date: %ci' 2>/dev/null || true

  (
    cd susfs
    cp "./kernel_patches/${susfs_patch_file}" ..
    cp ./kernel_patches/fs/* ../fs/
    cp ./kernel_patches/include/linux/* ../include/linux/
  )

  mkdir -p "${ksu_kernel_dir}/include/linux"
  cp ./susfs/kernel_patches/include/linux/* "${ksu_kernel_dir}/include/linux/"

  test -f include/linux/susfs_def.h || {
    echo "::error::susfs_def.h was not copied into include/linux from $susfs_ref"
    exit 1
  }

  # ---- kernel-tree patch: fs/, mm/, security/selinux/, kernel/ --------------
  if ! patch -p1 --batch --forward < "${susfs_patch_file}"; then
    echo "[!] susfs kernel-tree patch reported conflicts, checking known drift..."

    local reject_files reject_count
    reject_files="$(find . -name "*.rej" | sort)"
    reject_count="$(printf '%s\n' "$reject_files" | sed '/^$/d' | wc -l)"

    # Known drift: task_mmu.c moved the susfs_def.h include anchor.
    if [[ "$reject_count" -eq 1 ]] && [[ "$reject_files" == "./fs/proc/task_mmu.c.rej" ]] && grep -q 'susfs_def.h' ./fs/proc/task_mmu.c.rej; then
      apply_susfs_task_mmu_fix
      rm -f ./fs/proc/task_mmu.c.rej
      echo "[+] Resolved known susfs task_mmu.c patch drift."
    else
      echo "==== KERNEL-TREE PATCH FAILED ===="
      find . -name "*.rej" -print -exec sh -c 'echo "---- $1 ----"; cat "$1"' _ {} \;
      exit 1
    fi
  fi

  patch_susfs_kernelsu_layout

  export KSU_KERNEL_DIR="$ksu_kernel_dir"
  export KSU_REPO_DIR="$ksu_repo_dir"
}
