#!/usr/bin/env bash
#
# Orchestrates the full kernel compile flow:
#   1. Set up cross-compile / ccache environment
#   2. Apply the requested KSU variant
#   3. Apply susfs patches (if requested)
#   4. Generate defconfig, merge config fragments, apply variant tweaks
#   5. PREFLIGHT: assert every requested feature is enabled in .config
#   6. Build Image
#   7. Assert the features are present in the built vmlinux (symbol level)
#   8. Patch Image with the KPM loader (KPM variants only)
#
# Required env (provided by the workflow):
#   GITHUB_WORKSPACE CLANG_VERSION SOC BUILD_CONFIGS SOURCE_LAYOUT
#   OFFICIAL_BUILD_TARGET KSU_TYPE KERNEL_BRANCH
#   SUSFS_REF / SUSFS_PATCH_FILE (susfs variants only)
#   FTRACE_LEVEL=none|trace|full (default trace; see kernel-helpers.sh)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kernel-helpers.sh
. "${SCRIPT_DIR}/lib/kernel-helpers.sh"
# shellcheck source=lib/ksu-setup.sh
. "${SCRIPT_DIR}/lib/ksu-setup.sh"
# shellcheck source=lib/susfs-apply.sh
. "${SCRIPT_DIR}/lib/susfs-apply.sh"
# shellcheck source=lib/verify.sh
. "${SCRIPT_DIR}/lib/verify.sh"

: "${GITHUB_WORKSPACE:?}"
: "${CLANG_VERSION:?}"
: "${SOC:?}"
: "${BUILD_CONFIGS:?}"
: "${SOURCE_LAYOUT:?}"
: "${OFFICIAL_BUILD_TARGET:?}"
: "${KSU_TYPE:?}"
: "${KERNEL_BRANCH:?}"

FTRACE_LEVEL="${FTRACE_LEVEL:-trace}"
export FTRACE_LEVEL

IS_KPM_BUILD=0
IS_SUSFS_BUILD=0
IS_KSU_BUILD=0
if [[ "$KSU_TYPE" == *KPM* ]]; then IS_KPM_BUILD=1; fi
if [[ "$KSU_TYPE" == *susfs* ]]; then IS_SUSFS_BUILD=1; fi
if [[ "$KSU_TYPE" != "None" ]]; then IS_KSU_BUILD=1; fi

# ---- Toolchain / ccache env --------------------------------------------------
CLANG_ROOT="${GITHUB_WORKSPACE}/toolchains/${CLANG_VERSION}/bin"
export PATH="${CLANG_ROOT}:${PATH}"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CCACHE_DIR="${GITHUB_WORKSPACE}/.ccache"
export CCACHE_BASEDIR="${GITHUB_WORKSPACE}"
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_MAXSIZE=2G
mkdir -p "${CCACHE_DIR}"
export CC="ccache ${CLANG_ROOT}/clang"
export CXX="ccache ${CLANG_ROOT}/clang++"
export HOSTCC="ccache ${CLANG_ROOT}/clang"
export HOSTCXX="ccache ${CLANG_ROOT}/clang++"
export LD="${CLANG_ROOT}/ld.lld"
export AR="${CLANG_ROOT}/llvm-ar"
export NM="${CLANG_ROOT}/llvm-nm"
export OBJCOPY="${CLANG_ROOT}/llvm-objcopy"
export OBJDUMP="${CLANG_ROOT}/llvm-objdump"
export STRIP="${CLANG_ROOT}/llvm-strip"

cd "${SOC}"

echo "==== BUILD REQUEST ===="
echo "ksu_type     : ${KSU_TYPE}"
echo "kernel_branch: ${KERNEL_BRANCH}"
echo "ftrace_level : ${FTRACE_LEVEL}"

# ---- KSU variant -------------------------------------------------------------
install_ksu_variant "${KSU_TYPE}"

