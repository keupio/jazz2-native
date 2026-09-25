#!/bin/bash

set -euo pipefail

# Build a notarization-ready Jazz² Resurrection app from source.
#
# The script deliberately does not submit anything to Apple's notary service.
# It builds the current checkout by default. Set UPDATE=1 to fast-forward the
# selected branch before building.
#
# Typical signed build:
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   UPDATE=1 ./macos-build.sh
#
# Useful overrides:
#   ARCH=x86_64 BACKEND=SDL2 WITH_VORBIS=ON ./macos-build.sh
#   ARCH=universal ./macos-build.sh
#   RHI=Metal BACKEND=SDL2 ./macos-build.sh
#   SUPPRESS_WARNINGS=1 ./macos-build.sh
#   CLEAN=0 ./macos-build.sh

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

ARCH="${ARCH:-$(uname -m)}"
BACKEND="${BACKEND:-GLFW}"
RHI="${RHI:-OpenGL}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-12.6}"
MACOS_BUNDLE_SHORT_VERSION="${MACOS_BUNDLE_SHORT_VERSION:-}"
MACOS_BUNDLE_BUILD_VERSION="${MACOS_BUNDLE_BUILD_VERSION:-1}"
WITH_VORBIS="${WITH_VORBIS:-}"
WITH_INNOEXTRACT="${WITH_INNOEXTRACT:-1}"
PARALLEL="${PARALLEL:-3}"
TIMESTAMP_RETRIES="${TIMESTAMP_RETRIES:-3}"
SUPPRESS_WARNINGS="${SUPPRESS_WARNINGS:-0}"
UPDATE="${UPDATE:-0}"
CLEAN="${CLEAN:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

BUILD_DIR="$PROJECT_DIR/build-macos-$ARCH-${BACKEND}-${RHI}"
DIST_DIR="$PROJECT_DIR/dist-macos-$ARCH-${BACKEND}-${RHI}"
APP_NAME="Jazz² Resurrection.app"
APP_BUNDLE="$DIST_DIR/$APP_NAME"
ZIP_FILE="$DIST_DIR/Jazz2-macOS-$ARCH-${BACKEND}-${RHI}.zip"

header() {
    printf '\n============================================================\n%s\n============================================================\n\n' "$1"
}

fail() {
    printf '\nERROR: %s\n\n' "$1" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"
}

make_icns_fallback() {
    local iconset="$1"
    local output="$2"

    # macOS 27's iconutil can reject an otherwise complete iconset. An ICNS
    # file is a simple big-endian container; modern entries contain PNG data.
    python3 - "$iconset" "$output" <<'PY'
import pathlib
import struct
import sys

iconset = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
entries = (
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)
chunks = []
for kind, name in entries:
    data = (iconset / name).read_bytes()
    chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
}

verify_universal_inputs() {
    local arm_app="$1" intel_app="$2"
    local source_app counterpart_app expected_arch counterpart_arch binary relative counterpart

    for source_app in "$arm_app" "$intel_app"; do
        [ -d "$source_app/Contents" ] || fail "Missing input app: $source_app"
        if [ "$source_app" = "$arm_app" ]; then
            counterpart_app="$intel_app"
            expected_arch=arm64
            counterpart_arch=x86_64
        else
            counterpart_app="$arm_app"
            expected_arch=x86_64
            counterpart_arch=arm64
        fi
        [ -f "$source_app/Contents/Resources/jazz2" ] \
            || fail "Missing game executable: $source_app/Contents/Resources/jazz2"
        file -b "$source_app/Contents/Resources/jazz2" | grep -q 'Mach-O' \
            || fail "Game executable is not Mach-O: $source_app/Contents/Resources/jazz2"

        # Check both directions: an Intel-only dependency must not disappear
        # merely because the ARM app is used as the resource template.
        while IFS= read -r -d '' binary; do
            if file -b "$binary" | grep -q 'Mach-O'; then
                relative="${binary#"$source_app/"}"
                counterpart="$counterpart_app/$relative"
                [ -f "$counterpart" ] \
                    || fail "Missing $counterpart_arch counterpart: $counterpart (required by $binary)"
                file -b "$counterpart" | grep -q 'Mach-O' \
                    || fail "Counterpart is not Mach-O: $counterpart"
                [ "$(lipo -archs "$binary")" = "$expected_arch" ] \
                    || fail "Expected a single $expected_arch slice: $binary"
            fi
        done < <(find "$source_app/Contents" -type f -print0)
    done
}

