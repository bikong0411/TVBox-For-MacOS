# FFmpeg source for the bundled live remux helper

The archive `ffmpeg-8.1.1.tar.xz` was downloaded from the official FFmpeg release server:

https://ffmpeg.org/releases/ffmpeg-8.1.1.tar.xz

SHA-256: `b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3`

The archive is unmodified. `scripts/build-remux.sh` records the minimal static build configuration, targets macOS 13 on arm64 or x86_64, and builds `Helpers/tvbox-remux.c` as a separate executable. No GPL-only codecs or external codec libraries are enabled. The resulting helper only demuxes and remuxes supported streams; it does not decode or encode video.

The original FFmpeg license files are inside the source archive. `COPYING.LGPLv2.1` is also included in the App as `Contents/Resources/FFmpeg-LICENSE.txt`. The source archive, helper source, and reproducible build script are included in the delivered source package. The application does not use the user's Homebrew installation or IINA libraries at runtime.


# Bundled VLC playback engine

The application dynamically embeds the official VideoLAN VLCKit 3.7.3 macOS framework (arm64 + x86_64). Runtime playback does not load IINA, VLC.app, Homebrew or libraries outside the application bundle.

Official archive: https://download.videolan.org/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz

Archive SHA-256: 019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d

The unmodified official binary archive is included with the source delivery. prepare-vlc.sh extracts only the macOS XCFramework and the original COPYING.txt. Release signing changes the framework's signature; the playback implementation is unmodified.

VLCKit source revision: https://code.videolan.org/videolan/VLCKit/-/tree/319ed2c0

Corresponding VLC revision identified by the official package: https://code.videolan.org/videolan/vlc/-/tree/79128878

VLCKit build instructions, contrib build scripts and source retrieval are available in those upstream source trees. The original GNU LGPL license is included as Resources/VLCKit-LICENSE.txt and in the application. The framework is dynamically linked and replaceable; rebuilding and ad hoc signing are described in README.md.

GitHub checkouts can omit the VLCKit binary archive. scripts/fetch-dependencies.py downloads missing archives from the exact official URLs above and verifies both SHA-256 values before use. CI caches are verified in the same way. The offline source delivery still includes the original archives.
