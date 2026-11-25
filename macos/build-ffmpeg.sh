#!/usr/bin/env bash
# Builds the LGPL FFmpeg the Alluno Mac app bundles: the avcodec, avutil, swresample and swscale
# shared libraries with the libopus encoder, nothing else enabled or autodetected, for macOS 12.3
# and later. The build stops unless every library reports the LGPL v3, links only libSystem and
# each other, and targets that macOS.
#
# Usage: macos/build-ffmpeg.sh <arm64|x86_64> [output dir]
# Runs on a Mac of that architecture with the Xcode command line tools, pkg-config and, for
# x86_64, nasm. Writes ffmpeg-n<version>-macos-<arm64|x64>-lgpl-shared-9.0.tar.xz and its .sha256.
set -euo pipefail

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
OPUS_VERSION=1.6.1
OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
MINIMUM_MACOS=12.3
LICENSE="LGPL version 3 or later"

ARCH="${1:?usage: build-ffmpeg.sh <arm64|x86_64> [output dir]}"
OUT="${2:-dist}"
case "$ARCH" in
  arm64) LABEL=arm64 ;;
  x86_64) LABEL=x64 ;;
  *) echo "unknown architecture: $ARCH" >&2; exit 2 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo "build on macOS" >&2; exit 2; }
[ "$(uname -m)" = "$ARCH" ] || { echo "build $ARCH on an $ARCH Mac" >&2; exit 2; }

export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS"
JOBS="$(sysctl -n hw.ncpu)"
NAME="ffmpeg-n$FFMPEG_VERSION-macos-$LABEL-lgpl-shared-9.0"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DEPS="$WORK/deps"
STAGE="$WORK/stage/ffmpeg"

FFMPEG_OPTIONS=(
  --prefix=/ffmpeg
  --install-name-dir=@rpath
  --pkg-config-flags=--static
  --extra-cflags="-mmacosx-version-min=$MINIMUM_MACOS"
  --extra-ldflags="-mmacosx-version-min=$MINIMUM_MACOS"
  --enable-version3
  --enable-shared
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-autodetect
  --disable-everything
  --disable-network
  --disable-avdevice
  --disable-avformat
  --disable-avfilter
  --enable-libopus
  --enable-encoder=libopus
)

fetch() {
  curl -fsSL --retry 3 -o "$WORK/$2" "$1"
  echo "$3  $WORK/$2" | shasum -a 256 -c -
}

check_library() {
  local file="$1" minos dep
  minos="$(otool -l "$file" | awk '/cmd LC_BUILD_VERSION/ { seen = 1 } seen && $1 == "minos" { print $2; exit }')"
  if [ "$minos" != "$MINIMUM_MACOS" ]; then
    echo "$file is built for macOS ${minos:-unknown}, not $MINIMUM_MACOS" >&2
    exit 1
  fi
  for dep in $(otool -L "$file" | tail -n +2 | awk '{ print $1 }'); do
    case "$dep" in
      @rpath/libavcodec.*|@rpath/libavutil.*|@rpath/libswresample.*|@rpath/libswscale.*) ;;
      /usr/lib/libSystem.B.dylib) ;;
      *) echo "$file links $dep" >&2; exit 1 ;;
    esac
  done
}

fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" opus.tar.gz "$OPUS_SHA256"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" ffmpeg.tar.xz "$FFMPEG_SHA256"

tar -xzf "$WORK/opus.tar.gz" -C "$WORK"
(
  cd "$WORK/opus-$OPUS_VERSION"
  ./configure --prefix="$DEPS" --enable-static --disable-shared --with-pic --disable-doc --disable-extra-programs
  make -j"$JOBS"
  make install
)

tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK"
(
  cd "$WORK/ffmpeg-$FFMPEG_VERSION"
  PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" ./configure "${FFMPEG_OPTIONS[@]}"
  make -j"$JOBS"
  make install DESTDIR="$WORK/stage"
)

for file in "$STAGE"/lib/*.dylib; do
  [ -L "$file" ] && continue
  case "$(basename "$file")" in
    libavcodec.*|libavutil.*|libswresample.*|libswscale.*) check_library "$file" ;;
    *) echo "unexpected library $file" >&2; exit 1 ;;
  esac
done

cat > "$WORK/check.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

int main(int argc, char **argv)
{
    const char *licenses[] = { avcodec_license(), avutil_license(), swresample_license(), swscale_license() };
    const char *configuration = avcodec_configuration();
    if (argc != 2)
        return 2;
    for (size_t i = 0; i < sizeof(licenses) / sizeof(*licenses); i++) {
        if (strcmp(licenses[i], argv[1]) != 0) {
            fprintf(stderr, "license: %s\n", licenses[i]);
            return 1;
        }
    }
    if (strstr(configuration, "--enable-gpl") || strstr(configuration, "--enable-nonfree")) {
        fprintf(stderr, "configuration: %s\n", configuration);
        return 1;
    }
    if (!avcodec_find_encoder_by_name("libopus")) {
        fputs("no libopus encoder\n", stderr);
        return 1;
    }
    puts(configuration);
    return 0;
}
EOF
clang -mmacosx-version-min="$MINIMUM_MACOS" -I"$STAGE/include" "$WORK/check.c" -L"$STAGE/lib" \
  -lavcodec -lavutil -lswresample -lswscale -Wl,-rpath,"$STAGE/lib" -o "$WORK/check"
CONFIGURATION="$("$WORK/check" "$LICENSE")"

rm -rf "$STAGE/share"
sed -i '' -e "s|^prefix=/ffmpeg\$|prefix=\${pcfiledir}/../..|" -e "s|=/ffmpeg/|=\${prefix}/|" \
  -e "s|-L$DEPS/lib ||g" "$STAGE"/lib/pkgconfig/*.pc
cp "$WORK/ffmpeg-$FFMPEG_VERSION/LICENSE.md" "$WORK/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv3" \
  "$WORK/ffmpeg-$FFMPEG_VERSION/COPYING.GPLv3" "$STAGE/"
cp "$WORK/opus-$OPUS_VERSION/COPYING" "$STAGE/COPYING.opus"
cp "$SCRIPT" "$STAGE/build-ffmpeg.sh"
cat > "$STAGE/BUILD.txt" <<EOF
FFmpeg $FFMPEG_VERSION: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz (SHA-256 $FFMPEG_SHA256)
Opus $OPUS_VERSION, inside libavcodec: https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz (SHA-256 $OPUS_SHA256)
Built by build-ffmpeg.sh for $ARCH, macOS $MINIMUM_MACOS and later
License: $LICENSE
Configuration: $CONFIGURATION
EOF

mv "$STAGE" "$WORK/$NAME"
COPYFILE_DISABLE=1 tar -C "$WORK" -cJf "$OUT/$NAME.tar.xz" "$NAME"
(cd "$OUT" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256" && cat "$NAME.tar.xz.sha256")