verify_universal_bundle() {
    local binary
    while IFS= read -r -d '' binary; do
        if file -b "$binary" | grep -q 'Mach-O'; then
            lipo -verify_arch arm64 "$binary" \
                || fail "Universal bundle is missing arm64: $binary"
            lipo -verify_arch x86_64 "$binary" \
                || fail "Universal bundle is missing x86_64: $binary"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
}

sign_bundle() {
    local signable

    # Sign every nested Mach-O file first and the outer app last. Avoid --deep
    # for signing; explicit inside-out signing is deterministic.
    while IFS= read -r -d '' signable; do
        if file -b "$signable" | grep -q 'Mach-O'; then
            codesign_with_timestamp "$signable"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)

    codesign_with_timestamp "$APP_BUNDLE"
}

sign_bundle_for_local_testing() {
    local signable
    while IFS= read -r -d '' signable; do
        if file -b "$signable" | grep -q 'Mach-O'; then
            # Ad-hoc signatures have no Team ID. Do not enable hardened runtime
            # for local-only builds, since library validation rejects bundled
            # dylibs without the same Developer ID Team ID as the main binary.
            codesign --force --sign - "$signable"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
    codesign --force --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
}

bundle_innoextract() {
    [ "$WITH_INNOEXTRACT" = "1" ] || return 0
    header "BUILDING GOG INSTALLER HELPER"
    bash "$PROJECT_DIR/macos-build-innoextract.sh"
    local helper_root="$PROJECT_DIR/build-macos-innoextract"
    local license_dir="$APP_BUNDLE/Contents/Resources/Licenses"
    mkdir -p "$APP_BUNDLE/Contents/Helpers" "$license_dir"
    ditto --norsrc --noextattr "$helper_root/innoextract-universal" \
        "$APP_BUNDLE/Contents/Helpers/innoextract"
    chmod 755 "$APP_BUNDLE/Contents/Helpers/innoextract"
    ditto "$helper_root/source/innoextract-1.9/LICENSE" "$license_dir/Innoextract.txt"
    ditto "$PROJECT_DIR/cmake/patches/innoextract-1.9-NOTICE.txt" "$license_dir/Innoextract-Changes.txt"
    ditto "$helper_root/source/boost_1_86_0/LICENSE_1_0.txt" "$license_dir/Boost.txt"
    ditto "$helper_root/source/xz-5.4.7/COPYING" "$license_dir/XZ-Utils.txt"
    lipo -verify_arch arm64 "$APP_BUNDLE/Contents/Helpers/innoextract"
    lipo -verify_arch x86_64 "$APP_BUNDLE/Contents/Helpers/innoextract"
}

bundle_dependency_licenses() {
    local license_dir="$APP_BUNDLE/Contents/Resources/Licenses"
    mkdir -p "$license_dir"
    ditto "$PROJECT_DIR/cmake/licenses/libogg-COPYING.txt" "$license_dir/libogg.txt"
    ditto "$PROJECT_DIR/cmake/licenses/libvorbis-COPYING.txt" "$license_dir/libvorbis.txt"
}

flatten_upstream_frameworks() {
    local frameworks_dir="$APP_BUNDLE/Contents/Frameworks"
    local framework logical binary_link target source output old_id
    local -a old_ids=()
    local -a new_ids=()
    local index signable

    # The downloaded dependencies use directories named *.framework without
    # the Info.plist required of a real framework bundle. Gatekeeper's strict
    # verification rejects those. Keep only their runtime dylibs and rewrite
    # the app's @rpath references to the flattened files.
    while IFS= read -r -d '' framework; do
        logical="$(basename "$framework" .framework)"
        binary_link="$framework/$logical"
        [ -L "$binary_link" ] || fail "Framework has no runtime binary: $framework"

        target="$(readlink "$binary_link")"
        source="$framework/$target"
        [ -f "$source" ] || fail "Broken framework binary link: $binary_link"

        output="$(basename "$source")"
        old_id="$(otool -D "$source" | sed -n '2p')"
        [ -n "$old_id" ] || fail "No install name found in: $source"

        ditto --norsrc --noextattr "$source" "$frameworks_dir/$output"
        install_name_tool -id "@rpath/$output" "$frameworks_dir/$output"
        old_ids+=("$old_id")
        new_ids+=("@rpath/$output")
    done < <(find "$frameworks_dir" -maxdepth 1 -type d -name '*.framework' -print0)

    while IFS= read -r -d '' framework; do
        rm -rf "$framework"
    done < <(find "$frameworks_dir" -maxdepth 1 -type d -name '*.framework' -print0)

    while IFS= read -r -d '' signable; do
        if file -b "$signable" | grep -q 'Mach-O'; then
            for ((index = 0; index < ${#old_ids[@]}; index++)); do
                if otool -L "$signable" | grep -Fq "${old_ids[$index]}"; then
                    install_name_tool -change "${old_ids[$index]}" \
                        "${new_ids[$index]}" "$signable"
                fi
            done
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
}

codesign_with_timestamp() {
    local target="$1"
    local attempt

    for ((attempt = 1; attempt <= TIMESTAMP_RETRIES; attempt++)); do
        if codesign --force --options runtime --timestamp \
            --sign "$SIGNING_IDENTITY" "$target"; then
            return 0
        fi
        if [ "$attempt" -lt "$TIMESTAMP_RETRIES" ]; then
            printf 'Timestamp signing failed; retrying (%d/%d)...\n' \
                "$attempt" "$TIMESTAMP_RETRIES" >&2
            sleep 2
        fi
    done

    fail "Could not obtain Apple's required secure timestamp for: $target"
}

header "JAZZ² RESURRECTION macOS BUILD"

case "$ARCH" in
    arm64|x86_64|universal) ;;
    *) fail "Unsupported ARCH '$ARCH' (expected arm64, x86_64, or universal)" ;;
esac

case "$BACKEND" in
    GLFW|SDL2) ;;
    *) fail "Unsupported BACKEND '$BACKEND' (expected GLFW or SDL2)" ;;
