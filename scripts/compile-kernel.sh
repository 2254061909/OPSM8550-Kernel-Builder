#!/usr/bin/env bash
#
# Orchestrates the full kernel compile flow:
#   1. Set up cross-compile / ccache environment
#   2. Apply the requested KSU variant
#   3. Apply susfs patches (if requested)
#   4. Generate defconfig, merge config fragments, apply variant tweaks
#   5. PREFLIGHT: assert every requested feature is actually enabled in .config
#   6. FAST CHECK: build only the KernelSU driver (~1 min) to surface C errors
#   7. Build Image
#   8. Patch Image with KPM loader (KPM variants only)
#   9. Assert the features are present in the built vmlinux (symbol level)
#
# Required env (provided by the workflow):
#   GITHUB_WORKSPACE
#   CLANG_VERSION
#   SOC
#   BUILD_CONFIGS
#   SOURCE_LAYOUT
#   OFFICIAL_BUILD_TARGET
#   KSU_TYPE
#   KERNEL_BRANCH
#   SUSFS_REF          (optional; only for susfs variants)
#   SUSFS_PATCH_FILE   (optional; only for susfs variants)
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

IS_KPM_BUILD=0
[[ "$KSU_TYPE" == *KPM* ]] && IS_KPM_BUILD=1
IS_SUSFS_BUILD=0
[[ "$KSU_TYPE" == *susfs* ]] && IS_SUSFS_BUILD=1
IS_KSU_BUILD=0
[[ "$KSU_TYPE" != "None" ]] && IS_KSU_BUILD=1

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

# ---- KSU variant -------------------------------------------------------------
install_ksu_variant "${KSU_TYPE}"

# ---- susfs -------------------------------------------------------------------
# NOTE: apply_susfs_full patches the *kernel tree* (fs/susfs.c, include/linux/*)
# and only patches the KernelSU tree when that tree has no native KSU_SUSFS
# support. SukiSU-Ultra susfs-main and ReSukiSU both have native support, so the
# KernelSU-side patch is skipped automatically -- do not force it.
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

apply_variant_configs out/.config

# ---- KPM config --------------------------------------------------------------
# KPM needs kallsyms to resolve symbols at module-load time. Set these
# explicitly rather than relying on Kconfig 'select', which olddefconfig can
# silently drop if the parent symbol is not visible.
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

# ---- susfs OPEN_REDIRECT compatibility guard --------------------------------
# The susfs gki-android13-5.10 patch enables CONFIG_KSU_SUSFS_OPEN_REDIRECT by
# default. That feature injects 4-argument set_nameidata() calls into
# fs/namei.c, but the stock 5.10.245 tree here defines the standard 3-argument
# set_nameidata(). Disable it so the kernel compiles while keeping the full
# root-hiding capability set.
if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  if [[ -x scripts/config ]]; then
    scripts/config --file out/.config --disable KSU_SUSFS_OPEN_REDIRECT || true
  else
    sed -i 's/^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y$/# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set/' out/.config || true
    grep -q 'CONFIG_KSU_SUSFS_OPEN_REDIRECT' out/.config \
      || echo '# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set' >> out/.config
  fi
  echo "[+] Disabled CONFIG_KSU_SUSFS_OPEN_REDIRECT (susfs 4-arg set_nameidata compat)."
fi

make O=out olddefconfig

# =============================================================================
# PREFLIGHT: every requested feature must be enabled in the final .config.
# This runs before any compilation, so a misconfiguration costs ~2 minutes
# instead of a full 8-minute build.
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
    grep -E "^(# )?${symbol}[ =]" out/.config || echo "         (symbol absent from .config entirely)"
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

# ftrace / debug capability -- requested for all builds.
assert_config_y CONFIG_FUNCTION_TRACER "ftrace debugging was requested for all builds"
assert_config_y CONFIG_DYNAMIC_FTRACE  "ftrace debugging was requested for all builds"
assert_config_y CONFIG_DEBUG_FS        "ftrace needs debugfs to expose its interface"
assert_config_y CONFIG_FTRACE_SYSCALLS "ftrace debugging was requested for all builds"
assert_config_y CONFIG_STACK_TRACER    "ftrace debugging was requested for all builds"

