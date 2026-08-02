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

# Restore tracked files to pristine HEAD. Deliberately does NOT `git clean`:
# the patch file itself and the susfs headers we copy in are untracked, and
# wiping them destroys the inputs for the next step.
reset_ksu_tracked_files() {
  local ksu_repo_dir="$1"
  git -C "$ksu_repo_dir" checkout -- . 2>/dev/null || true
  find "$ksu_repo_dir" -name '*.rej' -delete 2>/dev/null || true
  find "$ksu_repo_dir" -name '*.orig' -delete 2>/dev/null || true
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

  # `git apply --reject` is the right tool here.
  #
  # A three-way merge is impossible: the patch's base blobs live in the susfs
  # author's own fork and are not objects in the SukiSU-Ultra repository, so
  # --3way always reports "repository lacks the necessary blob" no matter how
  # deep we clone.
  #
  # --reject applies every hunk that fits and writes the rest to .rej, with no
  # fuzzy context matching and no partial rewrites of the files it cannot
  # handle. That gives us an exact, minimal list of what actually drifted.
  echo "==== Applying susfs KernelSU patch (git apply --reject) ===="
  local apply_rc=0
  git -C "$ksu_repo_dir" apply --reject --whitespace=nowarn "$patch_name" 2>&1 || apply_rc=$?

  local rejects
  rejects="$(find "$ksu_repo_dir" -name '*.rej' | sort)"

  if [[ -n "$rejects" ]]; then
    echo "==== FILES THAT DID NOT APPLY ===="
    local rej target
    printf '%s\n' "$rejects" | while IFS= read -r rej; do
      [[ -z "$rej" ]] && continue
      target="${rej%.rej}"
      echo "########## REJECT: ${rej} ##########"
      cat "$rej"
      echo
      if [[ -f "$target" ]]; then
        echo "########## CURRENT ${target} ##########"
        cat -n "$target"
        echo
      fi
    done
  fi

  # susfs must end up wired into the KernelSU Kconfig; that is the difference
  # between "susfs is built in" and "susfs silently does nothing".
  if ! grep -q 'KSU_SUSFS' "$kconfig_file"; then
    echo "::error::KSU_SUSFS is missing from $kconfig_file after patching."
    echo "::error::susfs would be a no-op; refusing to continue."
    exit 1
  fi

  if [[ -n "$rejects" ]]; then
    echo "::error::susfs KernelSU patch left rejects (see the dumps above)."
    echo "::error::susfs and SukiSU-Ultra have drifted in these files only;"
    echo "::error::everything else applied cleanly."
    exit 1
  fi

  echo "[+] susfs KernelSU patch applied cleanly; KSU_SUSFS is wired into Kconfig."
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

  # Record exactly which revisions we are combining.
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
