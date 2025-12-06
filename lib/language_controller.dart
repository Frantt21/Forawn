// import 'package:flutter/material.dart';
// import 'package:shared_preferences/shared_preferences.dart';
// import 'main.dart' show loadLanguageFromExeOrAssets;

// class LanguageController {
//   final ValueNotifier<String> currentLangCode = ValueNotifier<String>('en');
//   final ValueNotifier<Map<String, String>> currentLangMap = ValueNotifier<Map<String, String>>({});

//   Future<void> initialize(String code) async {
//     final map = await loadLanguageFromExeOrAssets(code);
//     currentLangCode.value = code;
//     currentLangMap.value = map;
//   }

//   Future<void> changeLanguage(String code) async {
//     final prefs = await SharedPreferences.getInstance();
//     await prefs.setString('preferred_lang', code);
//     final map = await loadLanguageFromExeOrAssets(code);
//     currentLangCode.value = code;
//     currentLangMap.value = map;
//   }

//   String getText(String key, {String? fallback}) {
//     return currentLangMap.value[key] ?? fallback ?? key;
//   }
// }

// final languageController = LanguageController();
