// Integration test helpers.
// Requires local Supabase running on http://127.0.0.1:54321.
// Start with: supabase start

import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'http://127.0.0.1:54321';
const anonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    '.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9'
    '.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const serviceKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    '.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0'
    '.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

SupabaseClient newClient() => SupabaseClient(supabaseUrl, anonKey);
SupabaseClient newServiceClient() => SupabaseClient(supabaseUrl, serviceKey);

typedef UserSession = ({
  SupabaseClient client,
  String userId,
  String displayName,
  String publicId,
});

Future<UserSession> signInAnon({String? name}) async {
  final client = newClient();
  final res = await client.auth.signInAnonymously();
  final userId = res.user!.id;
  final publicId = _makePublicId();
  final displayName = name ?? 'Tester-${userId.substring(0, 6)}';
  await client.from('profiles').insert({
    'user_id': userId,
    'public_id': publicId,
    'display_name': displayName,
  });
  return (
    client: client,
    userId: userId,
    displayName: displayName,
    publicId: publicId,
  );
}

String _makePublicId() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rng = Random.secure();
  String part() =>
      List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
  return '${part()}-${part()}';
}

String uid() => DateTime.now().microsecondsSinceEpoch.toString();

Future<Map<String, dynamic>> createHousehold(
  SupabaseClient client,
  String name,
) async {
  return await client.rpc('create_household', params: {'p_name': name});
}

Future<Map<String, dynamic>> createInvite(
  SupabaseClient client,
  String householdId,
) async {
  return await client.rpc(
    'create_household_invite',
    params: {'p_household_id': householdId},
  );
}

Future<Map<String, dynamic>> joinByInvite(
  SupabaseClient client,
  String code,
) async {
  return await client.rpc('join_household_by_invite', params: {'p_code': code});
}
