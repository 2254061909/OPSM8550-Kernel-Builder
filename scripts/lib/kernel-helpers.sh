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
# ftrace levels -- a bisection in progress, on a device that keeps its stock
# vendor_dlkm (388 modules, CONFIG_MODVERSIONS=y, so symbol CRCs are enforced).
#
# Measured on ingres (SM8450):
#
#   none                                            -> BOOTS, verified working
#   FUNCTION_TRACER DYNAMIC_FTRACE FTRACE_SYSCALLS
#     STACK_TRACER DEBUG_FS                         -> does NOT boot
#   FUNCTION_TRACER DYNAMIC_FTRACE FTRACE_SYSCALLS
#     STACK_TRACER            (no DEBUG_FS)         -> does NOT boot
#
# The second result rules out the theory that DEBUG_FS alone was responsible,
# even though it was the option with the most outside evidence against it
# (the vendor's debugfs.config disables it deliberately, and AOSP documents
# enabling debugfs under "intrusive downstream debug features" with an
# ABI-mismatch warning). Something in the remaining four also breaks boot.
#
# Not variables -- the stock config already has these, and level "none" still
# gives you tracefs at /sys/kernel/tracing with ~1700 static tracepoints:
#   CONFIG_TRACING=y  CONFIG_TRACING_SUPPORT=y  CONFIG_FTRACE=y
#
# Next suspect, hence the "func" level: CONFIG_FTRACE_SYSCALLS. It generates
# trace-event metadata for every syscall, touching the trace_event_call and
# syscall_metadata structures -- and Qualcomm's vendor modules use tracepoints
# heavily. It is the only one of the four that plausibly reaches structures
# the modules themselves also see.
#
# By contrast STACK_TRACER only adds kernel/trace/trace_stack.c and registers
# a function hook; DYNAMIC_FTRACE cannot exist without FUNCTION_TRACER and
# actually reduces runtime cost. FUNCTION_TRACER itself changes code
# generation for every function rather than any struct layout, so if "func"
# also fails to boot, ftrace and a stock vendor_dlkm are simply incompatible
# here and there is no middle ground left to find.
#
# FTRACE_LEVEL:
#   none  -> touch nothing, keep the vendor config exactly as merged
#   func  -> FUNCTION_TRACER + DYNAMIC_FTRACE + STACK_TRACER   (DEFAULT)
#   trace -> func + FTRACE_SYSCALLS          (does not boot on ingres)
#   full  -> trace + DEBUG_FS                (does not boot on ingres)
# ---------------------------------------------------------------------------
enable_ftrace_debug_configs() {
  local config_file="$1"
  local level="${FTRACE_LEVEL:-func}"

  case "$level" in
    none)
      echo "[i] FTRACE_LEVEL=none: leaving the vendor tracing config untouched."
      return 0
      ;;
    func|trace|full)
      ;;
    *)
      echo "::error::Unknown FTRACE_LEVEL '${level}' (expected none|func|trace|full)"
      exit 1
      ;;
  esac

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
    CONFIG_STACK_TRACER

  echo "[+] FTRACE_LEVEL=${level}: FUNCTION_TRACER + DYNAMIC_FTRACE + STACK_TRACER"
  echo "    Tracing interface: /sys/kernel/tracing"

  if [[ "$level" == "trace" || "$level" == "full" ]]; then
    enable_config_values "$config_file" CONFIG_FTRACE_SYSCALLS
    echo "[!] + CONFIG_FTRACE_SYSCALLS. This has been observed NOT to boot on"
    echo "[!] ingres with the stock vendor_dlkm."
  fi

  if [[ "$level" == "full" ]]; then
    enable_config_values "$config_file" CONFIG_DEBUG_FS
    echo "[!] + CONFIG_DEBUG_FS, overriding the vendor's debugfs.config."
    echo "[!] Also observed NOT to boot on ingres."
  fi
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
