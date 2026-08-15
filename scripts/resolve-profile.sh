#!/usr/bin/env bash
# Resolve workflow_dispatch inputs into a concrete build profile.
set -euo pipefail

: "${INPUT_PLATFORM:?}"
: "${INPUT_SOURCE_CHOICE:?}"
: "${INPUT_BRANCH_MODE:?}"
: "${INPUT_CLANG_CHOICE:?}"
: "${MATRIX_KSU_TYPE:?}"
: "${GITHUB_ENV:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_STEP_SUMMARY:?}"

INPUT_KERNEL_BRANCH="${INPUT_KERNEL_BRANCH:-}"

# ---- Platform ----------------------------------------------------------------
case "$INPUT_PLATFORM" in
  "Xiaomi ingres (SM8450 / Redmi K50G / POCO F4 GT)")
    SOC="sm8450"
    PLATFORM_SLUG="ingres"
    PLATFORM_NAME="Xiaomi ingres (SM8450)"
    # Xiaomi ingres defconfig stack lives entirely inside the kernel tree.
    BUILD_CONFIGS="vendor/waipio_GKI.config vendor/xiaomi_GKI.config vendor/ingres_GKI.config vendor/debugfs.config"
    OFFICIAL_BUILD_TARGET="waipio"
    OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/ingres_GKI.config"
    RECOMMENDED_SOURCE="IngresCentre"
    ;;
  "Snapdragon 8 Gen 1 (SM8450 / OnePlus 10T / Ace Pro)")
    SOC="sm8450"
    PLATFORM_SLUG="8gen1"
    PLATFORM_NAME="Snapdragon 8 Gen 1"
    BUILD_CONFIGS="vendor/waipio_GKI.config vendor/oplus/waipio_GKI.config vendor/debugfs.config"
    OFFICIAL_BUILD_TARGET="waipio"
    OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/waipio_GKI.config"
    RECOMMENDED_SOURCE="lineage-ovaltine-dev"
    ;;
  "Snapdragon 8 Gen 2 (SM8550 / OnePlus 11 / 12R)")
    SOC="sm8550"
    PLATFORM_SLUG="8gen2"
    PLATFORM_NAME="Snapdragon 8 Gen 2"
    BUILD_CONFIGS="vendor/kalama_GKI.config vendor/oplus/kalama_GKI.config vendor/debugfs.config"
    OFFICIAL_BUILD_TARGET="kalama"
    OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/kalama_GKI.config"
    RECOMMENDED_SOURCE="LineageOS"
    ;;
  "Snapdragon 8 Gen 3 (SM8650 / OnePlus 12)")
    SOC="sm8650"
    PLATFORM_SLUG="8gen3"
    PLATFORM_NAME="Snapdragon 8 Gen 3"
    BUILD_CONFIGS="vendor/pineapple_GKI.config vendor/oplus/pineapple_GKI.config"
    OFFICIAL_BUILD_TARGET="pineapple"
    OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/pineapple_GKI.config"
    RECOMMENDED_SOURCE="LineageOS"
    ;;
  *)
    echo "::error::Unsupported platform: $INPUT_PLATFORM"
    exit 1
    ;;
esac

# ---- Source preset -----------------------------------------------------------
# ingres layout: single kernel tree (device trees + defconfig fragments in-tree),
# NO separate -modules repo. We reuse the vendor_dlkm modules already on device.
if [[ "$PLATFORM_SLUG" == "ingres" ]]; then
  SOURCE_LAYOUT="ingres-flat"
  KERNEL_SOURCE="IngresCentre"
  SOURCE_NAME="Ingres-Centre (Xiaomi ingres)"
  SOURCE_SLUG="ingres-centre"
else
case "$INPUT_SOURCE_CHOICE" in
  "Recommended source for this platform")
    KERNEL_SOURCE="$RECOMMENDED_SOURCE"
    SOURCE_LAYOUT="community-flat"
    ;;
  "OnePlus official source")
    KERNEL_SOURCE="OnePlusOSS"
    SOURCE_LAYOUT="oneplus-official"
    ;;
  "LineageOS / community source")
    SOURCE_LAYOUT="community-flat"
    case "$SOC" in
      sm8450) KERNEL_SOURCE="lineage-ovaltine-dev" ;;
      sm8550|sm8650) KERNEL_SOURCE="LineageOS" ;;
    esac
    ;;
  "crDroid source")
    SOURCE_LAYOUT="community-flat"
    if [[ "$SOC" == "sm8450" ]]; then
      echo "::error::crDroid source is not configured for Snapdragon 8 Gen 1 in this workflow yet."
      exit 1
    fi
    KERNEL_SOURCE="crdroidandroid"
    ;;
  "OnePlus 12R development source (SM8550 only)")
    SOURCE_LAYOUT="community-flat"
    if [[ "$SOC" != "sm8550" ]]; then
      echo "::error::OnePlus 12R development source is only available for Snapdragon 8 Gen 2 (SM8550)."
      exit 1
    fi
    KERNEL_SOURCE="OnePlus12R-development"
    ;;
  *)
    echo "::error::Unknown source choice: $INPUT_SOURCE_CHOICE"
    exit 1
    ;;
