# Forawn

Forawn is a cross-platform desktop application for **Windows**, **Linux** and **macOS**, built with Flutter. It combines a local music player with a music/video downloader and a set of everyday tools, all in a single multilingual interface.

The app downloads and manages its own audio/video tools (`yt-dlp` and `ffmpeg`) automatically, so downloads keep working on every platform without manual setup.

Current version: **v1.0.6**

---

## Features

### Music Player

- Local music library with automatic metadata and artwork extraction
- Audio playback with position, seek, volume, shuffle, repeat and queue controls
- Synchronized lyrics with auto-scroll, tap-to-seek and manual offset adjustment
- Playlists and favorites, persisted locally
- Mini player overlay across screens
- Album-art based color themes (dominant color per song)
- Background playback and media key integration

### Download Manager

- **Music downloader**: search and download tracks (metadata from Deezer API, audio from yt-dlp with YouTube fallback)
- **Video downloader**: download videos from supported platforms
- Download queue with progress, status and history
- Automatic installation of `yt-dlp` and `ffmpeg` per platform, with integrity validation and re-download on failure
- ID3 tags and embedded artwork after conversion

### Tools

- Text translator with multiple target languages
- QR code generator
- Global keyboard shortcuts
- Discord Rich Presence integration
- Windows System Media Transport Controls (SMTC) integration

### Interface

- Unified custom title bar across all platforms (frameless on Windows/Linux, native traffic lights on macOS)
- Acrylic/blur window effects on Windows 11
- Dark and light backgrounds with adaptive contrast
- Sidebar navigation with recent screens tracking
- Localized UI with 10 languages

---

## Project Structure

```
forawn/
├── assets/
│   └── lang/                     # Built-in language files (JSON)
├── lib/
│   ├── main.dart                 # App entry point, window setup, main navigation
│   ├── settings.dart             # Settings screen
│   ├── translate.dart            # Translator screen
│   ├── version.dart              # Version constant
│   ├── language_controller.dart  # Language loading helpers
│   ├── config/                   # Runtime configuration
│   ├── lang/                     # Language files copied next to the binary
│   ├── models/                   # Data models (songs, playlists, downloads, lyrics)
│   ├── screen/
│   │   ├── music_player_screen.dart   # Library, playlists, favorites
│   │   ├── player_screen.dart         # Full player with lyrics view
│   │   ├── playlist_detail_screen.dart# Single playlist view
│   │   ├── music_downloader_screen.dart
│   │   ├── video_downloader.dart
│   │   ├── downloads_screen.dart      # Download manager
│   │   ├── qrcode_generator.dart
│   │   ├── home_content.dart
│   │   └── lyrics_display_widget.dart
│   ├── services/
│   │   ├── tools_service.dart         # yt-dlp/ffmpeg download & validation
│   │   ├── download_manager.dart      # Download queue
│   │   ├── metadata_service.dart      # Deezer API metadata
│   │   ├── global_music_player.dart   # Shared player state
│   │   ├── local_music_database.dart  # Local library database
│   │   ├── playlist_service.dart
│   │   ├── lyrics_service.dart
│   │   ├── lyrics_adjuster.dart
│   │   ├── discord_service.dart
│   │   ├── window_media_service.dart  # Windows SMTC
│   │   ├── global_keyboard_service.dart
│   │   └── native_media_service.dart
│   ├── utils/
│   │   └── color_utils.dart           # Contrast helpers (WCAG)
│   └── widgets/
│       ├── app_title_bar.dart         # Reusable custom title bar
│       ├── sidebar_navigation.dart
│       ├── mini_player.dart
│       └── elegant_notification.dart
├── windows/                      # Windows runner
├── linux/                        # Linux runner
├── macos/                        # macOS runner
├── pubspec.yaml                  # Dependencies & configuration
├── analysis_options.yaml         # Linter configuration
└── README.md
```

---

## Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| Windows | Supported | Acrylic effects, SMTC integration |
| Linux | Supported | Requires GStreamer and keybinder dev packages |
| macOS | Supported | Requires network entitlement for tool downloads |

The Android, iOS and web folders are not part of the desktop feature set.

---

## Dependencies

### Framework

| Package | Version | Purpose |
|---------|---------|---------|
| Flutter SDK | >= 3.9.2 | UI framework |
| sqflite_common_ffi | ^2.3.6 | SQLite for desktop (FFI) |

### Media & Download

| Package | Version | Purpose |
|---------|---------|---------|
| audioplayers | ^5.2.1 | Audio playback |
| audio_service | ^0.18.18 | Background media session |
| audio_metadata_reader | ^1.4.2 | Metadata extraction |
| palette_generator | ^0.3.3+3 | Album-art dominant color |
| dio | ^5.9.0 | HTTP downloads |
| http | ^1.1.0 | HTTP requests |
| file_picker | ^6.1.1 | File selection |
| image | ^4.0.17 | Image processing |

