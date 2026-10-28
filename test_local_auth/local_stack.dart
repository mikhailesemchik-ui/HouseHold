// Shared helpers for the opt-in local-auth tests. They talk to the ISOLATED
// hhsqltest stack only: http://127.0.0.1:55421 (Auth/API) and :55424 (mail
// capture), and refuse to run unless HH_ALLOW_STACK=hhsqltest.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final env = Platform.environment;
final stackEnabled =
    env['HH_ALLOW_STACK'] == 'hhsqltest' &&
    (env['HH_AUTH_URL'] ?? '') == 'http://127.0.0.1:55421' &&
    (env['HH_MAIL_URL'] ?? '') == 'http://127.0.0.1:55424' &&
    env['HH_ANON_KEY'] != null &&
    env['HH_SERVICE_KEY'] != null;

class MemoryPkceStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      values[key] = value;
  @override
  Future<void> removeItem({required String key}) async => values.remove(key);
}

SupabaseClient newClient(MemoryPkceStorage pkce) => SupabaseClient(
  env['HH_AUTH_URL']!,
  env['HH_ANON_KEY']!,
  authOptions: AuthClientOptions(
    authFlowType: AuthFlowType.pkce,
    pkceAsyncStorage: pkce,
  ),
);

final runId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
final created = <String>[];
void track(String? id) {
  if (id == null) return;
  created.add(id);
  final file = env['HH_IDS_FILE'];
  if (file != null) {
    File(file).writeAsStringSync('$id\n', mode: FileMode.append);
  }
}

Future<Map<String, dynamic>> mailApi(
  String path, {
  String method = 'GET',
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('${env['HH_MAIL_URL']}$path'),
    );
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (!text.startsWith('{')) return <String, dynamic>{};
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<List<Map<String, dynamic>>> mailTo(String address) async {
  final all = await mailApi('/api/v1/messages');
  return [
    for (final m in (all['messages'] as List).cast<Map<String, dynamic>>())
      if ((m['To'] as List).any((t) => t['Address'] == address)) m,
  ];
}

Future<String> latestCode(String address) async {
  final messages = await mailTo(address);
  expect(messages, isNotEmpty, reason: 'no mail for $address');
  final detail = await mailApi('/api/v1/message/${messages.first['ID']}');
  final match = RegExp(r'\b(\d{6})\b').firstMatch(detail['Text'] as String);
  expect(match, isNotNull);
  return match!.group(1)!;
}

String subjectOf(Map<String, dynamic> m) => m['Subject'] as String;

Map<String, dynamic> claims(String jwt) {
  final part = jwt.split('.')[1];
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))))
      as Map<String, dynamic>;
}

Future<int> userCount(SupabaseClient admin) async =>
    (await admin.auth.admin.listUsers(perPage: 1000)).length;

Future<int> rowCount(SupabaseClient admin, String table) async =>
    (await admin.from(table).select('*')).length;
