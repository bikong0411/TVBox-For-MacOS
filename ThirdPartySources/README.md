# FFmpeg source for the bundled live remux helper

The archive `ffmpeg-8.1.1.tar.xz` was downloaded from the official FFmpeg release server:

https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.xz

SHA-256: `b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3`

The archive is unmodified. `scripts/build-remux.sh` records the minimal static build configuration, targets macOS 13 on arm64, and builds `Helpers/tvbox-remux.c` as a separate executable. No GPL-only codecs or external codec libraries are enabled. The resulting helper only demuxes and remuxes supported streams; it does not decode or encode video.

The original FFmpeg license files are inside the source archive. `COPYING.LGPLv2.1` is also included in the App as `Contents/Resources/FFmpeg-LICENSE.txt`. The source archive, helper source, and reproducible build script are included in the delivered source package. The application does not use the user's Homebrew installation or IINA libraries at runtime.
