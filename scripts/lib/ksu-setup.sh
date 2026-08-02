#!/usr/bin/env bash
#
# KernelSU variant setup helpers. Sourced, not executed.
# Depends on lib/kernel-helpers.sh (insert_line_before_first_match,
# ensure_line_in_file, detect_kernelsu_driver_dir, kernelsu_kconfig_source_path).
#

# ---------------------------------------------------------------------------
# PINNED UPSTREAM REFS
#
# As of 2026-08 no single upstream branch provides root + susfs + KPM:
#   ReSukiSU main       -> root + native susfs, KPM deliberately removed
#   SukiSU-Ultra main   -> root + KPM, susfs must come from susfs4ksu
#   susfs-* branches    -> deleted upstream, do not reference them
#
# susfs4ksu's 10_enable_susfs_for_ksu.patch is maintained against the MODERN
# modular layout (kernel/core/, kernel/policy/, kernel/supercall/, ...), so the
# KSU tree must be a 4.x-style tree. The old flat v3.1.x tags do NOT work: the
# patch cannot find a single file and silently no-ops.
# ---------------------------------------------------------------------------
SUKISU_KPM_REF="${SUKISU_KPM_REF:-main}"

setup_kernelsu_repo() {
  local owner="$1"
  local repo="$2"
  local requested_ref="$3"
  local allow_fallbacks="${4:-0}"
  local repo_dir="$repo"
  local driver_dir
  local kconfig_source
  local ref
  local cloned=0
  local refs_to_try

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

    if git clone --depth=1 --no-tags -b "$ref" "https://github.com/${owner}/${repo}.git" "$repo_dir"; then
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

# The KPM variant needs a tree that has BOTH the KPM sources and the modular
# layout that susfs4ksu's KernelSU patch targets. Upstream's setup.sh swallows a
# failed checkout ("|| echo Checkout default branch"), so we clone the ref
# ourselves and verify the result rather than trusting it.
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

  # Modular layout check. susfs4ksu's KernelSU patch addresses
  # kernel/core/init.c, kernel/policy/, kernel/supercall/ etc. On an old flat
  # tree (core_hook.c at top level) every hunk is skipped with
  # "can't find file to patch" and susfs silently never gets enabled.
  if [[ -f "${ksu_kernel_dir}/core/init.c" ]] && [[ -d "${ksu_kernel_dir}/supercall" ]]; then
    echo "  [OK]   modular layout (core/init.c, supercall/) -- susfs4ksu patch targets this"
  else
    echo "  [FAIL] not a modular tree; susfs4ksu's KernelSU patch will match nothing."
    echo "         Old flat trees (core_hook.c at top level) are NOT usable."
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "::error::The installed KSU tree cannot satisfy susfs + KPM together."
    echo "::error::Checked out tree contents:"
    ls -1 "${ksu_kernel_dir}" | head -n 40
    exit 1
  fi

  echo "[+] KSU tree verified: KPM sources + modular layout for susfs."
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
      echo "[+] KPM variant: SukiSU-Ultra @ ${SUKISU_KPM_REF}."
      setup_kernelsu_repo "SukiSU-Ultra" "SukiSU-Ultra" "$SUKISU_KPM_REF" 0
      verify_kpm_capable_driver
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
