# 📝 Forawn

**Forawn** is a modular and multilingual desktop application for Windows, designed to offer clarity, speed, and customization. Built with Flutter and SQLite, it provides a refined experience for organizing notes, managing categories, and accessing powerful tools such as music downloading, AI image generation, video downloading, translation, and more.

---

## 🚀 Features

### 📋 Core Note System
- **Create, edit, archive, and delete notes** with rich text support
- **Pin important notes** to keep them at the top
- **Organize with categories** and powerful search functionality
- **Attach images** to your notes for visual context
- **Undo/redo actions** with confirmation dialogs for safety
- **Trash system** with recovery options before permanent deletion
- **Markdown support** for formatted notes
- **Fully localized interface** with 10 language support

### 🎨 Bonus Tools & Features
- 🎧 **Spotify Music Downloader** - Search and download music from Spotify with YouTube fallback
- 📥 **Download Manager** - Track and manage all your downloads with progress indicators
- 🖼️ **AI Image Generator (ForaAI)** - Generate creative visuals using AI
- 🎬 **Video Downloader** - Download videos from various platforms
- 🌐 **Text Translator** - Multi-language translation support
- 📱 **QR Code Generator** - Create QR codes for any text or URL
- 🔞 **NSFW Content Search (R34)** - Optional feature (disabled by default for safety)

### 🎨 UI/UX Features
- **Acrylic/Blur effects** for modern Windows 11 aesthetic
- **Custom window controls** with minimize, maximize, and close buttons
- **Sidebar navigation** with recent screens tracking
- **Dark mode support** with customizable themes
- **Smooth transitions** and animations
- **Responsive design** that adapts to window size

---

## 📁 Project Structure

```
Forawn/
├── lib/
│   ├── main.dart                      # App entry point & main navigation
│   ├── version.dart                   # Version information
│   ├── language_controller.dart       # Language management
│   │
│   ├── screen/                        # Main application screens
│   │   ├── home_content.dart          # Home dashboard
│   │   ├── notes_screen.dart          # Notes management
│   │   ├── archived_screen.dart       # Archived notes view
│   │   ├── trash_screen.dart          # Trash/recycle bin
│   │   ├── spotify_screen.dart        # Music downloader
│   │   ├── downloads_screen.dart      # Download manager
│   │   ├── foraai_screen.dart         # AI image generator
│   │   ├── video_downloader.dart      # Video download tool
│   │   ├── qrcode_generator.dart      # QR code creation
│   │   └── settings_screen.dart       # App settings
│   │
│   ├── widgets/                       # Reusable UI components
│   │   ├── sidebar_navigation.dart    # App sidebar
│   │   ├── note_card.dart             # Note display card
│   │   ├── note_popup.dart            # Note editor dialog
│   │   └── fade_transition_screen.dart # Screen transitions
│   │
│   ├── models/                        # Data models
│   │   ├── note.dart                  # Note data structure
│   │   └── download_task.dart         # Download task model
│   │
│   ├── db/                            # Database layer
│   │   └── notes_database.dart        # SQLite database handler
│   │
│   ├── services/                      # Business logic services
│   │   └── download_manager.dart      # Download management service
│   │
│   ├── utils/                         # Utility functions
│   │   └── color_utils.dart           # Color manipulation helpers
│   │
│   ├── lang/                          # Localization files (JSON)
│   │   ├── en.json                    # English
│   │   ├── es.json                    # Spanish
│   │   ├── fr.json                    # French
│   │   ├── de-CH.json                 # German (Switzerland)
│   │   ├── pt.json                    # Portuguese
│   │   ├── ru.json                    # Russian
│   │   ├── ja.json                    # Japanese
│   │   ├── ko.json                    # Korean
│   │   ├── zh.json                    # Chinese
│   │   └── pl.json                    # Polish
│   │
│   ├── settings.dart                  # Settings management
│   ├── translate.dart                 # Translation tool
│   ├── imgia_screen.dart              # Image handling
│   └── r34.dart                       # NSFW search (optional)
│
├── assets/                            # Static assets
├── windows/                           # Windows platform specific code
├── android/                           # Android platform code (future)
├── ios/                               # iOS platform code (future)
├── linux/                             # Linux platform code (future)
├── macos/                             # macOS platform code (future)
├── web/                               # Web platform code (future)
│
├── pubspec.yaml                       # Dependencies & configuration
├── analysis_options.yaml              # Dart linter configuration
└── README.md                          # This file
```

---

## 🧩 Architecture & Logic

### Database Layer
- **SQLite** for local data persistence
- **Notes Database** handles CRUD operations for notes
- **Categories** system for organization
- **Soft delete** with trash functionality before permanent removal
- **Image attachments** stored with file paths

### Download Management
- **Asynchronous download handling** with progress tracking
- **Queue system** for managing multiple downloads
- **Spotify integration** with YouTube fallback for music
- **Video platform support** for various sources
- **Download history** and status tracking