esac

case "$RHI" in
    OpenGL|Metal) ;;
    *) fail "Unsupported RHI '$RHI' (expected OpenGL or Metal)" ;;
esac

if [ "$RHI" = "Metal" ] && [ "$BACKEND" != "SDL2" ]; then
    fail "RHI=Metal requires BACKEND=SDL2"
fi

if [ -z "$WITH_VORBIS" ] && [ "$ARCH" != "universal" ]; then
    if [ "$ARCH" = "arm64" ]; then
        WITH_VORBIS="OFF"
    else
        WITH_VORBIS="ON"
    fi
fi

if [ "$ARCH" = "universal" ]; then
    require_tool lipo
    UNIVERSAL_BUILD_DIR="$PROJECT_DIR/build-macos-universal-${BACKEND}-${RHI}"
    UNIVERSAL_DIST_DIR="$PROJECT_DIR/dist-macos-universal-${BACKEND}-${RHI}"
    UNIVERSAL_APP="$UNIVERSAL_DIST_DIR/$APP_NAME"
    UNIVERSAL_ZIP="$UNIVERSAL_DIST_DIR/Jazz2-macOS-universal-${BACKEND}-${RHI}.zip"
    if [ "$CLEAN" = "1" ]; then
        rm -rf "$UNIVERSAL_BUILD_DIR"
    fi
    mkdir -p "$UNIVERSAL_DIST_DIR"
    # The upstream macOS dependency archives do not provide a reliable
    # arm64 Vorbis slice. Keep Vorbis disabled for both slices unless the
    # caller supplies a known-good universal dependency set.
    UNIVERSAL_VORBIS="${WITH_VORBIS:-OFF}"
    ARCH=arm64 CLEAN="$CLEAN" WITH_VORBIS="$UNIVERSAL_VORBIS" \
        WITH_INNOEXTRACT=0 MACOS_BUNDLE_SHORT_VERSION="$MACOS_BUNDLE_SHORT_VERSION" \
        MACOS_BUNDLE_BUILD_VERSION="$MACOS_BUNDLE_BUILD_VERSION" SIGNING_IDENTITY="" "$PROJECT_DIR/macos-build.sh"
    ARCH=x86_64 CLEAN="$CLEAN" WITH_VORBIS="$UNIVERSAL_VORBIS" \
        WITH_INNOEXTRACT=0 MACOS_BUNDLE_SHORT_VERSION="$MACOS_BUNDLE_SHORT_VERSION" \
        MACOS_BUNDLE_BUILD_VERSION="$MACOS_BUNDLE_BUILD_VERSION" SIGNING_IDENTITY="" "$PROJECT_DIR/macos-build.sh"
    ARM_APP="$PROJECT_DIR/dist-macos-arm64-${BACKEND}-${RHI}/$APP_NAME"
    INTEL_APP="$PROJECT_DIR/dist-macos-x86_64-${BACKEND}-${RHI}/$APP_NAME"
    verify_universal_inputs "$ARM_APP" "$INTEL_APP"

    # Always assemble from an empty directory, including when CLEAN=0.
    # Keep the previous output until the new bundle and archive are complete.
    UNIVERSAL_STAGE="$(mktemp -d "$UNIVERSAL_DIST_DIR/.universal-stage.XXXXXX")"
    trap 'rm -rf "$UNIVERSAL_STAGE"' EXIT
    APP_BUNDLE="$UNIVERSAL_STAGE/$APP_NAME"
    ZIP_FILE="$UNIVERSAL_STAGE/$(basename "$UNIVERSAL_ZIP")"
    ditto "$ARM_APP" "$APP_BUNDLE"
    while IFS= read -r -d '' arm_file; do
        rel="${arm_file#"$APP_BUNDLE/"}"
        intel_file="$INTEL_APP/$rel"
        if file -b "$arm_file" | grep -q 'Mach-O'; then
            [ -f "$intel_file" ] || fail "Missing Intel counterpart: $intel_file"
            lipo -create "$arm_file" "$intel_file" -output "$arm_file"
        fi
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
    bundle_innoextract
    bundle_dependency_licenses
    verify_universal_bundle
    xattr -cr "$APP_BUNDLE"
    if [ -n "$SIGNING_IDENTITY" ]; then
        sign_bundle
        codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    else
        sign_bundle_for_local_testing
    fi
    touch "$APP_BUNDLE"
    ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ZIP_FILE"
    unzip -t "$ZIP_FILE" >/dev/null
    if [ -e "$UNIVERSAL_APP" ]; then
        mv "$UNIVERSAL_APP" "$UNIVERSAL_STAGE/previous.app"
    fi
    if ! mv "$APP_BUNDLE" "$UNIVERSAL_APP"; then
        if [ -d "$UNIVERSAL_STAGE/previous.app" ] && ! mv "$UNIVERSAL_STAGE/previous.app" "$UNIVERSAL_APP"; then
            trap - EXIT
            fail "Could not restore the previous app; it is preserved at $UNIVERSAL_STAGE/previous.app"
        fi
        fail "Could not install the new Universal bundle"
    fi
    mv -f "$ZIP_FILE" "$UNIVERSAL_ZIP"
    APP_BUNDLE="$UNIVERSAL_APP"
    ZIP_FILE="$UNIVERSAL_ZIP"
    printf '\nUniversal build complete:\n  %s\n  %s\n' "$APP_BUNDLE" "$ZIP_FILE"
    exit 0
