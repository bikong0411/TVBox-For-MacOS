#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/remux"
SOURCE_DIR="$PROJECT_DIR/.build/ffmpeg-8.1.1-minimal"
mkdir -p "$BUILD_DIR"
if [[ ! -f "$SOURCE_DIR/ffbuild/config.mak" || "$PROJECT_DIR/scripts/build-remux.sh" -nt "$SOURCE_DIR/ffbuild/config.mak" ]]; then
    mkdir -p "$SOURCE_DIR"
    tar -xJf "$PROJECT_DIR/ThirdPartySources/ffmpeg-8.1.1.tar.xz" --strip-components 1 -C "$SOURCE_DIR"
    cd "$SOURCE_DIR"
    ./configure --cc=clang --arch=arm64 --target-os=darwin \
      --extra-cflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0 \
      --disable-shared --enable-static --disable-programs --disable-doc --disable-debug \
      --disable-everything --disable-autodetect --disable-avdevice --disable-avfilter \
      --disable-swscale --disable-swresample --disable-iconv --disable-videotoolbox --disable-audiotoolbox \
      --enable-network --enable-securetransport \
      --enable-protocol=file,http,https,httpproxy,tcp,tls,crypto \
      --enable-demuxer=flv,hls,mpegts,mov,aac,mp3 \
      --enable-muxer=hls,mpegts,mp4 --enable-parser=h264,hevc,aac,mpegaudio \
      --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
      > "$BUILD_DIR/configure.log"
fi
make -C "$SOURCE_DIR" -j4 > "$BUILD_DIR/make.log" 2>&1
clang -O2 -mmacosx-version-min=13.0 -I "$SOURCE_DIR" \
  "$PROJECT_DIR/Helpers/tvbox-remux.c" \
  "$SOURCE_DIR/libavformat/libavformat.a" "$SOURCE_DIR/libavcodec/libavcodec.a" "$SOURCE_DIR/libavutil/libavutil.a" \
  -framework Security -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework CoreServices \
  -lm -lz -lpthread -o "$BUILD_DIR/tvbox-remux"
cp "$SOURCE_DIR/COPYING.LGPLv2.1" "$BUILD_DIR/COPYING.LGPLv2.1"
echo "Built $BUILD_DIR/tvbox-remux"
