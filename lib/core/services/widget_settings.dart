import 'package:shared_preferences/shared_preferences.dart';

enum WidgetPrivacyMode { showNames, countsOnly }

class WidgetSettings {
  static const _key = 'widget_privacy_mode';

  static Future<WidgetPrivacyMode> getPrivacyMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return value == 'show_names'
        ? WidgetPrivacyMode.showNames
        : WidgetPrivacyMode.countsOnly;
  }

  static Future<void> setPrivacyMode(WidgetPrivacyMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      mode == WidgetPrivacyMode.showNames ? 'show_names' : 'counts_only',
    );
  }
}