esac

case "$KERNEL_SOURCE" in
  "OnePlusOSS")             SOURCE_NAME="OnePlus official source";       SOURCE_SLUG="oneplus-official" ;;
  "LineageOS")              SOURCE_NAME="LineageOS";                     SOURCE_SLUG="lineageos" ;;
  "lineage-ovaltine-dev")   SOURCE_NAME="LineageOS community (ovaltine)"; SOURCE_SLUG="lineage-community" ;;
  "crdroidandroid")        SOURCE_NAME="crDroid";                       SOURCE_SLUG="crdroid" ;;
  "OnePlus12R-development") SOURCE_NAME="OnePlus 12R development";       SOURCE_SLUG="oneplus12r-dev" ;;
esac
fi

# ---- Clang preset ------------------------------------------------------------
case "$INPUT_CLANG_CHOICE" in
  "Recommended (auto-select based on branch)"               CLANG_VERSION="" ;;
  "clang-r563880c (Android 16 / LineageOS 23.2+ era)"       CLANG_VERSION="clang-r563880c" ;;
  "clang-r547379 (Android 16 / LineageOS 23.0 era)"         CLANG_VERSION="clang-r547379" ;;
  "clang-r536225 (Android 15 / LineageOS 22.2 era)"         CLANG_VERSION="clang-r536225" ;;
  "clang-r487747c (Android 14 / LineageOS 21 era)"          CLANG_VERSION="clang-r487747c" ;;
  "clang-r450784d (Android 13 / LineageOS 20 era)"          CLANG_VERSION="clang-r450784d" ;;
  "clang-r416183b1 (Android 12 / LineageOS 19.1 era)"       CLANG_VERSION="clang-r416183b1" ;;
  *)
    echo "::error::Unknown clang choice: $INPUT_CLANG_CHOICE"
    exit 1
    ;;
esac

KSU_TYPE="$MATRIX_KSU_TYPE"
SUSFS_REF=""
SUSFS_PATCH_FILE=""

# ---- Repo layout -------------------------------------------------------------
if [[ "$SOURCE_LAYOUT" == "ingres-flat" ]]; then
  KERNEL_REPO="https://github.com/Ingres-Centre/android_kernel_xiaomi_sm8450.git"
  MODULES_REPO=""
  KERNEL_CLONE_DIR="${SOC}"
  MODULES_CLONE_DIR=""
