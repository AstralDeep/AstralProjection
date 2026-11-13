#!/bin/bash
# Builds a separate localtest identity with Xcode-generated simulator Keychain entitlements, then stages a verified copy.
# Installation is separate so the running app can be stopped and its data backed up first.
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "usage: $0 <macos|ios> <existing-team-id> <derived-data> <new-stage-directory> [simulator-uuid]" >&2
    exit 2
fi
platform=$1
team=$2
derived=$3
stage=$4
simulator=${5:-}
bundle=com.personalailabs.astraldeep.localtest
configuration=${ASTRAL_LOCALTEST_CONFIGURATION:-Release}
case $configuration in
    Debug|Release) ;;
    *) echo "Localtest configuration must be Debug or Release" >&2; exit 2 ;;
esac
if [[ -n ${ASTRAL_LOCALTEST_PACKAGES_DIRECTORY:-} ]]; then
    [[ -d $ASTRAL_LOCALTEST_PACKAGES_DIRECTORY ]] || { echo "The package checkout directory must exist" >&2; exit 2; }
fi
root=$(cd "$(dirname "$0")/../AstralApp" && pwd)
[[ $team =~ ^[A-Z0-9]{10}$ ]] || { echo "A ten-character existing team id is required" >&2; exit 2; }
stage_parent=$(cd "$(dirname "$stage")" && pwd -P)
stage_name=$(basename "$stage")
[[ $stage_name != . && $stage_name != .. ]] || { echo "Choose a new stage directory" >&2; exit 2; }
stage="$stage_parent/$stage_name"
[[ ! -e $stage ]] || { echo "Stage directory must not exist" >&2; exit 2; }
[[ $stage != /Applications && $stage != /Applications/* ]] || { echo "Stage outside /Applications" >&2; exit 2; }
case $platform in
    macos)
        [[ -z $simulator ]] || { echo "macOS does not take a simulator id" >&2; exit 2; }
        identity=${ASTRAL_LOCALTEST_SIGN_IDENTITY:-Apple Development}
        [[ $identity != - ]] || { echo "macOS needs an existing stable signing identity" >&2; exit 2; }
        destination=platform=macOS
        product="$configuration/AstralDeep.app"
        extra=(ENABLE_APP_SANDBOX=NO "CODE_SIGN_ENTITLEMENTS=$root/AstralApp-DirectDownload.entitlements" ASTRAL_DISTRIBUTION=direct-download)
        ;;
    ios)
        identity=-
        [[ $simulator =~ ^[A-Fa-f0-9-]{36}$ ]] || { echo "An existing simulator UUID is required" >&2; exit 2; }
        destination="platform=iOS Simulator,id=$simulator"
        product="$configuration-iphonesimulator/AstralDeep.app"
        extra=(CODE_SIGN_ENTITLEMENTS=)
        ;;
    *) echo "Platform must be macos or ios" >&2; exit 2 ;;
esac
if [[ -n ${ASTRAL_LOCALTEST_PACKAGES_DIRECTORY:-} ]]; then
    extra+=(-clonedSourcePackagesDirPath "$ASTRAL_LOCALTEST_PACKAGES_DIRECTORY")
fi
mkdir -p "$derived"
derived=$(cd "$derived" && pwd -P)
xcodebuild -project "$root/AstralApp.xcodeproj" -scheme AstralApp -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$derived" -jobs "${ASTRAL_BUILD_JOBS:-4}" \
    CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team" \
    "PRODUCT_BUNDLE_IDENTIFIER=$bundle" "${extra[@]}" build
source_app="$derived/Build/Products/$product"
if [[ $platform == macos ]]; then
    info="$source_app/Contents/Info.plist"
else
    info="$source_app/Info.plist"
    xcent="$derived/Build/Intermediates.noindex/AstralApp.build/$configuration-iphonesimulator/AstralApp.build/AstralDeep.app-Simulated.xcent"
    identity=$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$xcent")
    [[ $identity == "$team.$bundle" ]] || { echo "Simulator Keychain identity does not match" >&2; exit 1; }
fi
actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
[[ $actual == "$bundle" ]] || { echo "Built app has the wrong bundle identity" >&2; exit 1; }
mkdir -m 700 "$stage"
target="$stage/AstralDeep-localtest.app"
ditto "$source_app" "$target"
if [[ $platform == ios && -d $target/Watch ]]; then
    rm -rf "$target/Watch"
    codesign --force --deep --sign - --identifier "$bundle" "$target"
fi
if [[ $platform == macos ]]; then
    codesign --force --deep --sign "$identity" --preserve-metadata=identifier,entitlements "$target"
fi
codesign --verify --deep --strict "$target"
if [[ $platform == macos ]]; then
    codesign --verify -R "=anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"$bundle\"" "$target"
    requirement=$(codesign -d -r- "$target" 2>&1)
    [[ $requirement != *cdhash* ]] || { echo "A changing hash cannot identify this localtest app" >&2; exit 1; }
fi
echo "Staged $target; stop and back up existing localtest data before installing."
