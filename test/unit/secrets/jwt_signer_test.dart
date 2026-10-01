import 'dart:convert';

import 'package:shipway/src/secrets/jwt_signer.dart';
import 'package:test/test.dart';

import 'signing_keys.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> _decode(String segment) =>
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(segment))))
        as Map<String, dynamic>;

void main() {
  group('ES256', () {
    test('matches the RFC 6979 test vector for P-256 and SHA-256', () {
      // Appendix A.2.5. A deterministic nonce means there is exactly one right
      // answer, so this proves the curve arithmetic and the nonce derivation
      // together, with no key of ours involved.
      final key = EcPrivateKey(
        BigInt.parse(
          'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
          radix: 16,
        ),
      );

      expect(
        _hex(key.sign(utf8.encode('sample'))),
        'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716'
        'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8',
      );
    });

    test('the signature is raw r||s, never DER', () {
      // A DER signature starts 0x30 and is 70 to 72 bytes. A JWT wants the two
      // integers back to back, and a server given DER says only "invalid".
      final signature = EcPrivateKey.parse(
        ecPkcs8Pem,
      ).sign(utf8.encode('header.payload'));

      expect(signature, hasLength(64));
    });

    test('reads a .p8 and the SEC1 form of the same key alike', () {
      expect(EcPrivateKey.parse(ecPkcs8Pem).d, EcPrivateKey.parse(ecSec1Pem).d);
    });

    test('builds a three-part token carrying the header and claims', () {
      final token = JwtSigner.es256(
        header: <String, Object?>{'kid': 'KEY123', 'typ': 'JWT'},
        claims: <String, Object?>{'iss': 'issuer', 'aud': 'appstoreconnect-v1'},
        pem: ecPkcs8Pem,
      );

      final parts = token.split('.');
      expect(parts, hasLength(3));
      expect(_decode(parts[0]), <String, dynamic>{
        'alg': 'ES256',
        'kid': 'KEY123',
        'typ': 'JWT',
      });
      expect(_decode(parts[1])['iss'], 'issuer');
      expect(token, isNot(contains('=')), reason: 'base64url, unpadded');
      expect(base64Url.decode(base64Url.normalize(parts[2])), hasLength(64));
    });

    test('an RSA key is refused by name rather than signed with', () {
      expect(
        () => EcPrivateKey.parse(rsaPkcs8Pem),
        throwsA(
          isA<KeyFormatException>().having(
            (e) => e.message,
            'message',
            contains('P-256'),
          ),
        ),
      );
    });
  });

  group('RS256', () {
    test('produces the signature openssl does', () {
      final signature = RsaPrivateKey.parse(
        rsaPkcs8Pem,
      ).sign(utf8.encode('header.payload'));

      expect(base64.encode(signature), rsaSignatureOfHeaderPayload);
    });

    test('reads a key whose line breaks arrived as backslash-n', () {
      // How `private_key` looks when a service-account JSON has been pasted
      // into a .env file rather than parsed.
      final escaped = rsaPkcs8Pem.replaceAll('\n', r'\n');

      expect(
        RsaPrivateKey.parse(escaped).modulus,
        RsaPrivateKey.parse(rsaPkcs8Pem).modulus,
      );
    });

    test('an EC key is refused', () {
      expect(
        () => RsaPrivateKey.parse(ecPkcs8Pem),
        throwsA(isA<KeyFormatException>()),
      );
    });
  });

  group('what is not a key', () {
    test('text without PEM armour', () {
      expect(
        () => EcPrivateKey.parse('not a key'),
        throwsA(isA<KeyFormatException>()),
      );
    });

    test('a truncated body', () {
      final lines = ecPkcs8Pem.trim().split('\n');
      final truncated = <String>[
        lines.first,
        lines[1].substring(0, 20),
        lines.last,
      ].join('\n');

      expect(
        () => EcPrivateKey.parse(truncated),
        throwsA(isA<KeyFormatException>()),
      );
    });
  });
}