elif [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  KERNEL_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${SOC}.git"
  MODULES_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_modules_and_devicetree_oneplus_${SOC}.git"
  KERNEL_CLONE_DIR="${SOC}-modules/kernel_platform/msm-kernel"
  MODULES_CLONE_DIR="${SOC}-modules"
else
  KERNEL_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${SOC}.git"
  MODULES_REPO="https://github.com/${KERNEL_SOURCE}/android_kernel_oneplus_${SOC}-modules.git"
  KERNEL_CLONE_DIR="${SOC}"
  MODULES_CLONE_DIR="${SOC}-modules"
fi

# ---- Branch resolution -------------------------------------------------------
if [[ "$INPUT_BRANCH_MODE" == "Use the recommended branch automatically" ]]; then
  if [[ "$SOURCE_LAYOUT" == "ingres-flat" ]]; then
    KERNEL_BRANCH="lineage-23.0"
  else
    KERNEL_BRANCH="$(git ls-remote --symref "$KERNEL_REPO" HEAD | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')"
  fi
  if [[ -z "$KERNEL_BRANCH" ]]; then
    echo "::error::Could not detect the default branch from $KERNEL_REPO"
    exit 1
  fi
else
  KERNEL_BRANCH="$INPUT_KERNEL_BRANCH"
  if [[ -z "$KERNEL_BRANCH" ]]; then
    echo "::error::Please type a branch name when using manual branch mode."
    exit 1
  fi
fi

# ---- Clang auto-selection ----------------------------------------------------
if [[ -z "$CLANG_VERSION" ]]; then
  case "$KERNEL_BRANCH" in
    lineage-19.1*|oneplus/*_s_12.1*|oneplus/*_s_12.0*)
      CLANG_VERSION="clang-r416183b1" ;;
    lineage-20*|thirteen*|oneplus/*_t_13*|oneplus_*_t_13*)
      CLANG_VERSION="clang-r450784d" ;;
    lineage-21*|fourteen*|oneplus/*_u_14*|oneplus_*_u_14*)
      CLANG_VERSION="clang-r487747c" ;;
    lineage-22*|fifteen*|oneplus/*_v_15*|oneplus_*_v_15*)
      CLANG_VERSION="clang-r536225" ;;
    lineage-23.0*)
      CLANG_VERSION="clang-r547379" ;;
    16.0|lineage-23*|oneplus/*_b_16*|oneplus_*_b_16*)
      CLANG_VERSION="clang-r563880c" ;;
    *)
      CLANG_VERSION="clang-r563880c"
      echo "::warning::Could not confidently infer clang for '$KERNEL_BRANCH'. Falling back to $CLANG_VERSION."
      ;;
  esac
fi

# ---- susfs reference ---------------------------------------------------------
if [[ "$KSU_TYPE" == *susfs* ]]; then
  case "$SOC" in
    sm8450) SUSFS_REF="gki-android13-5.10" ;;
    sm8550)
      case "$KERNEL_BRANCH" in
        lineage-20*|thirteen*|android13*|13.*|oneplus/*_t_13*|oneplus_*_t_13*)
          SUSFS_REF="gki-android13-5.15" ;;
        *) SUSFS_REF="gki-android14-5.15" ;;
      esac ;;
    sm8650) SUSFS_REF="gki-android14-6.1" ;;
    *) echo "::error::No susfs mapping for $SOC"; exit 1 ;;
  esac
  SUSFS_PATCH_FILE="50_add_susfs_in_${SUSFS_REF}.patch"
fi

# ---- Repo/branch availability checks -----------------------------------------
if ! git ls-remote --exit-code --heads "$KERNEL_REPO" "$KERNEL_BRANCH" >/dev/null 2>&1; then
  echo "::error::Branch '$KERNEL_BRANCH' was not found in $KERNEL_REPO"
  exit 1
fi

# ingres layout has no separate modules repo; skip that check.
if [[ "$SOURCE_LAYOUT" != "ingres-flat" ]]; then
  if ! git ls-remote --exit-code --heads "$MODULES_REPO" "$KERNEL_BRANCH" >/dev/null 2>&1; then
    echo "::error::Branch '$KERNEL_BRANCH' was not found in $MODULES_REPO"
    exit 1
  fi
fi

# ---- Export to GITHUB_ENV ----------------------------------------------------
{
  echo "SOC=$SOC"
  echo "PLATFORM_SLUG=$PLATFORM_SLUG"
  echo "PLATFORM_NAME=$PLATFORM_NAME"
  echo "BUILD_CONFIGS=$BUILD_CONFIGS"
  echo "SOURCE_LAYOUT=$SOURCE_LAYOUT"
  echo "KERNEL_SOURCE=$KERNEL_SOURCE"
  echo "SOURCE_NAME=$SOURCE_NAME"
  echo "SOURCE_SLUG=$SOURCE_SLUG"
  echo "KERNEL_REPO=$KERNEL_REPO"
  echo "MODULES_REPO=$MODULES_REPO"
  echo "KERNEL_CLONE_DIR=$KERNEL_CLONE_DIR"
  echo "MODULES_CLONE_DIR=$MODULES_CLONE_DIR"
  echo "OFFICIAL_BUILD_TARGET=$OFFICIAL_BUILD_TARGET"
  echo "OFFICIAL_GKI_FRAGMENT=$OFFICIAL_GKI_FRAGMENT"
  echo "KERNEL_BRANCH=$KERNEL_BRANCH"
  echo "CLANG_VERSION=$CLANG_VERSION"
  echo "KSU_TYPE=$KSU_TYPE"
  echo "SUSFS_REF=$SUSFS_REF"
  echo "SUSFS_PATCH_FILE=$SUSFS_PATCH_FILE"
} >> "$GITHUB_ENV"

{
  echo "soc=$SOC"
  echo "platform_slug=$PLATFORM_SLUG"
  echo "platform_name=$PLATFORM_NAME"
  echo "kernel_source=$KERNEL_SOURCE"
  echo "source_name=$SOURCE_NAME"
  echo "source_slug=$SOURCE_SLUG"
  echo "source_layout=$SOURCE_LAYOUT"
  echo "kernel_branch=$KERNEL_BRANCH"
  echo "clang_version=$CLANG_VERSION"
  echo "ksu_type=$KSU_TYPE"
  echo "susfs_ref=$SUSFS_REF"
} >> "$GITHUB_OUTPUT"

{
  echo "### Build profile"
  echo "- Platform: $PLATFORM_NAME ($SOC)"
  echo "- Source: $SOURCE_NAME"
  echo "- Branch: $KERNEL_BRANCH"
  echo "- Clang: $CLANG_VERSION"
  echo "- Root solution: $KSU_TYPE"
  [[ -n "$SUSFS_REF" ]] && echo "- susfs branch: $SUSFS_REF"
} >> "$GITHUB_STEP_SUMMARY"
