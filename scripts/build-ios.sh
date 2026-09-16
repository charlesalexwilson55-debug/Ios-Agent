#!/bin/bash
# Builds an unsigned Conduit.ipa. Runs on macOS only (needs the iOS SDK).
#
# This replaces the single-file `xcrun swiftc` approach used in other projects
# here. That approach cannot work for Conduit: MLX Swift is a SwiftPM package
# with Metal shaders and C++ sources, and resolving/compiling that requires a
# real Xcode project. XcodeGen builds the project from project.yml at build
# time, so no .xcodeproj is ever committed and everything stays authorable
# from Windows.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "An Apple iOS SDK on macOS is required to compile this IPA." >&2
  echo "Push to GitHub and let .github/workflows/ios.yml build it." >&2
  exit 1
fi

APP_NAME="Conduit"
BUILD_ROOT="$PWD/build"
ARCHIVE="$BUILD_ROOT/$APP_NAME.xcarchive"

echo "==> Toolchain"
xcodebuild -version
# Liquid Glass (glassEffect) needs the iOS 26 SDK. Failing loudly here beats a
# wall of "cannot find glassEffect in scope" errors later.
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "iOS SDK: $SDK_VERSION"
if [[ "${SDK_VERSION%%.*}" -lt 26 ]]; then
  echo "ERROR: iOS SDK $SDK_VERSION is too old. Conduit needs the iOS 26 SDK (Xcode 26+)." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Installing XcodeGen"
  brew install xcodegen
fi

echo "==> Generating icons"
python3 scripts/make-icons.py

echo "==> Generating Xcode project"
rm -rf "$APP_NAME.xcodeproj"
xcodegen generate

echo "==> Resolving Swift packages"
# Done as its own step so a dependency-resolution failure is distinguishable
# from a compile failure in the log.
xcodebuild -resolvePackageDependencies -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME"

echo "==> Archiving"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
# CODE_SIGNING_ALLOWED=NO produces an unsigned .app. The signature is applied
# later by whatever installs it (Sideloadly, AltStore), which re-signs with the
# user's own Apple ID anyway, so signing here would only be thrown away.
# The raw log is teed to a file before xcbeautify sees it. xcbeautify is for
# humans reading the CI console; the unfiltered log is what actually contains
# the compiler diagnostics, and discarding it was costing a full build cycle
# per error.
RAW_LOG="$BUILD_ROOT/xcodebuild.log"
set +e
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  > "$RAW_LOG" 2>&1
BUILD_STATUS=$?
set -e

if command -v xcbeautify >/dev/null 2>&1; then
  xcbeautify < "$RAW_LOG" || true
else
  tail -60 "$RAW_LOG"
fi

APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
if [[ $BUILD_STATUS -ne 0 || ! -d "$APP_PATH" ]]; then
  echo ""
  echo "======================= COMPILER DIAGNOSTICS =======================" >&2
  # Unique, in file order, so the same error repeated across targets does not
  # crowd out the others.
  grep -E "(error|warning): " "$RAW_LOG" | sort -u | head -80 >&2 || true
  echo "====================================================================" >&2
  echo "xcodebuild exited $BUILD_STATUS; full log at $RAW_LOG" >&2
  exit 1
fi

echo "==> Packaging IPA"
# The entitlements file is copied in beside the app rather than embedded,
# because an unsigned binary cannot carry entitlements. Sideloadly and AltStore
# both accept an explicit entitlements plist at re-sign time, and this is how
# increased-memory-limit survives to the installed app.
mkdir -p "$BUILD_ROOT/Payload"
cp -R "$APP_PATH" "$BUILD_ROOT/Payload/"
cp Support/Conduit.entitlements "$BUILD_ROOT/Conduit.entitlements"

mkdir -p artifacts
rm -f "artifacts/$APP_NAME-unsigned.ipa"
(cd "$BUILD_ROOT" && zip -qry "$OLDPWD/artifacts/$APP_NAME-unsigned.ipa" Payload Conduit.entitlements)

echo "==> Verifying"
python3 scripts/verify-ipa.py "artifacts/$APP_NAME-unsigned.ipa"