fi

for tool in cmake codesign ditto file find git iconutil install_name_tool otool python3 security unzip xattr; do
    require_tool "$tool"
done

[ -d "$PROJECT_DIR/.git" ] || fail "Not a Git checkout: $PROJECT_DIR"
[ -f "$PROJECT_DIR/CMakeLists.txt" ] || fail "CMakeLists.txt not found"

printf 'Project:             %s\n' "$PROJECT_DIR"
printf 'Architecture:        %s\n' "$ARCH"
printf 'Backend / renderer:  %s / %s\n' "$BACKEND" "$RHI"
printf 'Minimum macOS:       %s\n' "$MACOS_MIN_VERSION"
printf 'Update checkout:     %s\n' "$UPDATE"
printf 'Signing identity:    %s\n' "${SIGNING_IDENTITY:-not supplied}"
printf 'Suppress warnings:    %s\n' "$SUPPRESS_WARNINGS"

if [ "$UPDATE" = "1" ]; then
    header "UPDATING SOURCE"
    [ -z "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ] \
        || fail "Tracked files contain local changes; refusing to update"
    git -C "$PROJECT_DIR" pull --ff-only
fi

header "PREPARING BUILD"

if [ "$CLEAN" = "1" ]; then
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR" "$DIST_DIR"

CMAKE_WARNING_FLAGS=()
if [ "$SUPPRESS_WARNINGS" = "1" ]; then
    CMAKE_WARNING_FLAGS+=(
        "-DCMAKE_CXX_FLAGS=-w"
        "-DCMAKE_C_FLAGS=-w"
    )
fi

cmake -S "$PROJECT_DIR" -B "$BUILD_DIR" \
    -D CMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -D CMAKE_OSX_ARCHITECTURES="$ARCH" \
    -D CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
    -D NCINE_STRIP_BINARIES=ON \
    -D NCINE_PREFERRED_BACKEND="$BACKEND" \
    -D NCINE_PREFERRED_RHI="$RHI" \
    -D NCINE_WITH_VORBIS="$WITH_VORBIS" \
    -D MACOS_BUNDLE_SHORT_VERSION="$MACOS_BUNDLE_SHORT_VERSION" \
    -D MACOS_BUNDLE_BUILD_VERSION="$MACOS_BUNDLE_BUILD_VERSION" \
    "${CMAKE_WARNING_FLAGS[@]}"

header "BUILDING"

# Generate the icon target first. If iconutil fails (observed on macOS 27),
# create the same output from the generated PNGs and mark the target current.
if ! cmake --build "$BUILD_DIR" --target iconutil_convert --parallel "$PARALLEL"; then
    ICONSET="$BUILD_DIR/jazz2.iconset"
    [ -d "$ICONSET" ] || fail "Icon build failed before creating $ICONSET"
    make_icns_fallback "$ICONSET" "$BUILD_DIR/jazz2.icns"
    touch "$ICONSET"
fi

cmake --build "$BUILD_DIR" --parallel "$PARALLEL"

header "CREATING UPSTREAM PACKAGE"

# CPack stages the complete app before it asks hdiutil for a DMG. macOS 27 can
# reject CPack's deprecated HFS+ hdiutil invocation, even though the staged app
# is valid. Preserve that useful output and continue with our notarization ZIP.
if ! cmake --build "$BUILD_DIR" --target package --parallel "$PARALLEL"; then
    printf '\nCPack could not create its optional DMG; using the staged app.\n'
fi

STAGED_APP="$(find "$BUILD_DIR/_CPack_Packages" -type d -name "$APP_NAME" -print -quit 2>/dev/null || true)"
[ -n "$STAGED_APP" ] || fail "CPack did not stage $APP_NAME"

rm -rf "$APP_BUNDLE"
ditto "$STAGED_APP" "$APP_BUNDLE"

[ -f "$APP_BUNDLE/Contents/Info.plist" ] || fail "Info.plist missing from app"
[ -d "$APP_BUNDLE/Contents/Frameworks" ] || fail "Frameworks missing from app"
[ -f "$APP_BUNDLE/Contents/Resources/jazz2" ] || fail "Game executable missing from app"

header "NORMALIZING RUNTIME LIBRARIES"

flatten_upstream_frameworks
bundle_dependency_licenses
bundle_innoextract

header "CLEANING BUNDLE METADATA"

find "$APP_BUNDLE" -type f \( -name '.DS_Store' -o -name '._*' \) -delete
xattr -cr "$APP_BUNDLE"

if [ -n "$SIGNING_IDENTITY" ]; then
    header "CHECKING DEVELOPER ID"
    security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null \
        || fail "Developer ID identity not found: $SIGNING_IDENTITY"

    header "SIGNING BUNDLE"
    sign_bundle

    header "VERIFYING SIGNATURE"
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign --display --verbose=4 "$APP_BUNDLE" 2>&1
else
    header "SIGNING SKIPPED"
    sign_bundle_for_local_testing
    printf 'Ad-hoc signed for local testing. Set SIGNING_IDENTITY to create a notarization-ready archive.\n'
fi

touch "$APP_BUNDLE"

header "CREATING ZIP"

rm -f "$ZIP_FILE"
ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ZIP_FILE"
unzip -t "$ZIP_FILE" >/dev/null

SUSPICIOUS_FILES="$(unzip -Z1 "$ZIP_FILE" | grep -E '(^|/)\.DS_Store$|(^|/)\._[^/]*$|__MACOSX/' || true)"
[ -z "$SUSPICIOUS_FILES" ] || fail "Archive contains unwanted metadata:\n$SUSPICIOUS_FILES"

header "BUILD COMPLETE"

printf 'Source:      %s\n' "$(git -C "$PROJECT_DIR" describe --tags --always --dirty)"
printf 'Application: %s\n' "$APP_BUNDLE"
printf 'Archive:     %s\n\n' "$ZIP_FILE"

if [ -n "$SIGNING_IDENTITY" ]; then
    printf '%s\n' 'Submit manually:'
    printf '  xcrun notarytool submit %q --keychain-profile %q --wait\n\n' "$ZIP_FILE" "YOUR-NOTARIZATION-PROFILE"
    printf '%s\n' 'After Apple accepts it:'
    printf '  xcrun stapler staple %q\n' "$APP_BUNDLE"
    printf '  xcrun stapler validate %q\n' "$APP_BUNDLE"
    printf '  spctl --assess --type execute --verbose=4 %q\n' "$APP_BUNDLE"
    printf '  rm -f %q\n' "$ZIP_FILE"
    printf '  ditto -c -k --keepParent --norsrc --noextattr %q %q\n' "$APP_BUNDLE" "$ZIP_FILE"
fi