### Window & System

| Package | Version | Purpose |
|---------|---------|---------|
| window_manager | ^0.5.2 | Frameless window, custom title bar |
| flutter_acrylic | ^1.1.0 | Acrylic/blur effects (Windows) |
| hotkey_manager | ^0.2.3 | Global keyboard shortcuts |
| smtc_windows | ^1.1.0 | Windows media transport controls |
| discord_rich_presence | ^1.0.0 | Discord status |

### Utilities

| Package | Version | Purpose |
|---------|---------|---------|
| shared_preferences | ^2.0.0 | Key-value storage |
| path_provider | ^2.1.1 | Filesystem paths |
| sqflite | ^2.3.0 | SQLite |
| url_launcher | ^6.1.10 | Open external links |
| share_plus | ^12.0.1 | Sharing |
| qr_flutter | ^4.0.0 | QR code generation |
| translator | ^1.0.4+1 | Translation engine |
| uuid | ^4.5.2 | Unique identifiers |
| image_picker | ^1.0.4 | Image selection |
| flutter_markdown | ^0.6.14 | Markdown rendering |
| logging | ^1.2.0 | Logging |
| path | ^1.8.3 | Path handling |

---

## Installation

### Requirements

- **Windows**: Windows 10 or later (64-bit)
- **Linux**: GStreamer and keybinder development packages (see below)
- **macOS**: macOS with Xcode command line tools
- **RAM**: 4 GB minimum, 8 GB recommended
- **Internet**: required on first run to download `yt-dlp` and `ffmpeg` (about 150 MB), and for download features

### Linux system dependencies

The `audioplayers` and `hotkey_manager` plugins require system libraries. Install them with:

```bash
# Fedora
sudo dnf install -y gstreamer1-devel gstreamer1-plugins-base-devel keybinder3-devel

# Ubuntu / Debian
sudo apt install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libkeybinder-3.0-dev
```

---

## Development

### Prerequisites

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.9.2 or higher)
2. Install Git

### Clone and run

```bash
git clone https://github.com/Frantt21/forawn.git
cd forawn

flutter pub get

# Run on your platform
flutter run -d windows   # Windows
flutter run -d linux     # Linux
flutter run -d macos     # macOS
```

### Build release binaries

```bash
flutter build windows --release
flutter build linux --release
flutter build macos --release
```

Build outputs:

```
build/windows/x64/runner/Release/forawn.exe
build/linux/x64/release/bundle/forawn
build/macos/Build/Products/Release/forawn.app
```

---

## Tools (`yt-dlp` and `ffmpeg`)

The download features need `yt-dlp` and `ffmpeg`. On first launch the app downloads the correct binary for your platform into the `tools/` folder next to the executable:

| Platform | yt-dlp binary | ffmpeg archive |
|----------|---------------|----------------|
| Windows | `yt-dlp.exe` | `win64-gpl.zip` |
| Linux x64 | `yt-dlp_linux` | `linux64-gpl.tar.xz` |
| Linux ARM | `yt-dlp_linux_aarch64` | `linuxarm64-gpl.tar.xz` |
| macOS Intel | `yt-dlp_macos` | `macos64-gpl.zip` |
| macOS ARM | `yt-dlp_macos` | `macos64-arm64-gpl.zip` |

Binaries are validated on startup (minimum size plus a real execution check). If a binary is missing or corrupt, it is re-downloaded automatically.

---

## Localization

The UI is translated into 10 languages:

English, Spanish, French, German (Switzerland), Portuguese, Russian, Japanese, Korean, Chinese, Polish.

### Adding a new language

1. Copy `assets/lang/en.json` to `assets/lang/<code>.json` (for example `it.json`)
2. Translate every key
3. Add the file to the `assets:` section of `pubspec.yaml` if needed
4. The language will be detected and selectable in Settings

Language files can also be placed next to the executable in a `lang/` folder, so translations can be updated without recompiling.

---

## Contributing

1. **Report bugs** — open an issue with reproduction steps
2. **Suggest features** — describe the use case and expected behavior
3. **Submit pull requests** — fork, branch, implement, and open a PR
4. **Improve translations** — extend or fix the JSON language files

### Guidelines

- Follow the Dart/Flutter style guide
- Run `flutter analyze` and `flutter test` before submitting
- Keep changes focused and write meaningful commit messages

---

## Feedback and Support

- Discord: @frntts
- Issues: [GitHub Issues](https://github.com/Frantt21/forawn/issues)
- Discussions: [GitHub Discussions](https://github.com/Frantt21/forawn/discussions)

---

## License

This project is licensed under the terms of the [LICENSE](LICENSE) file included in the repository.
