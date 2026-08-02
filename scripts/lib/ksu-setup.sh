#!/usr/bin/env bash
#
# KernelSU variant setup helpers. Sourced, not executed.
# Depends on lib/kernel-helpers.sh (insert_line_before_first_match,
# ensure_line_in_file, detect_kernelsu_driver_dir, kernelsu_kconfig_source_path).
#

# ---------------------------------------------------------------------------
# PINNED UPSTREAM REFS
#
# SukiSU-Ultra's `builtin` branch carries BOTH KPM and native susfs support:
# its kernel/Kconfig has `config KPM` and a full "KernelSU - SUSFS" menu
# (KSU_SUSFS, SUS_PATH, SUS_MOUNT, SUS_KSTAT, SPOOF_UNAME, OPEN_REDIRECT,
# SUS_MAP ...), all default y.
#
# That means the KernelSU-side susfs patch (10_enable_susfs_for_ksu.patch) must
# NOT be applied on top of it. Only the kernel-tree patch
# (50_add_susfs_in_gki-*.patch) is needed, exactly as upstream build workflows
# do it. Applying the KSU-side patch to an already-susfs-aware tree is what
# produced the endless stream of rejects, deleted includes and deleted
# declarations.
#
# For reference, the other branches:
#   main    -> KPM, no susfs in Kconfig (needs the KSU-side patch: painful)
#   ReSukiSU main -> native susfs, KPM deliberately removed
#   susfs-main / susfs-dev / susfs-stable -> deleted upstream
# ---------------------------------------------------------------------------
SUKISU_KPM_REF="${SUKISU_KPM_REF:-builtin}"

setup_kernelsu_repo() {
  local owner="$1"
  local repo="$2"
  local requested_ref="$3"
  local allow_fallbacks="${4:-0}"
  local full_history="${5:-0}"
  local repo_dir="$repo"
  local driver_dir
  local kconfig_source
  local ref
  local cloned=0
  local refs_to_try
  local depth_args="--depth=1 --no-tags"

  if [[ "$full_history" == "1" ]]; then
    depth_args=""
  fi

  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found in kernel tree"
    exit 1
  }
  kconfig_source="$(kernelsu_kconfig_source_path "$driver_dir")"

  rm -rf "$repo_dir"

  refs_to_try="$requested_ref"
  if [[ "$allow_fallbacks" == "1" ]]; then
    refs_to_try="$refs_to_try dev main"
  fi

  for ref in $refs_to_try; do
    [[ -z "$ref" ]] && continue

    # shellcheck disable=SC2086
    if git clone $depth_args -b "$ref" "https://github.com/${owner}/${repo}.git" "$repo_dir"; then
      echo "[+] Cloned ${owner}/${repo} at '$ref'."
      cloned=1
      break
    fi

    rm -rf "$repo_dir"
    echo "[!] ${owner}/${repo} ref '$ref' is unavailable, trying next fallback..."
  done

  if [[ "$cloned" -ne 1 ]]; then
    echo "::error::Failed to clone ${owner}/${repo} using refs: $refs_to_try"
    exit 1
  fi

  rm -rf "$driver_dir/kernelsu"
  ln -sfn "$(realpath --relative-to="$driver_dir" "$repo_dir/kernel")" "$driver_dir/kernelsu"

  ensure_line_in_file "$driver_dir/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
  insert_line_before_first_match "$driver_dir/Kconfig" "endmenu" "source \"$kconfig_source\""
}

setup_kernelsu_next() {
  local requested_ref="$1"
  setup_kernelsu_repo "KernelSU-Next" "KernelSU-Next" "$requested_ref" 1
}

# The KPM variant needs a tree with KPM sources AND native susfs support.
# Upstream's setup.sh swallows a failed checkout ("|| echo Checkout default
# branch"), so we clone the ref ourselves and verify what we actually got.
#
# Note: no layout assertion here. The `builtin` branch is flat (ksu.c at the
# top level, no core/), which is fine precisely because we never apply the
# KernelSU-side susfs patch to it.
verify_kpm_capable_driver() {
  local driver_dir ksu_kernel_dir failed=0
  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found while verifying KPM support"
    exit 1
  }
  ksu_kernel_dir="$(readlink -f "${driver_dir}/kernelsu")"

  echo "==== KSU TREE VERIFICATION ===="

  if [[ -f "${ksu_kernel_dir}/kpm/kpm.c" ]]; then
    echo "  [OK]   kpm/kpm.c present"
  else
    echo "  [FAIL] no kpm/ sources at ${ksu_kernel_dir}/kpm"
    failed=1
  fi

  if grep -q 'config KPM' "${ksu_kernel_dir}/Kconfig" 2>/dev/null; then
    echo "  [OK]   Kconfig has 'config KPM'"
  else
    echo "  [FAIL] Kconfig has no 'config KPM' entry"
    failed=1
  fi

  # Native susfs support is the whole point of this branch. Without it we would
  # have to apply the KernelSU-side susfs patch, which does not survive contact
  # with a modern SukiSU tree.
  if grep -q 'config KSU_SUSFS' "${ksu_kernel_dir}/Kconfig" 2>/dev/null; then
    echo "  [OK]   Kconfig has native 'config KSU_SUSFS' (no KSU-side patch needed)"
  else
    echo "  [FAIL] Kconfig has no KSU_SUSFS entry, so this tree has no native"
    echo "         susfs support. Applying the KernelSU-side susfs patch to a"
    echo "         modern SukiSU tree does not work -- pick a branch that has"
    echo "         susfs built in (currently: builtin)."
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "::error::The installed KSU tree cannot satisfy susfs + KPM together."
    echo "::error::Ref requested: ${SUKISU_KPM_REF}"
    echo "::error::Checked out tree contents:"
    ls -1 "${ksu_kernel_dir}" | head -n 40
    exit 1
  fi

  echo "[+] KSU tree verified: KPM sources + native susfs support."
  export KSU_KERNEL_DIR="$ksu_kernel_dir"
}

# Apply the chosen KSU preset using its upstream setup.sh / local clone flow.
install_ksu_variant() {
  local ksu_type="$1"

  case "$ksu_type" in
    "None")
      ;;
    "Official-KernelSU")
      curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
        "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
      ;;
    "KowSU")
      curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
        "https://raw.githubusercontent.com/KOWX712/KernelSU/main/kernel/setup.sh" | bash -s master
      ;;
    "KernelSU-Next")
      setup_kernelsu_next dev
      ;;
    "ReSukiSU"|"ReSukiSU-with-susfs")
      # ReSukiSU has native susfs support but no KPM.
      curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
        "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main
      ;;
    "ReSukiSU-with-susfs-KPM")
      # Clone ourselves instead of piping upstream's setup.sh: setup.sh treats a
      # failed checkout as a warning and silently continues on the default
      # branch, which is how a wrong tree slipped through before.
      echo "[+] KPM variant: SukiSU-Ultra @ ${SUKISU_KPM_REF} (KPM + native susfs)."
      setup_kernelsu_repo "SukiSU-Ultra" "SukiSU-Ultra" "$SUKISU_KPM_REF" 0 0
      verify_kpm_capable_driver
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
