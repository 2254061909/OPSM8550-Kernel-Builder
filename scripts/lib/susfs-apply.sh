#!/usr/bin/env bash
#
# susfs patching helpers and the end-to-end apply routine. Sourced, not
# executed. Depends on lib/kernel-helpers.sh.
#

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

# Restore the KSU worktree to pristine HEAD. Essential between patch attempts:
# a half-applied patch leaves files that are valid to neither side, and the next
# strategy would then be operating on garbage.
reset_ksu_tree() {
  local ksu_repo_dir="$1"
  git -C "$ksu_repo_dir" checkout -- . 2>/dev/null || true
  git -C "$ksu_repo_dir" clean -fd 2>/dev/null || true
  find "$ksu_repo_dir" -name '*.rej' -delete 2>/dev/null || true
  find "$ksu_repo_dir" -name '*.orig' -delete 2>/dev/null || true
}

# Any conflict markers left behind mean the merge did not actually resolve.
assert_no_conflict_markers() {
  local dir="$1"
  local hits
  hits="$(grep -rlE '^(<<<<<<<|>>>>>>>) ' "$dir" --include='*.c' --include='*.h' 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    echo "::error::Conflict markers left in the KernelSU tree after merging:"
    printf '%s\n' "$hits"
    local f
    printf '%s\n' "$hits" | while IFS= read -r f; do
      echo "---------- ${f} ----------"
      grep -nE -A5 -B5 '^(<<<<<<<|=======|>>>>>>>)' "$f" | head -n 60
    done
    return 1
  fi
  return 0
}

patch_kernelsu_for_susfs() {
  local ksu_repo_dir="$1"
  local ksu_dir="$2"
  local patch_name="10_enable_susfs_for_ksu.patch"
  local patch_file="${ksu_repo_dir}/${patch_name}"
  local kconfig_file="${ksu_dir}/Kconfig"

  test -f "$kconfig_file" || {
    echo "::error::KernelSU Kconfig not found at $kconfig_file"
    exit 1
  }

  if grep -q 'KSU_SUSFS' "$kconfig_file"; then
    echo "[+] KernelSU tree already contains KSU_SUSFS entries (native susfs support)."
    return 0
  fi

  test -f "$patch_file" || {
    echo "::error::Missing KernelSU susfs patch at $patch_file"
    exit 1
  }

  # Strategy 1: three-way merge.
  #
  # susfs4ksu's patch is cut against whatever SukiSU snapshot the susfs author
  # had. Plain `patch` matches by context lines only, so on a drifted tree it
  # applies some hunks, rejects others, and can leave a file that is valid to
  # neither side (we watched it eat an #include block and the leading "//" of a
  # comment). `git apply -3` instead reconstructs the patch's base blobs from
  # the index lines and does a real merge, which is exactly the right tool for
  # version drift. It also fails atomically.
  echo "==== Applying susfs KernelSU patch (three-way merge) ===="
  if git -C "$ksu_repo_dir" apply --3way --whitespace=nowarn "$patch_name" 2>&1; then
    if assert_no_conflict_markers "$ksu_dir"; then
      echo "[+] Three-way merge applied cleanly."
    else
      echo "::error::Three-way merge produced conflicts that need manual resolution."
      exit 1
    fi
  else
    echo "[!] Three-way merge failed (missing base blobs or real conflicts)."
    echo "[!] Resetting the tree and falling back to context matching."
    reset_ksu_tree "$ksu_repo_dir"

    # Strategy 2: context matching, but WITHOUT --forward. We want a hunk to
    # either apply or be rejected; we do not want a partially rewritten file.
    local patch_rc=0
    (
      cd "$ksu_repo_dir"
      patch -p1 --batch < "$patch_name"
    ) || patch_rc=$?

    local rej
    local blocking=0
    while IFS= read -r rej; do
      [[ -z "$rej" ]] && continue
      echo "---------- REJECT: ${rej} ----------"
      cat "$rej"
      echo
      blocking=1
    done < <(find "$ksu_repo_dir" -name '*.rej' | sort)

    if [[ "$blocking" -ne 0 ]] || [[ "$patch_rc" -ne 0 ]]; then
      echo "::error::susfs KernelSU patch could not be applied by either strategy."
      echo "::error::Patch: $patch_file"
      echo "::error::Tree:  $ksu_repo_dir"
      echo "::error::The susfs release and the SukiSU-Ultra revision have drifted"
      echo "::error::apart. Pin SUKISU_KPM_REF to a revision matching this susfs."
      exit 1
    fi
  fi

  # The real gate: susfs must be wired into the KernelSU Kconfig, or nothing
  # downstream can enable it and susfs would silently be a no-op.
  grep -q 'KSU_SUSFS' "$kconfig_file" || {
    echo "::error::Patch finished but KSU_SUSFS is still missing from $kconfig_file"
    exit 1
  }

  echo "[+] susfs is wired into the KernelSU Kconfig."
}

