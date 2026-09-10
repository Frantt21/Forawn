#!/bin/bash
cd "$(dirname "$0")"

echo "=== Forawn Windows Build ==="

# Step 1: flutter build (may fail due to cargokit vcxproj bug)
echo "[1/3] Building with Flutter..."
flutter build windows --release 2>&1
FLUTTER_EXIT=$?

if [ $FLUTTER_EXIT -eq 0 ]; then
    echo "=== Build succeeded! ==="
    exit 0
fi

# Step 2: Fix the vcxproj
VCXPROJ="build/windows/x64/plugins/smtc_windows/smtc_windows_cargokit.vcxproj"
if [ ! -f "$VCXPROJ" ]; then
    echo "VCXPROJ not found. Build failed for a different reason."
    exit 1
fi

echo "[2/3] Fixing cargokit vcxproj..."
dart run fix_vcxproj.dart "$VCXPROJ"

# Step 3: Rebuild with MSBuild
echo "[3/3] Rebuilding with MSBuild..."
"C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe" \
    --build build/windows/x64 --config Release

if [ -f "build/windows/x64/runner/Release/forawn.exe" ]; then
    echo ""
    echo "=== Build succeeded! forawn.exe ready ==="
else
    echo ""
    echo "=== Build failed ==="
    exit 1
fi
