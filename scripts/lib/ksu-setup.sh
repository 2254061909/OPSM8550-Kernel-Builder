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

# Overlay KPM support from SukiSU-Ultra onto an already-installed KSU driver.
# Must be called AFTER susfs patches have been applied.
overlay_kpm_from_sukisu() {
  local driver_dir
  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found, cannot overlay KPM"
    exit 1
  }
  local ksu_kernel_dir
  ksu_kernel_dir="$(readlink -f "${driver_dir}/kernelsu")"

  echo "[+] Overlaying KPM support from SukiSU-Ultra..."

  # Clone SukiSU-Ultra kernel to extract KPM files
  rm -rf SukiSU-Ultra-kpm
  git clone --depth=1 --no-tags -b main \
    "https://github.com/SukiSU-Ultra/SukiSU-Ultra.git" SukiSU-Ultra-kpm

  # Copy kpm/ directory into the KSU driver
  rm -rf "${ksu_kernel_dir}/kpm"
  cp -r SukiSU-Ultra-kpm/kernel/kpm "${ksu_kernel_dir}/kpm"
  echo "[+] Copied kpm/ source files."

  # Copy uapi/supercall.h from SukiSU-Ultra (has KPM definitions ReSukiSU lacks)
  cp -f SukiSU-Ultra-kpm/uapi/supercall.h "${ksu_kernel_dir}/uapi/supercall.h"
  echo "[+] Updated uapi/supercall.h with KPM definitions."

  # Fix compact.c: ReSukiSU renamed ksu_manager_appid -> ksu_last_manager_appid
  local compact_c="${ksu_kernel_dir}/kpm/compact.c"
  sed -i 's/ksu_manager_appid/ksu_last_manager_appid/g' "$compact_c"
  echo "[+] Patched compact.c for ReSukiSU API compatibility."

  # Add C99-compat flag for kpm source files (super_access.c uses C99 for-loops)
  local kbuild="${ksu_kernel_dir}/Kbuild"
  if ! grep -q 'kpm/kpm.o' "$kbuild"; then
    printf '\n# KPM objects (overlay from SukiSU-Ultra)\n' >> "$kbuild"
    printf 'obj-$(CONFIG_KPM) += kpm/compact.o\n' >> "$kbuild"
    printf 'obj-$(CONFIG_KPM) += kpm/kpm.o\n' >> "$kbuild"
    printf 'obj-$(CONFIG_KPM) += kpm/super_access.o\n' >> "$kbuild"
    printf 'subdir-ccflags-$(CONFIG_KPM) += -Wno-gcc-compat\n' >> "$kbuild"
    echo "[+] Added KPM objects and flags to Kbuild."
  else
    echo "[+] KPM objects already present in Kbuild."
  fi

  # Add CONFIG_KPM to Kconfig
  local kconfig="${ksu_kernel_dir}/Kconfig"
  if ! grep -q 'config KPM' "$kconfig"; then
    cat >> "$kconfig" << 'KPM_KCONFIG'

config KPM
    bool "Enable SukiSU KPM"
    depends on KSU && 64BIT
    default n
    help
      Enabling this option will activate the KPM feature.
    select KALLSYMS
    select KALLSYMS_ALL
KPM_KCONFIG
    echo "[+] Added CONFIG_KPM to Kconfig."
  else
    echo "[+] CONFIG_KPM already present in Kconfig."
  fi

  rm -rf SukiSU-Ultra-kpm
  echo "[+] KPM overlay complete."
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
    "ReSukiSU"|"ReSukiSU-with-susfs"|"ReSukiSU-with-susfs-KPM")
      # ReSukiSU works with susfs patches; KPM is overlaid later if needed.
      curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
        "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash -s main
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