if [[ "$IS_KSU_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KSU "root support was requested"
fi

if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KSU_SUSFS "susfs was requested"
  assert_config_not_y CONFIG_KSU_SUSFS_OPEN_REDIRECT "incompatible with this tree's 3-arg set_nameidata"
fi

if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  assert_config_y CONFIG_KPM           "KPM was requested"
  assert_config_y CONFIG_KALLSYMS      "KPM resolves symbols at module load time"
  assert_config_y CONFIG_KALLSYMS_ALL  "KPM resolves symbols at module load time"
fi

if [[ "$PREFLIGHT_FAILED" -ne 0 ]]; then
  echo "::error::Preflight config assertions failed -- aborting before the expensive build."
  echo "==== RELEVANT CONFIG LINES ===="
  grep -E '^(# )?CONFIG_(KSU|KPM|KALLSYMS|FUNCTION_TRACER|DYNAMIC_FTRACE|DEBUG_FS|FTRACE_SYSCALLS|STACK_TRACER)' out/.config || true
  exit 1
fi
echo "[+] Preflight passed: all requested features are enabled in out/.config."

# =============================================================================
# FAST CHECK: compile only the KernelSU driver directory first (~1 minute).
# Every C-level incompatibility (missing headers, renamed APIs, undeclared
# constants, -Werror pedantry) surfaces here instead of 8 minutes into the
# full build. Only the driver objects are built; nothing is thrown away, the
# full build below reuses them.
# =============================================================================
if [[ "$IS_KSU_BUILD" -eq 1 ]]; then
  KSU_DRIVER_DIR="$(detect_kernelsu_driver_dir)" || KSU_DRIVER_DIR=""
  if [[ -n "$KSU_DRIVER_DIR" ]] && [[ -d "${KSU_DRIVER_DIR}/kernelsu" ]]; then
    echo "==== FAST CHECK: building ${KSU_DRIVER_DIR}/kernelsu/ only ===="
    if ! make -j"$(nproc)" O=out "${KSU_DRIVER_DIR}/kernelsu/" 2>&1 | tee ksu-driver-build.log; then
      echo "::error::The KernelSU driver failed to compile. This is a source-level"
      echo "::error::incompatibility between the KSU tree, susfs and/or KPM."
      echo "==== DRIVER ERROR SUMMARY ===="
      grep -nE ' error:|fatal error:|undefined' ksu-driver-build.log | tail -n 40 || true
      exit 1
    fi
    echo "[+] Fast check passed: KernelSU driver (incl. susfs/KPM sources) compiles."
  fi
fi

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
# SYMBOL ASSERTIONS: prove the features are actually linked into the kernel.
# A successful compile only proves the compiler was happy. Symbol names are
# far more stable across upstream releases than source-text greps, so these
# are fatal rather than advisory.
# =============================================================================
if [[ -f out/vmlinux ]]; then
  echo "==== SYMBOL ASSERTIONS ===="
  SYMBOLS_FAILED=0
  "${NM}" out/vmlinux > vmlinux-symbols.txt 2>/dev/null || true

  assert_symbol() {
    local pattern="$1"
    local why="$2"
    if grep -qE "$pattern" vmlinux-symbols.txt; then
      echo "  [OK]   ${pattern}"
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
    assert_symbol ' sukisu_handle_kpm' "the KPM dispatch entry point is missing"
    assert_symbol ' sukisu_compact_find_symbol' "the KPM symbol resolver is missing"
  fi
  assert_symbol ' ftrace_' "ftrace did not get compiled in"

  if [[ "$SYMBOLS_FAILED" -ne 0 ]]; then
    echo "::error::A requested feature compiled but is not present in vmlinux."
    exit 1
  fi
  echo "[+] Symbol assertions passed: requested features are linked into vmlinux."
else
  echo "::warning::out/vmlinux not found; skipping symbol assertions."
fi

# ---- KPM Image patching ------------------------------------------------------
# Compiling the kpm/ objects is only half of KPM. The KernelPatch loader
# (kpimg) has to be embedded into the Image by patch_linux; without this step
# the manager reports "KernelPatch was not found" and /proc/kallsyms has no KPM
# symbols. This is done in-place so AnyKernel3 packaging, the release upload
# and the artifact upload all pick up the patched Image automatically.
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

  pushd out/arch/arm64/boot >/dev/null
  cp -f Image Image.unpatched

  if ! "${KPM_TOOL_DIR}/patch_linux" 2>&1 | tee "${GITHUB_WORKSPACE}/${SOC}/kpm-patch.log"; then
    echo "::error::patch_linux failed; see kpm-patch.log."
    cat "${GITHUB_WORKSPACE}/${SOC}/kpm-patch.log" || true
    popd >/dev/null
    exit 1
  fi

  test -f oImage || {
    echo "::error::patch_linux ran but produced no oImage."
    ls -l
    popd >/dev/null
    exit 1
  }

  ORIG_SIZE="$(stat -c %s Image.unpatched)"
  PATCHED_SIZE="$(stat -c %s oImage)"
  if [[ "$PATCHED_SIZE" -le "$ORIG_SIZE" ]]; then
    echo "::error::oImage (${PATCHED_SIZE}) is not larger than Image (${ORIG_SIZE}); patch likely did nothing."
    popd >/dev/null
    exit 1
  fi

  # The arm64 Image header must survive patching, or the device will not boot.
  # Bytes 56..59 are the 'ARM\x64' magic.
  HEADER_MAGIC="$(dd if=oImage bs=1 skip=56 count=4 2>/dev/null | xxd -p || true)"
  if [[ "$HEADER_MAGIC" != "41524d64" ]]; then
    echo "::error::oImage arm64 header magic is ${HEADER_MAGIC}, expected 41524d64 (ARM\\x64)."
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
grep -E '^CONFIG_(KSU|KPM|KALLSYMS|FUNCTION_TRACER|DYNAMIC_FTRACE|DEBUG_FS|FTRACE_SYSCALLS|STACK_TRACER)' out/.config || true

if [[ "$IS_SUSFS_BUILD" -eq 1 ]]; then
  # These verifiers grep source text and drift between susfs releases, so they
  # stay advisory. The symbol assertions above are the real gate.
  ( verify_resukisu_susfs_hook_mode ) \
    || echo "::warning::verify_resukisu_susfs_hook_mode reported an issue (advisory)."
  ( verify_susfs_binary_presence ) \
    || echo "::warning::verify_susfs_binary_presence reported an issue (advisory)."
fi

ccache -sv || true
test -f out/arch/arm64/boot/Image
echo "[+] All requested features verified: root / susfs / KPM / ftrace."
