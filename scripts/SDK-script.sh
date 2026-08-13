#!/usr/bin/env bash
set -Eeuo pipefail

ARGON_REPO="${ARGON_REPO:-https://github.com/jerrykuku/luci-theme-argon}"
ARGON_CONFIG_REPO="${ARGON_CONFIG_REPO:-https://github.com/jerrykuku/luci-app-argon-config}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
OPENWRT_TARGET_PROFILE="${OPENWRT_TARGET_PROFILE:-}"
OPENWRT_DOWNLOADS_BASE_URL="${OPENWRT_DOWNLOADS_BASE_URL:-https://downloads.openwrt.org}"
OPENWRT_SDK_VERSION="${OPENWRT_SDK_VERSION:-${SDK_VERSION:-main}}"
OPENWRT_SDK_BASE_URL="${OPENWRT_SDK_BASE_URL:-}"
SDK_URL="${SDK_URL:-}"
PACKAGE_CONFIG_FILES="${PACKAGE_CONFIG_FILES:-${CONFIG_FILES:-configs/x86-64.config configs/Packages.config}}"
unset CONFIG_FILES
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
SDK_ROOT="${SDK_ROOT:-$RUNNER_TEMP/openwrt-sdk}"
OUTPUT_DIR="${OUTPUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/artifacts/packages}"
PACKAGE_ARCH_NAME="${PACKAGE_ARCH_NAME:-$OPENWRT_TARGET-$OPENWRT_SUBTARGET}"
PACKAGE_SELECTED_ARCH="${PACKAGE_SELECTED_ARCH:-$PACKAGE_ARCH_NAME}"
PACKAGE_SELECTION="${PACKAGE_SELECTION:-${PACKAGE_NAME:-all}}"
SDK_ARCHIVE="$RUNNER_TEMP/openwrt-sdk.tarball"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

COMPILE_TARGETS=()
CONFIG_FILE_LIST=()
ARTIFACT_PACKAGE_NAMES=()

log() {
  printf '\n==> %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

normalize_package_selection() {
  local selection="${1:-all}"

  selection="${selection,,}"
  case "$selection" in
    "" | all | "全部")
      printf 'all\n'
      ;;
    wireguard | argon | banip | ddns | tailscale | dmesg | htop | nano)
      printf '%s\n' "$selection"
      ;;
    luci-proto-wireguard | wireguard-tools)
      printf 'wireguard\n'
      ;;
    luci-theme-argon | luci-app-argon-config)
      printf 'argon\n'
      ;;
    luci-app-banip)
      printf 'banip\n'
      ;;
    luci-app-ddns | ddns-scripts | ddns-scripts-cloudflare)
      printf 'ddns\n'
      ;;
    *)
      die "Unsupported PACKAGE_SELECTION: ${1:-} (supported: all, wireguard, argon, banip, ddns, tailscale, dmesg, htop, nano)"
      ;;
  esac
}

normalize_sdk_version() {
  local version="${1:-main}"

  version="${version,,}"
  case "$version" in
    "" | main | snapshot | snapshots | master)
      printf 'main\n'
      ;;
    23.05 | 24.10 | 25.12)
      printf '%s\n' "$version"
      ;;
    *)
      die "Unsupported OPENWRT_SDK_VERSION: ${1:-} (supported: main, 23.05, 24.10, 25.12)"
      ;;
  esac
}

load_inline_target_profile() {
  local profile="${1:-}"

  [ -n "$profile" ] || return 0

  case "$profile" in
    rax3000m | cmcc-rax3000m | cmcc_rax3000m)
      [ "$OPENWRT_TARGET" = mediatek ] && [ "$OPENWRT_SUBTARGET" = filogic ] ||
        die "OPENWRT_TARGET_PROFILE=$profile requires OPENWRT_TARGET=mediatek and OPENWRT_SUBTARGET=filogic"
      cat >> "$SDK_ROOT/.config" <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_cmcc_rax3000m=y
