#!/usr/bin/env bash
#
# Shared helper functions used by the kernel build pipeline.
# This file is sourced, not executed.
#

# ---- Small utilities ---------------------------------------------------------

ensure_line_in_file() {
  local file="$1"
  local line="$2"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

insert_line_before_first_match() {
  local file="$1"
  local match_line="$2"
  local insert_line="$3"
  local tmp_file

  grep -qxF "$insert_line" "$file" && return 0

  tmp_file="$(mktemp)"
  awk -v match_line="$match_line" -v insert_line="$insert_line" '
    !inserted && $0 == match_line {
      print insert_line
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print insert_line
      }
    }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

detect_kernelsu_driver_dir() {
  if test -d "common/drivers"; then
    echo "common/drivers"
  elif test -d "drivers"; then
    echo "drivers"
  else
    return 1
  fi
}

kernelsu_kconfig_source_path() {
  local driver_dir="$1"
  echo "${driver_dir}/kernelsu/Kconfig"
}

# ---- defconfig / .config manipulation ---------------------------------------

set_config_value() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  if [[ "$value" == "n" ]]; then
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|# ${key} is not set|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      :
    else
      echo "# ${key} is not set" >> "$config_file"
    fi
  else
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      sed -i "s|^# ${key} is not set$|${key}=${value}|" "$config_file"
    else
      echo "${key}=${value}" >> "$config_file"
    fi
  fi
}

enable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" y
  done
}

disable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" n
  done
}

enable_susfs_configs() {
  local config_file="$1"
  enable_config_values "$config_file" \
    CONFIG_KSU_SUSFS \
    CONFIG_KSU_SUSFS_SUS_PATH \
    CONFIG_KSU_SUSFS_SUS_MOUNT \
    CONFIG_KSU_SUSFS_SUS_KSTAT \
    CONFIG_KSU_SUSFS_SPOOF_UNAME \
    CONFIG_KSU_SUSFS_ENABLE_LOG \
    CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
  disable_config_values "$config_file" \
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
}

enable_ksu_common_configs() {
  local config_file="$1"
  enable_config_values "$config_file" CONFIG_TMPFS_XATTR
}

enable_resukisu_kpm_configs() {
  local config_file="$1"
  enable_config_values "$config_file" \
    CONFIG_KPM \
    CONFIG_KALLSYMS \
    CONFIG_KALLSYMS_ALL
}

# ---------------------------------------------------------------------------
# ftrace / debug tracing -- OPT-IN, and for good reason.
#
# Turning these on breaks boot on devices that keep the stock vendor_dlkm:
# CONFIG_TRACING and friends change the layout of core structures such as
# task_struct, while the hundreds of .ko files in vendor_dlkm were compiled
# against the stock kernel. They then fail to load -- touchscreen, charger,
# display -- and the device never finishes booting.
#
# The vendor fragments say so explicitly. ingres' debugfs.config sets:
#     CONFIG_DEBUG_FS=n   CONFIG_PAGE_OWNER=n   CONFIG_PAGE_PINNER=n
# That is a deliberate production choice, and forcing DEBUG_FS back to y
# after the fragments have been merged overrides it.
#
# So: only enable this when ENABLE_FTRACE=1 is explicitly requested, and
# never silently. A kernel that boots is worth more than one that traces.
# ---------------------------------------------------------------------------
enable_ftrace_debug_configs() {
  local config_file="$1"

  if [[ "${ENABLE_FTRACE:-0}" != "1" ]]; then
    return 0
  fi

  # Parent symbols matter as much as the leaves: FUNCTION_TRACER depends on
  # FTRACE, which depends on TRACING_SUPPORT. olddefconfig silently drops any
  # symbol whose dependencies are unmet.
  enable_config_values "$config_file" \
    CONFIG_TRACING_SUPPORT \
    CONFIG_FTRACE \
    CONFIG_TRACING \
    CONFIG_GENERIC_TRACER \
    CONFIG_FUNCTION_TRACER \
    CONFIG_DYNAMIC_FTRACE \
    CONFIG_DEBUG_FS \
    CONFIG_FTRACE_SYSCALLS \
    CONFIG_STACK_TRACER

  echo "[!] ftrace/debug tracing enabled by request (ENABLE_FTRACE=1)."
  echo "[!] This changes core struct layouts. If the device keeps its stock"
  echo "[!] vendor_dlkm modules, they may fail to load and it may not boot."
}

apply_variant_configs() {
  local config_file="$1"

  enable_ftrace_debug_configs "$config_file"

  if [[ "$KSU_TYPE" == *susfs* ]]; then
    enable_susfs_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" != "None" ]]; then
    enable_ksu_common_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" == "ReSukiSU-with-susfs-KPM" ]]; then
    enable_resukisu_kpm_configs "$config_file"
  fi
}

require_config_enabled() {
  local config_file="$1"
  local key="$2"

  if ! grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key}=y in ${config_file}, but it was not enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}

require_config_disabled() {
  local config_file="$1"
  local key="$2"

  if grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key} to stay disabled in ${config_file}, but it is enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}
