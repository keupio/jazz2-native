#!/bin/bash

set -euo pipefail

# Build a self-contained Universal innoextract helper. Dependencies are pinned
# and statically linked; Apple system libraries remain dynamic.
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$PROJECT_DIR/build-macos-innoextract"
SOURCE_DIR="$WORK_DIR/source"
DOWNLOAD_DIR="$WORK_DIR/downloads"
BOOST_DIR="$SOURCE_DIR/boost_1_86_0"
XZ_DIR="$SOURCE_DIR/xz-5.4.7"
INNO_DIR="$SOURCE_DIR/innoextract-1.9"
INNO_COMMIT="81fd9b95b76ee5115ce116bfdbc3bc6b887b809d"
PARALLEL="${PARALLEL:-3}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-12.6}"

mkdir -p "$SOURCE_DIR" "$DOWNLOAD_DIR"

fetch_and_verify() {
    local filename="$1" url="$2" sha256="$3"
    if [ ! -f "$DOWNLOAD_DIR/$filename" ]; then
        curl --fail --location --retry 3 --output "$DOWNLOAD_DIR/$filename" "$url"
    fi
    printf '%s  %s\n' "$sha256" "$DOWNLOAD_DIR/$filename" | shasum -a 256 -c -
}

fetch_and_verify "boost_1_86_0.tar.gz" \
    "https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz" \
    "2575e74ffc3ef1cd0babac2c1ee8bdb5782a0ee672b1912da40e5b4b591ca01f"
fetch_and_verify "xz-5.4.7.tar.gz" \
    "https://github.com/tukaani-project/xz/releases/download/v5.4.7/xz-5.4.7.tar.gz" \
    "8db6664c48ca07908b92baedcfe7f3ba23f49ef2476864518ab5db6723836e71"

[ -d "$BOOST_DIR" ] || tar -xzf "$DOWNLOAD_DIR/boost_1_86_0.tar.gz" -C "$SOURCE_DIR"
[ -d "$XZ_DIR" ] || tar -xzf "$DOWNLOAD_DIR/xz-5.4.7.tar.gz" -C "$SOURCE_DIR"
if [ ! -d "$INNO_DIR/.git" ]; then
    git clone --depth 1 --branch 1.9 https://github.com/dscharrer/innoextract.git "$INNO_DIR"
fi
[ "$(git -C "$INNO_DIR" rev-parse HEAD)" = "$INNO_COMMIT" ] || {
    printf 'Unexpected innoextract revision; refusing to build.\n' >&2
    exit 1
}

# innoextract 1.9 predates CMake 4 and newer Boost header separation.
PATCH="$PROJECT_DIR/cmake/patches/innoextract-1.9-modern-toolchain.patch"
if git -C "$INNO_DIR" apply --unidiff-zero --reverse --check "$PATCH" 2>/dev/null; then
    : # Already patched.
else
    git -C "$INNO_DIR" apply --unidiff-zero --check "$PATCH"
    git -C "$INNO_DIR" apply --unidiff-zero "$PATCH"
fi

if [ ! -x "$BOOST_DIR/b2" ]; then
    (cd "$BOOST_DIR" && ./bootstrap.sh --with-libraries=date_time,filesystem,iostreams,program_options,system)
fi

for arch in arm64 x86_64; do
    stage="$WORK_DIR/boost-stage-$arch"
    build="$WORK_DIR/boost-$arch"
    arch_args=()
    if [ "$arch" = x86_64 ]; then arch_args=(architecture=x86 address-model=64); fi
    if [ ! -f "$stage/lib/libboost_program_options.a" ]; then
        (cd "$BOOST_DIR" && ./b2 -j"$PARALLEL" toolset=clang target-os=darwin \
            "${arch_args[@]}" variant=release link=static threading=multi runtime-link=shared \
            --with-date_time --with-filesystem --with-iostreams --with-program_options --with-system \
            cxxflags="-arch $arch -mmacosx-version-min=$MACOS_MIN_VERSION" \
            linkflags="-arch $arch -mmacosx-version-min=$MACOS_MIN_VERSION" \
            --build-dir="$build" --stagedir="$stage" stage)
    fi
    lipo -verify_arch "$arch" "$stage/lib/libboost_program_options.a"
done

cmake -S "$XZ_DIR" -B "$WORK_DIR/xz-universal" \
    -D CMAKE_BUILD_TYPE=Release \
    -D 'CMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
    -D CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
    -D BUILD_SHARED_LIBS=OFF
cmake --build "$WORK_DIR/xz-universal" --target liblzma --parallel "$PARALLEL"
lipo -verify_arch arm64 "$WORK_DIR/xz-universal/liblzma.a"
lipo -verify_arch x86_64 "$WORK_DIR/xz-universal/liblzma.a"

for arch in arm64 x86_64; do
    build="$WORK_DIR/innoextract-$arch"
    cmake -S "$INNO_DIR" -B "$build" \
        -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_OSX_ARCHITECTURES="$arch" \
        -D CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
        -D USE_LTO=OFF \
        -D Boost_NO_BOOST_CMAKE=ON \
        -D Boost_USE_STATIC_LIBS=ON \
        -D Boost_NO_SYSTEM_PATHS=ON \
        -D BOOST_ROOT="$BOOST_DIR" \
        -D BOOST_LIBRARYDIR="$WORK_DIR/boost-stage-$arch/lib" \
        -D LZMA_USE_STATIC_LIBS=ON \
        -D LZMA_LIBRARY="$WORK_DIR/xz-universal/liblzma.a" \
        -D LZMA_INCLUDE_DIR="$XZ_DIR/src/liblzma/api"
    cmake --build "$build" --target innoextract --parallel "$PARALLEL"
    lipo -verify_arch "$arch" "$build/innoextract"
done

HELPER="$WORK_DIR/innoextract-universal"
lipo -create "$WORK_DIR/innoextract-arm64/innoextract" \
    "$WORK_DIR/innoextract-x86_64/innoextract" -output "$HELPER"
lipo -verify_arch arm64 "$HELPER"
lipo -verify_arch x86_64 "$HELPER"
printf '\nUniversal innoextract helper: %s\n' "$HELPER"
