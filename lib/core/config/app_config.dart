const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

abstract final class AppConfig {
  static String get supabaseUrl {
    if (_supabaseUrl.isEmpty) {
      throw StateError(
        'SUPABASE_URL is not set. '
        'Pass it as --dart-define=SUPABASE_URL=<value>.',
      );
    }
    return _supabaseUrl;
  }

  static String get supabaseAnonKey {
    if (_supabaseAnonKey.isEmpty) {
      throw StateError(
        'SUPABASE_ANON_KEY is not set. '
        'Pass it as --dart-define=SUPABASE_ANON_KEY=<value>.',
      );
    }
    return _supabaseAnonKey;
  }
}
