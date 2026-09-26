// win_diag.dart
//
// Utilidad Windows-only: leer el estado de la ventana principal (¿es la
// ventana en primer plano?, ¿qué valor tiene DWMWA_SYSTEMBACKDROP_TYPE?) y
// forzarla a primer plano. Necesario porque el DWM deja el material de fondo
// "pegado" en su estado inactivo si la ventana se compone por primera vez sin
// foco, y ninguna re-aplicación posterior lo recupera.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int kSystemBackdropType = 38;

typedef _FindWindowWNative = IntPtr Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _FindWindowWDart = int Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _DwmGetWindowAttributeNative = Int32 Function(
  IntPtr hwnd,
  Uint32 dwAttribute,
  Pointer<Void> pvAttribute,
  Uint32 cbAttribute,
);
typedef _DwmGetWindowAttributeDart = int Function(
  int hwnd,
  int dwAttribute,
  Pointer<Void> pvAttribute,
  int cbAttribute,
);

typedef _SetForegroundWindowNative = Int32 Function(IntPtr hwnd);
typedef _SetForegroundWindowDart = int Function(int hwnd);

typedef _BringWindowToTopNative = Int32 Function(IntPtr hwnd);
typedef _BringWindowToTopDart = int Function(int hwnd);

typedef _AttachThreadInputNative = Int32 Function(
  Uint32 idAttach,
  Uint32 idAttachTo,
  Int32 fAttach,
);
typedef _AttachThreadInputDart = int Function(int idAttach, int idAttachTo, int fAttach);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
  IntPtr hwnd,
  Pointer<Uint32> lpdwProcessId,
);
typedef _GetWindowThreadProcessIdDart = int Function(int hwnd, Pointer<Uint32> lpdwProcessId);

typedef _GetCurrentThreadIdNative = Uint32 Function();
typedef _GetCurrentThreadIdDart = int Function();

_FindWindowWDart? _findWindow;
_GetForegroundWindowDart? _getForegroundWindow;
_DwmGetWindowAttributeDart? _getWindowAttribute;
_SetForegroundWindowDart? _setForegroundWindow;
_BringWindowToTopDart? _bringWindowToTop;
_AttachThreadInputDart? _attachThreadInput;
_GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
_GetCurrentThreadIdDart? _getCurrentThreadId;
bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final dwmapi = DynamicLibrary.open('dwmapi.dll');
    _findWindow =
        user32.lookupFunction<_FindWindowWNative, _FindWindowWDart>(
      'FindWindowW',
    );
    _getForegroundWindow = user32
        .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
      'GetForegroundWindow',
    );
    _getWindowAttribute = dwmapi.lookupFunction<
        _DwmGetWindowAttributeNative,
        _DwmGetWindowAttributeDart>('DwmGetWindowAttribute');
    _setForegroundWindow = user32
        .lookupFunction<_SetForegroundWindowNative, _SetForegroundWindowDart>(
      'SetForegroundWindow',
    );
    _bringWindowToTop = user32
        .lookupFunction<_BringWindowToTopNative, _BringWindowToTopDart>(
      'BringWindowToTop',
    );
    _attachThreadInput = user32
        .lookupFunction<_AttachThreadInputNative, _AttachThreadInputDart>(
      'AttachThreadInput',
    );
    _getWindowThreadProcessId = user32.lookupFunction<
        _GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _getCurrentThreadId = kernel32.lookupFunction<
        _GetCurrentThreadIdNative,
        _GetCurrentThreadIdDart>('GetCurrentThreadId');
  } catch (_) {
    _findWindow = null;
    _getForegroundWindow = null;
    _getWindowAttribute = null;
    _setForegroundWindow = null;
    _bringWindowToTop = null;
    _attachThreadInput = null;
    _getWindowThreadProcessId = null;
    _getCurrentThreadId = null;
  }
}

/// HWND de la ventana principal (clase del runner de Flutter), 0 si no hay.
int mainWindowHandle() {
  _resolve();
  final findWindow = _findWindow;
  if (findWindow == null) return 0;
  try {
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final hwnd = findWindow(className, nullptr);
    malloc.free(className);
    return hwnd;
  } catch (_) {
    return 0;
  }
}

/// true si la ventana principal es la ventana en primer plano del sistema.
bool isMainWindowForeground() {
  _resolve();
  final getForeground = _getForegroundWindow;
  if (getForeground == null) return false;
  final hwnd = mainWindowHandle();
  return hwnd != 0 && getForeground() == hwnd;
}

/// Valor actual de DWMWA_SYSTEMBACKDROP_TYPE (38), o null si no se pudo leer.
int? readSystemBackdrop() {
  _resolve();
  final getAttr = _getWindowAttribute;
  if (getAttr == null) return null;
  final hwnd = mainWindowHandle();
  if (hwnd == 0) return null;
  try {
    final out = malloc<Int32>();
    final hr =
        getAttr(hwnd, kSystemBackdropType, out.cast<Void>(), sizeOf<Int32>());
    final value = out.value;
    malloc.free(out);
    return hr == 0 ? value : null;
  } catch (_) {
    return null;
  }
}

/// Cadena corta de diagnóstico para logs.
String windowDiag() {
  if (!Platform.isWindows) return '';
  return 'front=${isMainWindowForeground()} backdrop=${readSystemBackdrop()}';
}

/// Fuerza que la ventana principal pase a primer plano.
///
/// `SetForegroundWindow` por sí solo puede ser rechazado por el "foreground
/// lock" de Windows (p. ej. si el usuario minimizó otra ventana justo al
/// abrir la app). El truco es adjuntar el input de nuestro hilo al hilo de la
/// ventana en primer plano, pedir el foco y desadjuntar: así el sistema lo
/// acepta como si fuera la misma cadena de input. Devuelve true si la
/// ventana quedó en primer plano.
bool forceForeground() {
  _resolve();
  final getForeground = _getForegroundWindow;
  final setForeground = _setForegroundWindow;
  final bringToTop = _bringWindowToTop;
  final attach = _attachThreadInput;
  final getThreadPid = _getWindowThreadProcessId;
  final getCurrentThreadId = _getCurrentThreadId;
  if (getForeground == null ||
      setForeground == null ||
      bringToTop == null ||
      attach == null ||
      getThreadPid == null ||
      getCurrentThreadId == null) {
    return false;
  }
  final hwnd = mainWindowHandle();
  if (hwnd == 0) return false;
  final fg = getForeground();
  if (fg == hwnd) return true;

  final pid = malloc<Uint32>();
  final fgThread = fg == 0 ? 0 : getThreadPid(fg, pid);
  malloc.free(pid);
  final ourThread = getCurrentThreadId();
  var attached = false;
  try {
    if (fgThread != 0 && fgThread != ourThread) {
      attached = attach(ourThread, fgThread, 1) != 0;
    }
    bringToTop(hwnd);
    setForeground(hwnd);
  } catch (_) {
    // Se ignora: el siguiente intento reintenta.
  } finally {
    if (attached) {
      try {
        attach(ourThread, fgThread, 0);
      } catch (_) {}
    }
  }
  return getForeground() == hwnd;
}
