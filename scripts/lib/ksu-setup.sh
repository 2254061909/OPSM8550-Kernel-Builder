#!/usr/bin/env bash
#
# KernelSU variant setup helpers. Sourced, not executed.
# Depends on lib/kernel-helpers.sh (insert_line_before_first_match,
# ensure_line_in_file, detect_kernelsu_driver_dir, kernelsu_kconfig_source_path).
#

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
      echo "[+] Cloned ${owner}/${repo} branch '$ref'."
      cloned=1
      break
    fi

    rm -rf "$repo_dir"
    echo "[!] ${owner}/${repo} branch '$ref' is unavailable, trying next fallback..."
  done

  if [[ "$cloned" -ne 1 ]]; then
    echo "::error::Failed to clone ${owner}/${repo} from https://github.com/${owner}/${repo}.git using refs: $refs_to_try"
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

# Sanity check: the KPM variant is only meaningful if the KSU driver we just
# installed actually contains the KPM sources and Kconfig entry. ReSukiSU does
# not (KPM was removed upstream), SukiSU-Ultra's susfs-main branch does.
verify_kpm_capable_driver() {
  local driver_dir ksu_kernel_dir
  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found while verifying KPM support"
    exit 1
  }
  ksu_kernel_dir="$(readlink -f "${driver_dir}/kernelsu")"

  test -f "${ksu_kernel_dir}/kpm/kpm.c" || {
    echo "::error::The installed KernelSU driver has no kpm/ sources at ${ksu_kernel_dir}/kpm."
    echo "::error::KPM builds require a KSU tree that ships KPM (e.g. SukiSU-Ultra)."
    exit 1
  }

  grep -q 'config KPM' "${ksu_kernel_dir}/Kconfig" || {
    echo "::error::The installed KernelSU Kconfig has no 'config KPM' entry."
    exit 1
  }

  grep -q 'kpm/kpm.o' "${ksu_kernel_dir}/Kbuild" 2>/dev/null || \
  grep -q 'kpm/kpm.o' "${ksu_kernel_dir}/Makefile" 2>/dev/null || {
    echo "::error::The installed KernelSU build files do not reference kpm/kpm.o."
    exit 1
  }

  echo "[+] Verified: installed KSU driver ships KPM sources, Kconfig and build rules."
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
      # KPM requires SukiSU-Ultra. Its susfs-main branch has susfs support
      # built in, so the susfs4ksu KernelSU-side patch must NOT be applied on
      # top of it (that is what used to blow up core_hook.c / init.c).
      echo "[+] KPM variant requested: using SukiSU-Ultra branch susfs-main."
      curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
        "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
      verify_kpm_capable_driver
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
