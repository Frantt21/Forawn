import 'dart:io';

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : 'build/windows/x64/plugins/smtc_windows/smtc_windows_cargokit.vcxproj';

  final file = File(path);
  if (!file.existsSync()) {
    print('File not found: $path');
    exit(1);
  }

  var content = file.readAsStringSync();

  // Remove ANSI escape codes
  content = content.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');

  // The problem: CMake generates a single <Command> line like:
  //   cmake -E env "CARGOKIT_CMAKE=..." ... CARGOKIT_ROOT_PROJECT_DIR=D:/path/windows "FLUTTER_DOCTOR_OUTPUT...\n...\run_build_tool.cmd" build-cmake
  //
  // The doctor output is INSIDE the quoted argument (after the " that follows "windows ").
  // We need to remove the doctor output between that " and the run_build_tool.cmd".
  //
  // Strategy: use a single regex that matches from CARGOKIT_ROOT_PROJECT_DIR=...windows "
  // through to run_build_tool.cmd", and replace with just the clean ending.
  //
  // The regex needs to handle embedded \r\n in the quoted string.

  final cmdPath =
      'D:/Programacion/Forawn/windows/flutter/ephemeral/.plugin_symlinks/smtc_windows/cargokit/run_build_tool.cmd';

  // Match: CARGOKIT_ROOT_PROJECT_DIR=D:/Programacion/Forawn/windows "...junk...run_build_tool.cmd"
  // where the "junk" can contain any characters including newlines
  final doctorPattern = RegExp(
    r'(CARGOKIT_ROOT_PROJECT_DIR=D:/Programacion/Forawn/windows )'
    r'"'    // opening quote of the contaminated argument
    r'[\s\S]*?'  // doctor output (any characters including newlines)
    r'(run_build_tool\.cmd")',  // closing of the contaminated argument
    multiLine: true,
  );

  final before = content.length;
  content = content.replaceAllMapped(doctorPattern, (m) {
    return '${m.group(1)}"$cmdPath"';
  });

  // Clean excess blank lines
  content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  file.writeAsStringSync(content);

  final after = file.readAsStringSync();
  print('Fixed: $path (${before} -> ${after.length} bytes)');

  // Verify
  if (after.contains('Admin@') || after.contains('/////////////////')) {
    print('WARNING: Doctor output still present!');
  } else {
    print('OK: No doctor output found');
  }
  if (after.contains(cmdPath)) {
    print('OK: Full cmd path present');
  } else {
    print('WARNING: Full cmd path missing!');
  }
  if (after.contains('cmake.exe') && after.contains('-E env')) {
    print('OK: cmake -E env command intact');
  } else {
    print('WARNING: cmake -E env command may be broken!');
  }
}
