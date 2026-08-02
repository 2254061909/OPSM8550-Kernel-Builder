#!/usr/bin/env bash
#
# Orchestrates the full kernel compile flow:
#   1. Set up cross-compile / ccache environment
#   2. Apply the requested KSU variant
#   3. Apply susfs patches (if requested)
#   4. Generate defconfig, merge config fragments, apply variant tweaks
#   5. Build Image
#   6. Patch Image with KPM loader (KPM variants only)
#   7. Run post-build verifications
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
if [[ "$KSU_TYPE" == *susfs* ]]; then
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

# Verify the guards actually stuck (olddefconfig could re-add / drop them).
if [[ "$KSU_TYPE" == *susfs* ]]; then
  if grep -q '^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y' out/.config; then
    echo "::error::CONFIG_KSU_SUSFS_OPEN_REDIRECT is still enabled after olddefconfig."
    exit 1
  fi
  echo "[+] Confirmed CONFIG_KSU_SUSFS_OPEN_REDIRECT is disabled in out/.config."
fi

if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  grep -q '^CONFIG_KPM=y' out/.config || {
    echo "::error::CONFIG_KPM did not survive olddefconfig; KPM would be a no-op."
    grep -E '^CONFIG_KSU|KPM' out/.config || true
    exit 1
  }
  grep -q '^CONFIG_KALLSYMS_ALL=y' out/.config || {
    echo "::error::CONFIG_KALLSYMS_ALL did not survive olddefconfig; KPM needs it."
    exit 1
  }
  echo "[+] Confirmed CONFIG_KPM=y and CONFIG_KALLSYMS_ALL=y in out/.config."
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

  # Sanity: a patched image must be strictly larger than the original.
  ORIG_SIZE="$(stat -c %s Image.unpatched)"
  PATCHED_SIZE="$(stat -c %s oImage)"
  if [[ "$PATCHED_SIZE" -le "$ORIG_SIZE" ]]; then
    echo "::error::oImage (${PATCHED_SIZE}) is not larger than Image (${ORIG_SIZE}); patch likely did nothing."
    popd >/dev/null
    exit 1
  fi

  mv -f oImage Image
  echo "[+] KPM patch applied: ${ORIG_SIZE} -> ${PATCHED_SIZE} bytes."
  popd >/dev/null
fi

# ---- Post-build checks -------------------------------------------------------
# Advisory self-diagnostics. susfs symbol names drift between releases, so
# these never fail a build that produced a valid Image.

if [[ "$KSU_TYPE" == *susfs* ]]; then
  echo "==== SUSFS CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KSU_SUSFS|^CONFIG_KSU_MANUAL_HOOK|^CONFIG_TMPFS_XATTR=' out/.config || true
  require_config_enabled  out/.config CONFIG_KSU_SUSFS \
    || echo "::warning::CONFIG_KSU_SUSFS not detected as enabled (advisory)."
fi

if [[ "$IS_KPM_BUILD" -eq 1 ]]; then
  echo "==== KPM CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KPM=|^CONFIG_KALLSYMS=|^CONFIG_KALLSYMS_ALL=' out/.config || true
fi

if [[ "$KSU_TYPE" == *susfs* ]]; then
  ( verify_resukisu_susfs_hook_mode ) \
    || echo "::warning::verify_resukisu_susfs_hook_mode reported an issue (advisory)."
  ( verify_susfs_binary_presence ) \
    || echo "::warning::verify_susfs_binary_presence reported an issue (advisory)."
fi

ccache -sv || true
test -f out/arch/arm64/boot/Image
