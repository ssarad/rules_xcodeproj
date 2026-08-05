#!/bin/bash

set -euo pipefail

shopt -s nullglob

# Echos the provided message to stderr and exits with an error (1)
fail() {
  local msg="${1:-}"
  shift 1
  while (("$#")); do
    msg="${msg:-}"$'\n'"${1}"
    shift 1
  done
  echo >&2 "${msg}"
  exit 1
}

# Process Args

separate_indexbuild_output_base=0

while (("$#")); do
  case "${1}" in
    "--bazel_env")
      bazel_env="${2}"
      shift 2
      ;;
    "--bazel_path")
      bazel_path="${2}"
      shift 2
      ;;
    "--xcodeproj_bazelrc")
      xcodeproj_bazelrc="${2}"
      shift 2
      ;;
    "--destination")
      dest="${2}"
      shift 2
      ;;
    "--execution_root")
      execution_root="${2}"
      shift 2
      ;;
    "--extra_flags_bazelrc")
      extra_flags_bazelrc="${2}"
      shift 2
      ;;
    "--separate_indexbuild_output_base")
      separate_indexbuild_output_base=1
      shift 1
      ;;
    *)
      fail "Unrecognized argument: ${1}"
      ;;
  esac
done

if [[ -z "${bazel_env:-}" ]]; then
  fail "Missing required argument: --bazel_env"
fi
if [[ -z "${bazel_path:-}" ]]; then
  fail "Missing required argument: --bazel_path"
fi
if [[ -z "${execution_root:-}" ]]; then
  fail "Missing required argument: --execution_root"
fi

# Resolve the inputs
readonly src_generated_xcfilelist="$PWD/%generated_xcfilelist%"
readonly src_generated_directories_filelist="$PWD/%generated_directories_filelist%"
readonly src_project_pbxproj="$PWD/%project_pbxproj%"
readonly src_rsync="$PWD/%rsync%"
readonly src_xcschememanagement="$PWD/%xcschememanagement%"
readonly src_xcschemes="$PWD/%xcschemes%/"
readonly src_xcworkspacedata="$PWD/%contents_xcworkspacedata%"
readonly toolchain_name="%toolchain_name%"

# Resolve the destination
[[ -z "${dest:-}" ]] \
  && [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]] \
  && dest="$BUILD_WORKSPACE_DIRECTORY/%output_path%"
[[ -n "${dest:-}" ]] || fail "A destination for the Xcode project was not set"
dest_dir="$(dirname "${dest}")"
[[ -d "${dest_dir}" ]] || \
  fail "The destination directory does not exist or is not a directory" \
    "${dest_dir}"

# Copy over `xcschemes`
readonly dest_xcschemes="$dest/xcshareddata/xcschemes"

mkdir -p "$dest_xcschemes"

if [[ $(uname) == "Darwin" ]]; then
  is_macos=1
  readonly rsync="$src_rsync"
else
  is_macos=0
  readonly rsync="$(command -v rsync || true)"
  [[ -n "$rsync" ]] || fail \
    "Failed to locate host rsync." \
    "rules_xcodeproj's bundled rsync is only supported on macOS project generation."
fi

"$rsync" \
  --archive \
  --perms \
  --chmod=u+w,F-x \
  --delete \
  "$src_xcschemes" "$dest_xcschemes/"

# Resolve the copy command (can't use `cp -c` if the files are on different
# filesystems, or on Linux)
if [[ $is_macos -eq 1 &&
      $(stat -f '%d' "$src_xcschemes") == $(stat -f '%d' "$dest_xcschemes") ]]
then
  readonly cp_cmd="cp -c"
else
  readonly cp_cmd="cp"
fi

# Copy over `project.pbxproj`
readonly dest_project_pbxproj="$dest/project.pbxproj"

$cp_cmd "$src_project_pbxproj" "$dest_project_pbxproj"
chmod +w "$dest_project_pbxproj"

# Copy over bazel integration files
readonly bazel_integration_files=%bazel_integration_files%
readonly bazel_integration_dir="$dest/rules_xcodeproj/bazel"
readonly staged_bazel_integration_dir="$dest/rules_xcodeproj/.bazel.$$.tmp"

rm -rf "$staged_bazel_integration_dir"
mkdir -p "$bazel_integration_dir" "$staged_bazel_integration_dir"
$cp_cmd "${bazel_integration_files[@]}" "$staged_bazel_integration_dir"
$cp_cmd "$bazel_env" "$staged_bazel_integration_dir/bazel_env.sh"
$cp_cmd "$xcodeproj_bazelrc" \
  "$staged_bazel_integration_dir/xcodeproj.bazelrc"