EOF
      ;;
    *)
      die "Unsupported OPENWRT_TARGET_PROFILE: $profile (supported: rax3000m)"
      ;;
  esac
}

selection_is_all() {
  [ "$PACKAGE_SELECTION" = all ]
}

selection_is() {
  [ "$PACKAGE_SELECTION" = "$1" ]
}

selection_in() {
  local package_name

  selection_is_all && return 0

  for package_name in "$@"; do
    selection_is "$package_name" && return 0
  done

  return 1
}

resolve_sdk_url() {
  local sdk_base_url
  local sdk_href

  if [ -n "$SDK_URL" ]; then
    printf '%s\n' "$SDK_URL"
    return
  fi

  sdk_base_url="$(resolve_sdk_base_url)"
  log "Resolve OpenWrt $OPENWRT_SDK_VERSION SDK for $OPENWRT_TARGET/$OPENWRT_SUBTARGET"
  sdk_href="$(
    curl -fsSL "${sdk_base_url%/}/" |
      grep -oE 'href="[^"]*openwrt-sdk-[^"]+\.tar\.(xz|zst|gz)"' |
      sed -E 's/^href="([^"]+)"/\1/' |
      head -n 1 || true
  )"

  [ -n "$sdk_href" ] || die "OpenWrt SDK archive was not found at $sdk_base_url"

  case "$sdk_href" in
    http://* | https://*)
      printf '%s\n' "$sdk_href"
      ;;
    /*)
      printf '%s%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$sdk_href"
      ;;
    *)
      printf '%s/%s\n' "${sdk_base_url%/}" "$sdk_href"
      ;;
  esac
}

resolve_sdk_base_url() {
  local release_version
  local sdk_version

  if [ -n "$OPENWRT_SDK_BASE_URL" ]; then
    printf '%s\n' "$OPENWRT_SDK_BASE_URL"
    return
  fi

  sdk_version="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"
  if [ "$sdk_version" = main ]; then
    printf '%s/snapshots/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
    return
  fi

  release_version="$(resolve_latest_release_version "$sdk_version")"
  printf '%s/releases/%s/targets/%s/%s\n' "${OPENWRT_DOWNLOADS_BASE_URL%/}" "$release_version" "$OPENWRT_TARGET" "$OPENWRT_SUBTARGET"
}

resolve_latest_release_version() {
  local release_version
  local series="$1"

  release_version="$(
    curl -fsSL "${OPENWRT_DOWNLOADS_BASE_URL%/}/releases/" |
      grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' |
      sed -E 's/^href="([^"]+)\/"/\1/' |
      grep -E "^${series//./\\.}(\\.[0-9]+)?$" |
      sort -V |
      tail -n 1 || true
  )"

  [ -n "$release_version" ] || die "OpenWrt release series was not found: $series"
  printf '%s\n' "$release_version"
}

download_sdk() {
  local resolved_url="$1"

  case "$resolved_url" in
    file://*)
      cp "${resolved_url#file://}" "$SDK_ARCHIVE"
      ;;
    /*)
      cp "$resolved_url" "$SDK_ARCHIVE"
      ;;
    *)
      curl -fsSL --retry 3 "$resolved_url" -o "$SDK_ARCHIVE"
      ;;
  esac
}

extract_sdk() {
  local resolved_url="$1"
  local archive_name
  archive_name="${resolved_url%%\?*}"

  mkdir -p "$SDK_ROOT"
  case "$archive_name" in
    *.tar.zst | *.tzst)
      tar --zstd -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.xz | *.txz)
      tar -xJf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *.tar.gz | *.tgz)
      tar -xzf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
    *)
      tar -xf "$SDK_ARCHIVE" --strip-components=1 -C "$SDK_ROOT"
      ;;
  esac
}

git_clone_package_repo() {
  local repourl="$1"
  local target_path="$2"
  local makefile_path
  shift 2

  rm -rf "$target_path"
  git clone \
    --depth=1 \
    --no-tags \
    "$repourl" \
    "$target_path"

  for makefile_path in "$@"; do
    [ -f "$target_path/$makefile_path" ] || die "Package Makefile not found: $target_path/$makefile_path"
  done
}

load_custom_packages() {
  rm -rf \
    "$SDK_ROOT/feeds/luci/themes/luci-theme-argon" \
    "$SDK_ROOT/feeds/luci/applications/luci-app-argon-config"
  git_clone_package_repo "$ARGON_REPO" "$SDK_ROOT/package/luci-theme-argon" Makefile
  git_clone_package_repo "$ARGON_CONFIG_REPO" "$SDK_ROOT/package/luci-app-argon-config" Makefile
}

prune_luci_translations() {
  local lang_dir
  local lang_name
  local po_dir
  local removed_count=0
  local root_dir

  for root_dir in \
    "$SDK_ROOT/package/luci-app-argon-config" \
    "$SDK_ROOT/package/luci-theme-argon" \
    "$SDK_ROOT/package/feeds/luci" \
    "$SDK_ROOT/feeds/luci/applications"; do
    [ -d "$root_dir" ] || continue

    while IFS= read -r -d '' po_dir; do
      while IFS= read -r -d '' lang_dir; do
        lang_name="$(basename "$lang_dir")"
        case "$lang_name" in
          templates | zh_Hans | zh_Hant)
            ;;
          *)
            rm -rf "$lang_dir"
            removed_count=$((removed_count + 1))
            ;;
        esac
      done < <(find "$po_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    done < <(find "$root_dir" -type d -name po -print0)
  done

  log "Pruned LuCI translations: kept zh_Hans and zh_Hant, removed $removed_count other language directories"
}

normalize_config_files() {
  printf '%s\n' "$PACKAGE_CONFIG_FILES" |
    sed -e 's/\r$//' -e 's/#.*$//' |
    tr ',[:space:]' '\n' |
    sed -e '/^$/d'
}

load_config_files() {
  local config_file
  local source_file

  : > "$SDK_ROOT/.config"
  load_inline_target_profile "$OPENWRT_TARGET_PROFILE"
  mapfile -t CONFIG_FILE_LIST < <(normalize_config_files)

  [ "${#CONFIG_FILE_LIST[@]}" -gt 0 ] || die "PACKAGE_CONFIG_FILES did not contain any config file"

  for config_file in "${CONFIG_FILE_LIST[@]}"; do
    if [ -f "$config_file" ]; then
      source_file="$config_file"
    else
      source_file="$WORKSPACE/$config_file"
    fi

    [ -f "$source_file" ] || die "Config file not found: $config_file"
    cat "$source_file" >> "$SDK_ROOT/.config"
    printf '\n' >> "$SDK_ROOT/.config"
  done
}

config_package_enabled() {
  local package_name="$1"

  grep -Eq "^CONFIG_PACKAGE_${package_name}=(y|m)$" "$SDK_ROOT/.config"
}

add_compile_target() {
  local compile_target="$1"
  local existing_target

  for existing_target in "${COMPILE_TARGETS[@]}"; do
    [ "$existing_target" != "$compile_target" ] || return
  done

  COMPILE_TARGETS+=("$compile_target")
}

add_artifact_package() {
  local package_name="$1"
  local existing_package

  for existing_package in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    [ "$existing_package" != "$package_name" ] || return
  done

  ARTIFACT_PACKAGE_NAMES+=("$package_name")
}

add_luci_i18n_packages() {
  local app_name="$1"

  add_artifact_package "luci-i18n-${app_name}-zh-cn"
  add_artifact_package "luci-i18n-${app_name}-zh-tw"
}

generate_artifact_filters() {
  ARTIFACT_PACKAGE_NAMES=()

  if selection_in wireguard; then
    config_package_enabled wireguard-tools && add_artifact_package wireguard-tools
    config_package_enabled luci-proto-wireguard && add_artifact_package luci-proto-wireguard
  fi

  if selection_in argon; then
    config_package_enabled luci-theme-argon && add_artifact_package luci-theme-argon
    config_package_enabled luci-app-argon-config && add_artifact_package luci-app-argon-config
    add_luci_i18n_packages argon-config
  fi

  if selection_in banip; then
    config_package_enabled luci-app-banip && add_artifact_package banip
    config_package_enabled luci-app-banip && add_artifact_package luci-app-banip
    add_luci_i18n_packages banip
  fi

  if selection_in ddns; then
    config_package_enabled ddns-scripts && add_artifact_package ddns-scripts
    config_package_enabled ddns-scripts-cloudflare && add_artifact_package ddns-scripts-cloudflare
    config_package_enabled luci-app-ddns && add_artifact_package luci-app-ddns
    add_luci_i18n_packages ddns
  fi

  selection_in tailscale && config_package_enabled tailscale && add_artifact_package tailscale
  selection_in dmesg && config_package_enabled dmesg && add_artifact_package dmesg
  selection_in htop && config_package_enabled htop && add_artifact_package htop
  selection_in nano && config_package_enabled nano && add_artifact_package nano

  [ "${#ARTIFACT_PACKAGE_NAMES[@]}" -gt 0 ] || die "No package artifact filters were generated for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

artifact_package_allowed() {
  local package_file_name="$1"
  local package_name

  for package_name in "${ARTIFACT_PACKAGE_NAMES[@]}"; do
    package_file_matches_name "$package_file_name" "$package_name" && return 0
  done

  return 1
}

package_file_matches_name() {
  local package_file_name="$1"
  local package_name="$2"

  case "$package_file_name" in
    "${package_name}_"* | "${package_name}-"[0-9]* | "${package_name}-git"* | "${package_name}-v"[0-9]*)
      return 0
      ;;
  esac

  return 1
}

artifact_package_group() {
  local package_file_name="$1"

  if package_file_matches_name "$package_file_name" wireguard-tools ||
    package_file_matches_name "$package_file_name" luci-proto-wireguard; then
    printf 'wireguard\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" luci-theme-argon ||
    package_file_matches_name "$package_file_name" luci-app-argon-config ||
    package_file_matches_name "$package_file_name" luci-i18n-argon-config-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-argon-config-zh-tw; then
    printf 'argon\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" banip ||
    package_file_matches_name "$package_file_name" luci-app-banip ||
    package_file_matches_name "$package_file_name" luci-i18n-banip-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-banip-zh-tw; then
    printf 'banip\n'
    return 0
  fi

  if package_file_matches_name "$package_file_name" ddns-scripts ||
    package_file_matches_name "$package_file_name" ddns-scripts-cloudflare ||
    package_file_matches_name "$package_file_name" luci-app-ddns ||
    package_file_matches_name "$package_file_name" luci-i18n-ddns-zh-cn ||
    package_file_matches_name "$package_file_name" luci-i18n-ddns-zh-tw; then
    printf 'ddns\n'
    return 0
  fi

  package_file_matches_name "$package_file_name" tailscale && { printf 'tailscale\n'; return 0; }
  package_file_matches_name "$package_file_name" dmesg && { printf 'dmesg\n'; return 0; }
  package_file_matches_name "$package_file_name" htop && { printf 'htop\n'; return 0; }
  package_file_matches_name "$package_file_name" nano && { printf 'nano\n'; return 0; }

  return 1
}

release_package_name() {
  local package_file="$1"
  local group_name="$2"
  local package_arch
  local package_release_name
  local package_file_name
  local safe_package_name
  local sdk_prefix

  package_file_name="$(basename "$package_file")"
  safe_package_name="${package_file_name//\~/-}"
  package_arch="$(release_package_arch_suffix "$group_name")"
  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")-"

  case "$safe_package_name" in
    *.apk)
      package_release_name="${safe_package_name%.apk}-$package_arch.apk"
      ;;
    *_all.ipk)
      package_release_name="${safe_package_name%_all.ipk}_$package_arch.ipk"
      ;;
    *.ipk)
      local package_path_arch
      package_path_arch="$(basename "$(dirname "$(dirname "$package_file")")")"
      case "$safe_package_name" in
        *_"$package_path_arch".ipk)
          package_release_name="${safe_package_name%_"$package_path_arch".ipk}_$package_arch.ipk"
          ;;
        *)
          package_release_name="${safe_package_name%.ipk}_$package_arch.ipk"
          ;;
      esac
      ;;
    *)
      package_release_name="$safe_package_name"
      ;;
  esac

  case "$package_release_name" in
    main-* | 23.05-* | 24.10-* | 25.12-*)
      printf '%s\n' "$package_release_name"
      ;;
    *)
      printf '%s%s\n' "$sdk_prefix" "$package_release_name"
      ;;
  esac
}

release_package_arch_suffix() {
  local group_name="$1"

  if [ "$group_name" = argon ]; then
    printf 'all\n'
    return
  fi

  printf '%s\n' "${PACKAGE_ARCH_NAME//\//-}"
}

artifact_zip_name() {
  local group_name="$1"
  local safe_arch_name="${PACKAGE_ARCH_NAME//\//-}"
  local sdk_prefix

  sdk_prefix="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

  if [ "$group_name" = argon ]; then
    printf '%s-%s-all.zip\n' "$sdk_prefix" "$group_name"
    return
  fi

  printf '%s-%s-%s.zip\n' "$sdk_prefix" "$group_name" "$safe_arch_name"
}

artifact_group_should_be_skipped() {
  local group_name="$1"

  [ "$group_name" = argon ] || return 1
  [ "$PACKAGE_SELECTED_ARCH" = ALL ] || return 1
  [ "$PACKAGE_ARCH_NAME" != x86-64 ]
}

generate_compile_targets() {
  COMPILE_TARGETS=()

  selection_in wireguard && config_package_enabled wireguard-tools && add_compile_target package/feeds/base/wireguard-tools/compile
  selection_in wireguard && config_package_enabled luci-proto-wireguard && add_compile_target package/feeds/luci/luci-proto-wireguard/compile
  if selection_in argon && ! artifact_group_should_be_skipped argon; then
    config_package_enabled luci-theme-argon && add_compile_target package/luci-theme-argon/compile
    config_package_enabled luci-app-argon-config && add_compile_target package/luci-app-argon-config/compile
  fi
  selection_in banip && config_package_enabled luci-app-banip && add_compile_target package/feeds/packages/banip/compile
  selection_in banip && config_package_enabled luci-app-banip && add_compile_target package/feeds/luci/luci-app-banip/compile
  selection_in ddns && config_package_enabled ddns-scripts && add_compile_target package/feeds/packages/ddns-scripts/compile
  selection_in ddns && config_package_enabled luci-app-ddns && add_compile_target package/feeds/luci/luci-app-ddns/compile
  selection_in tailscale && config_package_enabled tailscale && add_compile_target package/feeds/packages/tailscale/compile
  selection_in dmesg && config_package_enabled dmesg && add_compile_target package/feeds/base/util-linux/compile
  selection_in htop && config_package_enabled htop && add_compile_target package/feeds/packages/htop/compile
  selection_in nano && config_package_enabled nano && add_compile_target package/feeds/packages/nano/compile

  [ "${#COMPILE_TARGETS[@]}" -gt 0 ] || die "No matching package compile targets were enabled by $PACKAGE_CONFIG_FILES for PACKAGE_SELECTION=$PACKAGE_SELECTION"
}

copy_artifacts() {
  local package_bin_dir="$SDK_ROOT/bin/packages"
  local copied_count=0
  local group_dir
  local group_name
  local groups=()
  local -A group_counts=()
  local package_file
  local package_file_name
  local release_name
  local skipped_count=0
  local staging_dir="$RUNNER_TEMP/package-artifact-groups"
  local target_file
  local zip_count=0
  local zip_file

  if [ ! -d "$package_bin_dir" ]; then
    die "SDK package output directory was not created: $package_bin_dir"
  fi

  if [ -z "$(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print -quit)" ]; then
    die "No compiled .ipk or .apk files were found under $package_bin_dir"
  fi

  command -v zip >/dev/null 2>&1 || die "zip command was not found"

  rm -rf "$OUTPUT_DIR" "$staging_dir"
  mkdir -p "$OUTPUT_DIR" "$staging_dir"
  while IFS= read -r -d '' package_file; do
    package_file_name="$(basename "$package_file")"
    if ! artifact_package_allowed "$package_file_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    group_name="$(artifact_package_group "$package_file_name")" ||
      die "No artifact group was found for package file: $package_file_name"
    if artifact_group_should_be_skipped "$group_name"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [ -z "${group_counts[$group_name]+set}" ]; then
      group_counts[$group_name]=0
      groups+=("$group_name")
    fi

    group_dir="$staging_dir/$group_name"
    mkdir -p "$group_dir"

    release_name="$(release_package_name "$package_file" "$group_name")"
    target_file="$group_dir/$release_name"
    [ ! -e "$target_file" ] || die "Duplicate package artifact name: $target_file"
    cp -a "$package_file" "$target_file"
    group_counts[$group_name]=$((group_counts[$group_name] + 1))
    copied_count=$((copied_count + 1))
  done < <(find "$package_bin_dir" -type f \( -name '*.ipk' -o -name '*.apk' \) -print0)

  [ "$copied_count" -gt 0 ] || die "No selected package files were copied from $package_bin_dir"

  for group_name in "${groups[@]}"; do
    group_dir="$staging_dir/$group_name"
    [ "${group_counts[$group_name]}" -gt 0 ] || die "No files were staged for artifact group: $group_name"

    zip_file="$OUTPUT_DIR/$(artifact_zip_name "$group_name")"
    [ ! -e "$zip_file" ] || die "Duplicate package zip artifact name: $zip_file"
    (
      cd "$group_dir"
      zip -q -r "$zip_file" .
    )
    zip_count=$((zip_count + 1))
  done

  rm -rf "$staging_dir"
  log "Packed $copied_count selected package files into $zip_count grouped zip files under $OUTPUT_DIR; skipped $skipped_count dependency files"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "PACKAGE_OUTPUT_DIR=$OUTPUT_DIR" >> "$GITHUB_ENV"
    echo "RESOLVED_SDK_URL=$RESOLVED_SDK_URL" >> "$GITHUB_ENV"
  fi
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

PACKAGE_SELECTION="$(normalize_package_selection "$PACKAGE_SELECTION")"
OPENWRT_SDK_VERSION="$(normalize_sdk_version "$OPENWRT_SDK_VERSION")"

log "Download OpenWrt SDK"
log "Selected package group: $PACKAGE_SELECTION"
log "Selected OpenWrt SDK version: $OPENWRT_SDK_VERSION"
RESOLVED_SDK_URL="$(resolve_sdk_url)"
rm -rf "$SDK_ROOT"
mkdir -p "$RUNNER_TEMP"
download_sdk "$RESOLVED_SDK_URL"
extract_sdk "$RESOLVED_SDK_URL"
[ -x "$SDK_ROOT/scripts/feeds" ] || die "Invalid SDK archive: scripts/feeds was not found"
[ -f "$SDK_ROOT/Makefile" ] || die "Invalid SDK archive: Makefile was not found"

log "Update SDK feeds"
cd "$SDK_ROOT"
./scripts/feeds update -a

log "Load custom packages"
load_custom_packages

log "Refresh SDK feed indexes"
./scripts/feeds update -i -a

log "Install SDK feeds"
./scripts/feeds install -a
prune_luci_translations

log "Load package config"
load_config_files
make defconfig
generate_compile_targets
generate_artifact_filters

log "Compile packages"
for compile_target in "${COMPILE_TARGETS[@]}"; do
  make -j"$(nproc)" "$compile_target" || make -j1 "$compile_target" V=s
done

log "Collect package artifacts"
copy_artifacts