patch_resukisu_susfs_runtime_compat() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  [[ -f "$runtime_file" ]] || return 0
  grep -q 'CONFIG_KSU_SUSFS' "$runtime_file" || return 0

  if grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "[+] Runtime already contains native susfs hook support."
    return 0
  fi

  sed -i \
    -e 's/^extern struct static_key_false ksu_init_rc_hook_key_false;$/extern struct static_key_true ksu_is_init_rc_hook_enabled;/' \
    -e 's/^extern struct static_key_false ksu_input_hook_key_false;$/extern struct static_key_true ksu_is_input_hook_enabled;/' \
    -e 's/^#define ksu_init_rc_hook ksu_init_rc_hook_key_false$/#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled/' \
    -e 's/^#define ksu_input_hook ksu_input_hook_key_false$/#define ksu_input_hook ksu_is_input_hook_enabled/' \
    "$runtime_file"

  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_init_rc_hook_key_false ksu_is_init_rc_hook_enabled"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_input_hook_key_false ksu_is_input_hook_enabled"

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_init_rc_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_input_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget init_rc hook to the susfs static key in ${runtime_file}"
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget input hook to the susfs static key in ${runtime_file}"
    exit 1
  fi
}

patch_susfs_selinux_hide_compat() {
  local ksu_kernel_dir="$1"
  local kbuild_file="${ksu_kernel_dir}/Kbuild"
  [[ -f "$kbuild_file" ]] || kbuild_file="${ksu_kernel_dir}/Makefile"
  local compat_dir="${ksu_kernel_dir}/compat"
  local compat_file="${compat_dir}/susfs_selinux_hide_compat.c"
  local compat_obj_line='kernelsu-objs += compat/susfs_selinux_hide_compat.o'
  local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
  local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

  if grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$fake_state_def_re" "$ksu_kernel_dir" && \
     grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$running_def_re" "$ksu_kernel_dir"; then
    if [[ -f "$kbuild_file" ]]; then
      sed -i "\|^${compat_obj_line}$|d" "$kbuild_file"
    fi
    rm -f "$compat_file"
    echo "[+] KernelSU tree already exports susfs SELinux hide compatibility symbols."
    return 0
  fi

  test -f "$kbuild_file" || {
    echo "::error::KernelSU Kbuild not found at $kbuild_file"
    exit 1
  }

  mkdir -p "$compat_dir"
  cat > "$compat_file" <<'EOF_COMPAT'
#include <linux/cache.h>
#include <linux/types.h>
#include "security.h"

#ifdef CONFIG_KSU_SUSFS
struct selinux_state fake_state;
bool ksu_selinux_hide_running __read_mostly = false;
#endif
EOF_COMPAT

  ensure_line_in_file "$kbuild_file" "$compat_obj_line"
  echo "[+] Added susfs SELinux hide compatibility symbols for this KernelSU tree."
}

# Full susfs apply flow: clone susfs, copy patches, patch KernelSU tree,
# apply the kernel-side patch with drift recovery.
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

  git clone --depth=1 --no-tags -b "$susfs_ref" \
    https://gitlab.com/simonpunk/susfs4ksu.git susfs

  # Record exactly which susfs revision we are building against.
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

  cp ./susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "${ksu_repo_dir}/"
  mkdir -p "${ksu_kernel_dir}/include/linux"
  cp ./susfs/kernel_patches/include/linux/* "${ksu_kernel_dir}/include/linux/"
  patch_kernelsu_for_susfs "${ksu_repo_dir}" "${ksu_kernel_dir}"
  patch_resukisu_susfs_runtime_compat "${ksu_kernel_dir}"
  patch_susfs_selinux_hide_compat "${ksu_kernel_dir}"

  test -f include/linux/susfs_def.h || {
    echo "::error::susfs_def.h was not copied into include/linux from $susfs_ref"
    find include/linux -maxdepth 1 -type f -name 'susfs*' -print || true
    exit 1
  }

  test -f "${ksu_kernel_dir}/include/linux/susfs_def.h" || {
    echo "::error::susfs_def.h was not copied into ${ksu_kernel_dir}/include/linux from $susfs_ref"
    find "${ksu_kernel_dir}/include/linux" -maxdepth 1 -type f -name 'susfs*' -print || true
    exit 1
  }

  if ! patch -p1 --batch --forward < "${susfs_patch_file}"; then
    echo "[!] susfs patch reported conflicts, checking for known task_mmu.c drift..."

    local reject_files reject_count
    reject_files="$(find . -name "*.rej" | sort)"
    reject_count="$(printf '%s\n' "$reject_files" | sed '/^$/d' | wc -l)"

    if [[ "$reject_count" -eq 1 ]] && [[ "$reject_files" == "./fs/proc/task_mmu.c.rej" ]] && grep -q 'susfs_def.h' ./fs/proc/task_mmu.c.rej; then
      apply_susfs_task_mmu_fix
      rm -f ./fs/proc/task_mmu.c.rej
      echo "[+] Resolved known susfs task_mmu.c patch drift."
    else
      echo "==== PATCH FAILED ===="
      echo "==== REJECT FILES ===="
      find . -name "*.rej" -print -exec sh -c 'echo "---- $1 ----"; cat "$1"' _ {} \;
      exit 1
    fi
  fi

  patch_susfs_kernelsu_layout

  # Export for downstream verification
  export KSU_KERNEL_DIR="$ksu_kernel_dir"
  export KSU_REPO_DIR="$ksu_repo_dir"
}