$cp_cmd "$staged_bazel_integration_dir/ld" \
  "$staged_bazel_integration_dir/clang"
chmod u+rx "$staged_bazel_integration_dir/rsync"

if [[ -s "${extra_flags_bazelrc:-}" ]]; then
  $cp_cmd "$extra_flags_bazelrc" \
    "$staged_bazel_integration_dir/xcodeproj_extra_flags.bazelrc"
else
  rm -f "$bazel_integration_dir/xcodeproj_extra_flags.bazelrc"
fi

chmod u+w "$staged_bazel_integration_dir/"*

# Keep only scripts as runnable before exposing them through the toolchain.
find "$staged_bazel_integration_dir" \
  -type f \( -name "*.sh" -o -name "*.py" -o -name "clang" -o -name "ld" -o -name "libtool" -o -name "rsync" \) \
  -print0 | xargs -0 chmod u+x
find "$staged_bazel_integration_dir" \
  -type f ! \( -name "swiftc" -o -name "clang" -o -name "ld" -o -name "libtool" -o -name "import_indexstores" -o -name "rsync" -o -name "*.sh" -o -name "*.py" \) \
  -print0 | xargs -0 chmod -x

for path in "$staged_bazel_integration_dir/"*; do
  mv -f "$path" "$bazel_integration_dir/${path##*/}"
done
rmdir "$staged_bazel_integration_dir"

if [[ $is_macos -eq 1 ]]; then
  readonly default_toolchain="$(
    xcrun --toolchain XcodeDefault --find swiftc |
      sed 's|/usr/bin/swiftc$||'
  )"
  readonly toolchain="$dest/rules_xcodeproj/$toolchain_name.xctoolchain"
  readonly toolchain_bin="$toolchain/usr/bin"

  mkdir -p "$toolchain_bin"

  for path in "$default_toolchain/usr/"*; do
    [[ "${path##*/}" == "bin" ]] && continue
    ln -sfn "$path" "$toolchain/usr/${path##*/}"
  done

  for path in "$default_toolchain/usr/bin/"*; do
    case "${path##*/}" in
      c++|cc|clang|clang++|ld|libtool|swiftc|swift-frontend)
        ;;
      *)
        ln -sfn "$path" "$toolchain_bin/${path##*/}"
        ;;
    esac
  done

  ln -sfn "$dest/rules_xcodeproj/bazel/clang.sh" "$toolchain_bin/clang"
  ln -sfn clang "$toolchain_bin/clang++"
  ln -sfn clang "$toolchain_bin/cc"
  ln -sfn clang "$toolchain_bin/c++"
  ln -sfn "$default_toolchain/usr/bin/clang" \
    "$toolchain_bin/rules_xcodeproj_default_clang"
  ln -sfn "$default_toolchain/usr/bin/ld" \
    "$toolchain_bin/rules_xcodeproj_default_ld"
  ln -sfn "$dest/rules_xcodeproj/bazel/ld" "$toolchain_bin/ld"
  ln -sfn "$dest/rules_xcodeproj/bazel/libtool" "$toolchain_bin/libtool"
  ln -sfn "$dest/rules_xcodeproj/bazel/swiftc" "$toolchain_bin/swiftc"
  ln -sfn swiftc "$toolchain_bin/swift-frontend"

  cp "$default_toolchain/ToolchainInfo.plist" "$toolchain/ToolchainInfo.plist"
  plutil -replace CFBundleIdentifier \
    -string "com.rules-xcodeproj.$toolchain_name" \
    "$toolchain/ToolchainInfo.plist"
  plutil -replace Identifier \
    -string "com.rules-xcodeproj.$toolchain_name" \
    "$toolchain/ToolchainInfo.plist"
  plutil -replace DisplayName -string "$toolchain_name" \
    "$toolchain/ToolchainInfo.plist"
  plutil -replace ShortDisplayName -string "$toolchain_name" \
    "$toolchain/ToolchainInfo.plist"
  plutil -remove CompatibilityVersion \
    "$toolchain/ToolchainInfo.plist" > /dev/null 2>&1 || true
  plutil -insert CompatibilityVersion -integer 2 \
    "$toolchain/ToolchainInfo.plist"
  plutil -remove Version \
    "$toolchain/ToolchainInfo.plist" > /dev/null 2>&1 || true
  plutil -insert Version -string "1.0" \
    "$toolchain/ToolchainInfo.plist"
  cp "$toolchain/ToolchainInfo.plist" "$toolchain/Info.plist"

  readonly user_toolchains="$HOME/Library/Developer/Toolchains"
  mkdir -p "$user_toolchains"
  ln -sfn "$toolchain" "$user_toolchains/$toolchain_name.xctoolchain"
