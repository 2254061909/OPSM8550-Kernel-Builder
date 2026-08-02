#!/usr/bin/env bash
#
# Post-patch/post-build verification helpers. Sourced, not executed.
#

# Does this KSU tree use the ReSukiSU-style static-key hook plumbing in
# runtime/ksud_integration.c? Decide from the tree itself, never from the
# preset label: the "ReSukiSU + susfs + KPM" preset actually installs
# SukiSU-Ultra (only it ships KPM), and SukiSU-Ultra uses a different hook
# architecture (hook/syscall_hook.c) with no init_rc/input static keys at all.
ksu_tree_uses_resukisu_hook_plumbing() {
  local runtime_file="$1"
  [[ -f "$runtime_file" ]] || return 1
  grep -Eq 'ksu_init_rc_hook|ksu_input_hook' "$runtime_file" || return 1
  return 0
}

verify_susfs_source_integration() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  test -f fs/susfs.c || {
    echo "::error::fs/susfs.c is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs.h || {
    echo "::error::include/linux/susfs.h is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs_def.h || {
    echo "::error::include/linux/susfs_def.h is missing after applying susfs patches."
    exit 1
  }

  grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || {
    echo "::error::fs/Makefile does not reference susfs.o after applying susfs patches."
    exit 1
  }

  grep -q 'ksu_handle_sys_reboot' kernel/reboot.c || {
    echo "::error::kernel/reboot.c is missing the susfs reboot hook after applying susfs patches."
    exit 1
  }

  grep -R -q 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" || {
    echo "::error::KernelSU tree does not expose CMD_SUSFS_SHOW_VERSION, so the manager will not detect susfs."
    exit 1
  }

  if grep -R -q 'ksu_selinux_hide_running' security/selinux; then
    local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
    local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

    grep -R -Eq "$fake_state_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define fake_state required by the susfs SELinux hooks."
      exit 1
    }
    grep -R -Eq "$running_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define ksu_selinux_hide_running required by the susfs SELinux hooks."
      exit 1
    }
  fi

  # susfs must be callable from the KSU driver, whatever the hook architecture.
  grep -R -q 'susfs_init' "$ksu_kernel_dir" || {
    echo "::error::KernelSU tree never calls susfs_init(), so susfs would never start."
    exit 1
  }

  if ksu_tree_uses_resukisu_hook_plumbing "$runtime_file"; then
    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
      echo "::error::Runtime compat is missing ksu_is_init_rc_hook_enabled, so susfs builds will fail or silently fall back."
      exit 1
    }

    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
      echo "::error::Runtime compat is missing ksu_is_input_hook_enabled, so susfs builds will fail or silently fall back."
      exit 1
    }

    if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::Runtime compat is not pointing init_rc hook to the susfs static key."
      exit 1
    fi

    if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::Runtime compat is not pointing input hook to the susfs static key."
      exit 1
    fi

    echo "[+] ReSukiSU-style hook plumbing verified."
  else
    echo "[i] This KSU tree does not use ReSukiSU static-key hook plumbing;"
    echo "    skipping those checks (SukiSU-Ultra uses hook/syscall_hook.c)."
  fi

  {
    echo "==== SUSFS SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "ksu_type=${KSU_TYPE}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    grep -Fn 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || true
    grep -n 'ksu_handle_sys_reboot' kernel/reboot.c | head -n 5 || true
    grep -R -n 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" | head -n 10 || true
    grep -R -n 'susfs_init' "$ksu_kernel_dir" | head -n 10 || true
    grep -R -nE 'fake_state|ksu_selinux_hide_running' "$ksu_kernel_dir" | head -n 10 || true
    if [[ -f "$runtime_file" ]]; then
      grep -nE 'ksu_is_init_rc_hook_enabled|ksu_is_input_hook_enabled|ksu_init_rc_hook_key_false|ksu_input_hook_key_false' "$runtime_file" | head -n 20 || true
    fi
  } | tee susfs-source-proof.txt
}

verify_susfs_binary_presence() {
  local symbol_hits=0
  local string_hits=0

  if [[ -f out/System.map ]]; then
    grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map && symbol_hits=1 || true
  fi

  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_SUS_MOUNT' && string_hits=1 || true
  fi

  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::susfs config flags were enabled, but no susfs signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== SUSFS BINARY PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    if [[ -f out/System.map ]]; then
      grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_' | head -n 20 || true
    fi
  } | tee susfs-proof.txt
}

# Only meaningful for trees that print a hook-mode banner at build time
# (ReSukiSU). SukiSU-Ultra does not, so this is advisory and the caller in
# compile-kernel.sh already treats a non-zero return as a warning.
verify_resukisu_susfs_hook_mode() {
  test -f build.log || {
    echo "::error::build.log is missing, cannot verify hook mode."
    exit 1
  }

  if ! grep -Eq 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook|using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook|using KSU_MANUAL_HOOK|using Manual Hook' build.log; then
    echo "[i] No hook-mode banner in build.log; this tree does not emit one."
    return 0
  fi

  if grep -Eq 'using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook' build.log; then
    echo "::error::Fell back to KSU_TRACEPOINT_HOOK, so the manager will not detect susfs inline mode."
    exit 1
  fi

  if grep -Eq 'using KSU_MANUAL_HOOK|using Manual Hook' build.log; then
    echo "::error::Fell back to KSU_MANUAL_HOOK, so this build is not the expected susfs inline mode."
    exit 1
  fi

  {
    echo "==== SUSFS HOOK PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "susfs_ref=${SUSFS_REF}"
    grep -nE 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook|using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook|using KSU_MANUAL_HOOK|using Manual Hook' build.log || true
  } | tee susfs-hook-proof.txt
}
