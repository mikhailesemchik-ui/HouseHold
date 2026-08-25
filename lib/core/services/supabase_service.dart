import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/core/config/app_config.dart';

Future<void> initializeSupabase() async {
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
}

SupabaseClient get supabaseClient => Supabase.instance.client;