fi

# Copy over `generated.xcfilelist`
readonly dest_generated_xcfilelist="$dest/rules_xcodeproj/generated.xcfilelist"

$cp_cmd "$src_generated_xcfilelist" "$dest_generated_xcfilelist"
chmod u+w "$dest_generated_xcfilelist"

# Copy over `project.xcworkspace/contents.xcworkspacedata` if needed
readonly dest_xcworkspacedata="$dest/project.xcworkspace/contents.xcworkspacedata"

if [[ ! -f "$dest_xcworkspacedata" ]] || \
  ! cmp -s "$src_xcworkspacedata" "$dest_xcworkspacedata"
then
  mkdir -p "$dest/project.xcworkspace"
  $cp_cmd "$src_xcworkspacedata" "$dest_xcworkspacedata"
  chmod u+w "$dest_xcworkspacedata"
fi

# Copy over `xcschememanagement.plist`
username="$(/usr/bin/id -un)"
readonly username
readonly user_xcschmes="$dest/xcuserdata/$username.xcuserdatad/xcschemes"
readonly dest_xcschememanagement="$user_xcschmes/xcschememanagement.plist"

mkdir -p "$user_xcschmes"
$cp_cmd "$src_xcschememanagement" "$dest_xcschememanagement"
chmod u+w "$dest_xcschememanagement"

# Even though we can generate a project on Linux, it can never run on Linux.
# And since it has absolute paths, the generated project can't be copied to a
# machine and still work. Given that, and since `plutil` doesn't exist on Linux,
# we only run the following commands on macOS.
if [[ $is_macos -eq 1 ]]; then
  # Set desired `project.xcworkspace` data
  readonly workspace_data="$dest/project.xcworkspace/xcshareddata"
  readonly workspace_checks="$workspace_data/IDEWorkspaceChecks.plist"
  readonly workspace_settings="$workspace_data/WorkspaceSettings.xcsettings"
  readonly settings_files=(
    "$workspace_checks"
    "$workspace_settings"
  )

  mkdir -p "$workspace_data"
  for file in "${settings_files[@]}"; do
    if [[ ! -f $file ]]; then
      # Create an empty plist
      echo "{}" | plutil -convert xml1 -o "$file" -
    fi
  done

  # - Prevent Xcode from doing work that slows down startup
  plutil -replace IDEDidComputeMac32BitWarning -bool true "$workspace_checks"

  # - Configure the project to use Xcode's new build system.
  plutil -remove BuildSystemType "$workspace_settings" > /dev/null 2>&1 || true

  # - Prevent Xcode from prompting the user to autocreate schemes for all targets
  plutil -replace IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded -bool false "$workspace_settings"
fi

if [[ $separate_indexbuild_output_base -eq 1 ]]; then
  # Create Index Build execution root (`$INDEXING_PROJECT_DIR__YES`)
  readonly workspace_name="${execution_root##*/}"
  readonly output_base="${execution_root%/*/*}"
  readonly indexbuild_exec_root="$output_base/rules_xcodeproj.noindex/indexbuild_output_base/execroot/$workspace_name"

  mkdir -p "$indexbuild_exec_root"
fi

# Create folder structure in bazel-out to work around Xcode red generated files
if [[ -s "$src_generated_directories_filelist" ]]; then
  cd "$BUILD_WORKSPACE_DIRECTORY"

  if [[ $separate_indexbuild_output_base -eq 1 ]]; then
    readonly nested_execution_root="$output_base/rules_xcodeproj.noindex/build_output_base/execroot/$workspace_name"
  else
    readonly nested_execution_root="${execution_root%/*/*}/rules_xcodeproj.noindex/build_output_base/execroot/${execution_root##*/}"
  fi

  # Create directory structure in bazel-out
  cd "$nested_execution_root"
  while IFS= read -r dir; do
    mkdir -p "$dir"
  done < "$src_generated_directories_filelist"
fi

echo 'Updated project at "%output_path%"'