### Localization System
- **Dynamic language loading** from JSON files
- **External language files** can be edited without recompiling
- **Fallback mechanism** to default language if translation missing
- **10 languages supported** out of the box
- **Easy to extend** with new languages

### Window Management
- **Custom window controls** for native Windows feel
- **Acrylic/blur effects** using flutter_acrylic
- **Window state persistence** (size, position)
- **Effect customization** (transparency, blur intensity)

### Navigation System
- **Sidebar-based navigation** with icons and labels
- **Recent screens tracking** for quick access
- **Screen state management** with proper lifecycle
- **Smooth transitions** between screens

---

## 🛠️ Technologies & Dependencies

### Core Framework
- **Flutter SDK** ^3.9.2 - Cross-platform UI framework
- **Dart** - Programming language

### Database & Storage
- **sqflite** ^2.3.0 - SQLite database
- **sqflite_common_ffi** ^2.3.6 - FFI support for desktop
- **path_provider** ^2.1.1 - File system paths
- **shared_preferences** ^2.0.0 - Key-value storage

### UI & Visual
- **flutter_acrylic** ^1.1.0 - Acrylic/blur effects
- **bitsdojo_window** ^0.1.6 - Custom window controls
- **window_manager** ^0.5.1 - Window management
- **flutter_markdown** ^0.6.14 - Markdown rendering
- **qr_flutter** ^4.0.0 - QR code generation

### Media & Downloads
- **http** ^1.1.0 - HTTP requests
- **just_audio** ^0.9.34 - Audio playback
- **just_audio_background** ^0.0.1-beta.17 - Background audio
- **url_launcher** ^6.1.10 - Open URLs

### File Handling
- **file_picker** ^6.1.1 - File selection dialogs
- **image_picker** ^1.0.4 - Image selection
- **image** ^4.0.17 - Image processing
- **share_plus** ^12.0.1 - Share functionality

### Utilities
- **path** ^1.8.3 - Path manipulation
- **logging** ^1.2.0 - Logging system
- **cupertino_icons** ^1.0.8 - iOS-style icons

---

## 📦 Installation

### For Users
Download the latest installer from the [Releases](https://github.com/Frantt21/forawn/releases) page.

#### 🛡️ Windows Security Alert
If Windows shows a security warning:

![Screenshot](assets/warning_windows.jpg)

- This happens because the installer is not digitally signed
- Click "More info" → "Run anyway" to proceed
- The app is safe and open-source

#### 📁 Default Installation Location
```
C:\Users\YourName\AppData\Roaming\Forawn
```
- Avoids permission issues
- No administrator privileges required
- User-specific installation

#### System Requirements
- **OS**: Windows 10 or later (64-bit)
- **RAM**: 4GB minimum, 8GB recommended
- **Storage**: 200MB for app + space for downloads
- **Internet**: Required for download features and updates

---

## 🔧 Development Setup

### Prerequisites
1. Install [Flutter SDK](https://flutter.dev/docs/get-started/install) (3.9.2 or higher)
2. Install [Git](https://git-scm.com/)
3. Install [Visual Studio Code](https://code.visualstudio.com/) or [Android Studio](https://developer.android.com/studio)

### Clone & Run
```bash
# Clone the repository
git clone https://github.com/Frantt21/forawn.git
cd forawn

# Install dependencies
flutter pub get

# Run on Windows
flutter run -d windows

# Build release version
flutter build windows --release
```

### Building Installer
The project uses **Inno Setup** for creating Windows installers.
1. Install [Inno Setup](https://jrsoftware.org/isinfo.php)
2. Build the Flutter app: `flutter build windows --release`
3. Run the Inno Setup script (if available in the project)

---

## 🌍 Adding New Languages

1. Create a new JSON file in `lib/lang/` (e.g., `it.json` for Italian)
2. Copy the structure from `en.json`
3. Translate all keys to the target language
4. The app will automatically detect and load the new language

Example structure:
```json
{
  "app_title": "Forawn",
  "notes": "Notes",
  "create_note": "Create Note",
  ...
}
```

---

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

1. **Report bugs** - Open an issue with detailed reproduction steps
2. **Suggest features** - Share your ideas for improvements
3. **Submit PRs** - Fork, create a branch, and submit a pull request
4. **Improve translations** - Help translate to more languages
5. **Documentation** - Improve README, code comments, or wiki

### Development Guidelines
- Follow Dart/Flutter style guide
- Write meaningful commit messages
- Test your changes thoroughly
- Update documentation when needed

---

## 📬 Feedback & Support

- **Discord**: @frntts
- **Issues**: [GitHub Issues](https://github.com/Frantt21/forawn/issues)
- **Discussions**: [GitHub Discussions](https://github.com/Frantt21/forawn/discussions)

Don't hesitate to report errors, bugs, or ideas that can help in the development progress of Forawn!

---

## 📜 License

This project is licensed under the terms of the [LICENSE.txt](LICENSE.txt) file included in the repository.

---

## 🙏 Acknowledgments

- Flutter team for the amazing framework
- All contributors and testers
- Open-source community for libraries and tools

---

**Made with ❤️ by Frantt21**
