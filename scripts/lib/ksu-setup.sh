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
#   ReSukiSU main        -> root + native susfs, KPM deliberately removed
#   SukiSU-Ultra main    -> root + KPM, susfs removed in the 4.x rewrite
#   SukiSU-Ultra v3.1.7  -> root + KPM + flat layout that susfs4ksu patches
#
# The susfs-main / susfs-dev / susfs-stable branches no longer exist, so the
# KPM variant is pinned to the v3.1.7 tag. Bump this deliberately, never
# implicitly.
# ---------------------------------------------------------------------------
SUKISU_KPM_REF="${SUKISU_KPM_REF:-v3.1.7}"

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

# The KPM variant only works if the installed tree really is the pinned
# SukiSU-Ultra release: KPM sources present, and the flat (pre-4.x) layout that
# the susfs4ksu KernelSU patch expects. Upstream's setup.sh swallows a failed
# checkout ("|| echo Checkout default branch") and silently leaves you on main,
# which is exactly how a KPM-capable-but-susfs-less tree slipped through before.
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

  # Flat layout check: the susfs4ksu KernelSU patch targets core_hook.c at the
  # top level. The 4.x tree moved this to core/init.c and the patch shreds it.
  if [[ -f "${ksu_kernel_dir}/core_hook.c" ]]; then
    echo "  [OK]   flat layout (core_hook.c) -- susfs4ksu patch will apply"
  else
    echo "  [FAIL] no core_hook.c -- this is a 4.x-style tree (core/init.c),"
    echo "         the susfs4ksu KernelSU patch will not apply to it."
    echo "         Most likely the pinned ref was not checked out."
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "::error::The installed KSU tree cannot satisfy susfs + KPM together."
    echo "::error::Checked out tree contents:"
    ls -1 "${ksu_kernel_dir}" | head -n 40
    exit 1
  fi

  echo "[+] KSU tree verified: KPM sources + flat layout for susfs."
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
      # Clone the pinned tag ourselves instead of piping upstream's setup.sh:
      # setup.sh treats a failed checkout as a warning and continues on the
      # default branch, which silently produces a tree without susfs support.
      # setup_kernelsu_repo uses `git clone -b <ref>` and hard-fails instead.
      echo "[+] KPM variant: pinning SukiSU-Ultra to ${SUKISU_KPM_REF}."
      setup_kernelsu_repo "SukiSU-Ultra" "SukiSU-Ultra" "$SUKISU_KPM_REF" 0
      verify_kpm_capable_driver
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