# ---- susfs -------------------------------------------------------------------
if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  : "${SUSFS_REF:?}"
  : "${SUSFS_PATCH_FILE:?}"
  apply_susfs_full "$SUSFS_REF" "$SUSFS_PATCH_FILE"
  verify_susfs_source_integration "${KSU_KERNEL_DIR}"
fi

touch .scmversion

# ---- Config -----------------------------------------------------------------
ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"
if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi

apply_variant_configs arch/arm64/configs/gki_defconfig

# shellcheck disable=SC2086
make O=out gki_defconfig ${ACTIVE_BUILD_CONFIGS}

# NOTE: vendor fragments are merged AFTER gki_defconfig and represent the
# vendor's production choices (ingres' debugfs.config disables DEBUG_FS,
# PAGE_OWNER and PAGE_PINNER on purpose). Re-applying our own settings here
# overrides them, so only touch what the requested features actually need.
apply_variant_configs out/.config

if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  if [[ -x scripts/config ]]; then
    scripts/config --file out/.config --enable KPM
    scripts/config --file out/.config --enable KALLSYMS
    scripts/config --file out/.config --enable KALLSYMS_ALL
  else
    sed -i '/^# CONFIG_KPM is not set$/d;/^# CONFIG_KALLSYMS_ALL is not set$/d' out/.config
    {
      echo 'CONFIG_KPM=y'
      echo 'CONFIG_KALLSYMS=y'
      echo 'CONFIG_KALLSYMS_ALL=y'
    } >> out/.config
  fi
  echo "[+] Enabled CONFIG_KPM / CONFIG_KALLSYMS / CONFIG_KALLSYMS_ALL."
fi

# The susfs gki-android13-5.10 patch enables CONFIG_KSU_SUSFS_OPEN_REDIRECT by
# default, which injects 4-argument set_nameidata() calls into fs/namei.c. This
# 5.10.245 tree defines the standard 3-argument form, so disable it.
if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  if [[ -x scripts/config ]]; then
    scripts/config --file out/.config --disable KSU_SUSFS_OPEN_REDIRECT || true
  else
    sed -i 's/^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y$/# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set/' out/.config || true
    grep -q 'CONFIG_KSU_SUSFS_OPEN_REDIRECT' out/.config \
      || echo '# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set' >> out/.config
  fi
  echo "[+] Disabled CONFIG_KSU_SUSFS_OPEN_REDIRECT (3-arg set_nameidata compat)."
fi

make O=out olddefconfig

# =============================================================================
# PREFLIGHT -- fail here (~2 min) rather than after a full build (~8 min).
# =============================================================================
echo "==== PREFLIGHT: CONFIG ASSERTIONS ===="
PREFLIGHT_FAILED=0

assert_config_y() {
  local symbol="$1"
  local why="$2"
  if grep -q "^${symbol}=y" out/.config; then
    echo "  [OK]   ${symbol}=y"
  else
    echo "  [FAIL] ${symbol} is not enabled -- ${why}"
    grep -E "^(# )?${symbol}[ =]" out/.config || echo "         (absent from .config entirely)"
    PREFLIGHT_FAILED=1
  fi
}

assert_config_not_y() {
  local symbol="$1"
  local why="$2"
  if grep -q "^${symbol}=y" out/.config; then
    echo "  [FAIL] ${symbol} is enabled -- ${why}"
    PREFLIGHT_FAILED=1
  else
    echo "  [OK]   ${symbol} disabled"
  fi
}

