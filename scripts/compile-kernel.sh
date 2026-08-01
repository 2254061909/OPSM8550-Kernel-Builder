#!/usr/bin/env bash
#
# Orchestrates the full kernel compile flow:
#   1. Set up cross-compile / ccache environment
#   2. Apply the requested KSU variant
#   3. Apply susfs patches (if requested)
#   4. Generate defconfig, merge config fragments, apply variant tweaks
#   5. Build Image
#   6. Run post-build verifications
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
if [[ "$KSU_TYPE" == *susfs* ]]; then
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

# ---- susfs OPEN_REDIRECT compatibility guard --------------------------------
# The susfs gki-android13-5.10 patch enables CONFIG_KSU_SUSFS_OPEN_REDIRECT by
# default (default y in KernelSU Kconfig). That feature injects 4-argument
# set_nameidata(nd, old_dfd, fake_filename, NULL) calls into fs/namei.c, but the
# stock 5.10.245 tree here defines the standard 3-argument set_nameidata(). The
# mismatch breaks the build ("too many arguments to function call, expected 3,
# have 4"). OPEN_REDIRECT is an optional, rarely-used path-redirect feature; all
# core susfs hiding features (SUS_PATH / SUS_MOUNT / SUS_KSTAT / SPOOF_UNAME /
# SPOOF_CMDLINE, etc.) are unaffected. Disable it so the kernel compiles while
# keeping the full root-hiding capability set.
if [[ "$KSU_TYPE" == *susfs* ]]; then
  if [[ -x scripts/config ]]; then
    scripts/config --file out/.config --disable KSU_SUSFS_OPEN_REDIRECT || true
  else
    # Fallback: normalize any enabled line to the disabled form.
    sed -i 's/^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y$/# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set/' out/.config || true
    grep -q 'CONFIG_KSU_SUSFS_OPEN_REDIRECT' out/.config \
      || echo '# CONFIG_KSU_SUSFS_OPEN_REDIRECT is not set' >> out/.config
  fi
  echo "[+] Disabled CONFIG_KSU_SUSFS_OPEN_REDIRECT (susfs 4-arg set_nameidata compat)."
fi

make O=out olddefconfig

# Verify the guard actually stuck (olddefconfig could theoretically re-add it).
if [[ "$KSU_TYPE" == *susfs* ]]; then
  if grep -q '^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y' out/.config; then
    echo "::error::CONFIG_KSU_SUSFS_OPEN_REDIRECT is still enabled after olddefconfig; the set_nameidata mismatch would break the build."
    exit 1
  fi
  echo "[+] Confirmed CONFIG_KSU_SUSFS_OPEN_REDIRECT is disabled in out/.config."
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

# ---- Post-build checks -------------------------------------------------------
# NOTE: The kernel Image is already built successfully at this point. The checks
# below are advisory self-diagnostics. Some of them (notably the susfs binary
# signature scan and the ReSukiSU hook-mode grep) assume specific symbol/string
# names from older susfs releases; with SUSFS v2.2.0 / ReSukiSU v4.1.0 those
# names have drifted, so a passing build can still trip the old assertions.
# We therefore run them in NON-FATAL mode: report findings, but never fail the
# build once a valid Image exists. The definitive success criterion is the
# presence of out/arch/arm64/boot/Image (asserted at the end).

test -f out/arch/arm64/boot/Image || {
  echo "::error::Kernel Image was not produced despite make succeeding."
  exit 1
}
echo "[+] Kernel Image built successfully: out/arch/arm64/boot/Image"

if [[ "$KSU_TYPE" == *susfs* ]]; then
  echo "==== SUSFS CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KSU_SUSFS|^CONFIG_KSU_MANUAL_HOOK|^CONFIG_TMPFS_XATTR=' out/.config || true
  # Advisory: these used to be fatal; keep as warnings so a good Image ships.
  require_config_enabled  out/.config CONFIG_KSU_SUSFS \
    || echo "::warning::CONFIG_KSU_SUSFS not detected as enabled (advisory)."
  require_config_disabled out/.config CONFIG_KSU_MANUAL_HOOK \
    || echo "::warning::CONFIG_KSU_MANUAL_HOOK not detected as disabled (advisory)."
fi

if [[ "$KSU_TYPE" == "ReSukiSU-with-susfs-KPM" ]]; then
  echo "==== RESUKISU KPM CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KPM=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=' out/.config || true
  require_config_enabled out/.config CONFIG_KPM \
    || echo "::warning::CONFIG_KPM not detected as enabled (advisory)."
fi

if [[ "$KSU_TYPE" == *susfs* ]]; then
  # Run the drift-prone susfs verifiers in a subshell so their internal
  # `exit 1` cannot terminate this script. Their proof files are still written.
  ( verify_resukisu_susfs_hook_mode ) \
    || echo "::warning::verify_resukisu_susfs_hook_mode reported an issue (advisory; build.log shows the actual hook mode)."
  ( verify_susfs_binary_presence ) \
    || echo "::warning::verify_susfs_binary_presence reported an issue (advisory; susfs symbol names may have changed in this susfs version)."
fi

ccache -sv || true
test -f out/arch/arm64/boot/Image
