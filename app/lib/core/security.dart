import 'dart:io';

import 'package:crypto/crypto.dart';

String normalizeFingerprint(String value) =>
    value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();

bool isValidFingerprint(String value) => normalizeFingerprint(value).length == 64;

/// A client that trusts no public root and accepts exactly one certificate,
/// identified by the SHA-256 of its DER bytes. This is stricter than relying
/// on badCertificateCallback alone because a public CA certificate would
/// otherwise be trusted before the callback runs.
HttpClient pinnedHttpClient(String fingerprint) {
  final expected = normalizeFingerprint(fingerprint);
  final context = SecurityContext(withTrustedRoots: false);
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 5)
    ..badCertificateCallback = (X509Certificate cert, String host, int port) {
      final actual = sha256.convert(cert.der).toString();
      return actual == expected;
    };
  return client;
}