case "$FTRACE_LEVEL" in
  trace)
    assert_config_y CONFIG_FTRACE           "tracers menu switch"
    assert_config_y CONFIG_FUNCTION_TRACER  "ftrace_level=trace"
    assert_config_y CONFIG_DYNAMIC_FTRACE   "ftrace_level=trace"
    assert_config_y CONFIG_FTRACE_SYSCALLS  "ftrace_level=trace"
    assert_config_y CONFIG_STACK_TRACER     "ftrace_level=trace"
    # Not asserting DEBUG_FS either way: 'trace' leaves it exactly as the
    # vendor fragments set it, which on ingres means n.
    ;;
  full)
    assert_config_y CONFIG_FTRACE           "tracers menu switch"
    assert_config_y CONFIG_FUNCTION_TRACER  "ftrace_level=full"
    assert_config_y CONFIG_DYNAMIC_FTRACE   "ftrace_level=full"
    assert_config_y CONFIG_FTRACE_SYSCALLS  "ftrace_level=full"
    assert_config_y CONFIG_STACK_TRACER     "ftrace_level=full"
    assert_config_y CONFIG_DEBUG_FS         "ftrace_level=full"
    ;;
  none)
    echo "  [i]    ftrace_level=none; vendor tracing config kept as-is"
    ;;
esac

