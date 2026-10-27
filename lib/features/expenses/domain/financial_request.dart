import 'dart:convert';
import 'dart:math';

/// A random RFC 4122 version-4 UUID identifying one logical financial
/// submission. The server stores it with the canonical payload so a retry of
/// the same submission can never create a second record.
String generateRequestId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// A short, non-reversible fingerprint of a submission's content (FNV-1a, 64
/// bit). Used only to notice that the user changed a submission whose outcome
/// is unknown, so the form never has to keep amounts or names in storage. It
/// is not a security primitive.
String payloadFingerprint(Iterable<String> parts) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(parts.join('\u001f'))) {
    hash = (hash ^ byte) * prime;
  }
  String half(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${half(hash >> 32)}${half(hash)}';
}