if [[ "$IS_KSU_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KSU "root support was requested"
fi

if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KSU_SUSFS "susfs was requested"
  assert_config_not_y CONFIG_KSU_SUSFS_OPEN_REDIRECT "incompatible with 3-arg set_nameidata"
fi

if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KPM          "KPM was requested"
  assert_config_y CONFIG_KALLSYMS     "KPM resolves symbols at module load time"
  assert_config_y CONFIG_KALLSYMS_ALL "KPM resolves symbols at module load time"
fi

if [[ "$PREFLIGHT_FAILED" -ne 0 ]]; then
  echo "::error::Preflight config assertions failed -- aborting before the expensive build."
  echo "==== RELEVANT CONFIG LINES ===="
  grep -E '^(# )?CONFIG_(KSU|KPM|KALLSYMS|TRACING|FTRACE|FUNCTION_TRACER|DYNAMIC_FTRACE|DEBUG_FS|STACK_TRACER)' out/.config || true
  exit 1
fi
echo "[+] Preflight passed."

# Record how the tracing options ended up, so a non-booting build can be
# correlated with them afterwards.
echo "==== TRACING / DEBUGFS CONFIG AS BUILT ===="
grep -E '^(# )?CONFIG_(TRACING|FTRACE|FUNCTION_TRACER|DYNAMIC_FTRACE|DEBUG_FS|STACK_TRACER|FTRACE_SYSCALLS|PAGE_OWNER|PAGE_PINNER)[ =]' out/.config || true

# ---- Build -------------------------------------------------------------------
ccache -z || true

if ! make -j"$(nproc)" O=out Image 2>&1 | tee build.log; then
  ccache -sv || true
  echo "==== BUILD ERROR SUMMARY ===="
  grep -nE ' error:|undefined reference|No rule to make target|fatal error:' build.log | tail -n 50 || true
  echo "==== BUILD FAILED (last 200 lines) ===="
  tail -n 200 build.log || true
  exit 1
fi

test -f out/arch/arm64/boot/Image || {
  echo "::error::Kernel Image was not produced despite make succeeding."
  exit 1
}
echo "[+] Kernel Image built successfully: out/arch/arm64/boot/Image"

# =============================================================================
# SYMBOL ASSERTIONS
# =============================================================================
if [[ -f out/vmlinux ]]; then
  echo "==== SYMBOL ASSERTIONS ===="
  SYMBOLS_FAILED=0
  "${NM}" out/vmlinux > vmlinux-symbols.txt 2>/dev/null || true

  assert_symbol() {
    local pattern="$1"
    local why="$2"
    local hits
    hits="$(grep -cE "$pattern" vmlinux-symbols.txt || true)"
    if [[ "${hits:-0}" -gt 0 ]]; then
      echo "  [OK]   ${pattern} (${hits} symbols)"
    else
      echo "  [FAIL] no symbol matching ${pattern} -- ${why}"
      SYMBOLS_FAILED=1
    fi
  }

  if [[ "$IS_KSU_BUILD" -eq 1 ]]; then
    assert_symbol ' ksu_' "the KernelSU driver did not get linked in"
  fi
  if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
    assert_symbol ' susfs_' "susfs did not get linked in"
  fi
  if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
    assert_symbol '[ _]kpm|[ _]KPM' "the KPM objects did not get linked in"
  fi
  if [[ "$FTRACE_LEVEL" != "none" ]]; then
    assert_symbol ' ftrace_' "function tracing did not get compiled in"
  fi

  if [[ "$SYMBOLS_FAILED" -ne 0 ]]; then
    echo "::error::A requested feature compiled but is not present in vmlinux."
    exit 1
  fi
  echo "[+] Symbol assertions passed."
else
  echo "::warning::out/vmlinux not found; skipping symbol assertions."
fi

# =============================================================================
# KPM Image patching.
# =============================================================================
if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  echo "[+] Patching Image with the KPM loader..."
  KPM_TOOL_DIR="${GITHUB_WORKSPACE}/kpm-tools"
  rm -rf "$KPM_TOOL_DIR"
  mkdir -p "$KPM_TOOL_DIR"

  curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs \
    -o "${KPM_TOOL_DIR}/patch_linux" \
    "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/main/kpm/patch_linux" || {
    echo "::error::Failed to download patch_linux from SukiSU_patch."
    exit 1
  }
  chmod +x "${KPM_TOOL_DIR}/patch_linux"

  KPM_LOG="${GITHUB_WORKSPACE}/${SOC}/kpm-patch.log"
  pushd out/arch/arm64/boot >/dev/null
  cp -f Image Image.unpatched

  if ! "${KPM_TOOL_DIR}/patch_linux" 2>&1 | tee "$KPM_LOG"; then
    echo "::error::patch_linux failed; see kpm-patch.log."
    popd >/dev/null
    exit 1
  fi

  if [[ ! -f oImage ]]; then
    echo "::error::patch_linux ran but produced no oImage."
    ls -l
    popd >/dev/null
    exit 1
  fi

  ORIG_SIZE="$(stat -c %s Image.unpatched)"
  PATCHED_SIZE="$(stat -c %s oImage)"
  if [[ "$PATCHED_SIZE" -le "$ORIG_SIZE" ]]; then
    echo "::error::oImage (${PATCHED_SIZE}) is not larger than Image (${ORIG_SIZE}); the patch did nothing."
    popd >/dev/null
    exit 1
  fi

  HEADER_MAGIC="$(dd if=oImage bs=1 skip=56 count=4 status=none | xxd -p | tr -d '\n' || true)"
  if [[ "$HEADER_MAGIC" != "41524d64" ]]; then
    echo "::error::oImage arm64 header magic is '${HEADER_MAGIC}', expected 41524d64."
    echo "::error::patch_linux corrupted the image header; this build would not boot."
    popd >/dev/null
    exit 1
  fi

  mv -f oImage Image
  echo "[+] KPM patch applied: ${ORIG_SIZE} -> ${PATCHED_SIZE} bytes, header magic intact."
  popd >/dev/null
fi

# ---- Final snapshots ---------------------------------------------------------
echo "==== FINAL CONFIG SNAPSHOT ===="
grep -E '^CONFIG_(KSU|KPM|KALLSYMS|FTRACE|FUNCTION_TRACER|DYNAMIC_FTRACE|DEBUG_FS|STACK_TRACER)' out/.config || true

if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  ( verify_resukisu_susfs_hook_mode ) \
    || echo "::warning::verify_resukisu_susfs_hook_mode reported an issue (advisory)."
  ( verify_susfs_binary_presence ) \
    || echo "::warning::verify_susfs_binary_presence reported an issue (advisory)."
fi

ccache -sv || true
test -f out/arch/arm64/boot/Image
echo "[+] Build complete (ftrace_level=${FTRACE_LEVEL})."
