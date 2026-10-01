import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Why a private key could not be used: not a PEM, not the kind expected, or
/// not a key at all.
class KeyFormatException implements Exception {
  const KeyFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Signs the two kinds of JWT a credential check needs, in plain Dart.
///
/// App Store Connect wants ES256 and Google wants RS256, and nothing in
/// `pubspec.yaml` signs either — `crypto` stops at hashes and HMAC. The
/// alternatives were a new dependency, or `openssl` through the process
/// runner. `openssl dgst -sign` takes its key from a *file*, so that route
/// means writing a private key to a temporary path for the length of a check
/// meant to be the safe way to ask; and it emits a DER signature that still
/// has to be unpacked, because a JWT wants the raw `r || s`. Both algorithms
/// are small with `BigInt`, so they are here and the key never leaves memory.
///
/// This is not constant-time, and does not need to be: it signs one
/// short-lived token on the machine that already holds the key, for nobody
/// who can time it.
abstract final class JwtSigner {
  /// A compact JWT signed with the P-256 key in [pem] — an App Store Connect
  /// `.p8`, which is PKCS#8.
  static String es256({
    required Map<String, Object?> header,
    required Map<String, Object?> claims,
    required String pem,
  }) {
    final key = EcPrivateKey.parse(pem);
    final input = _signingInput(<String, Object?>{
      'alg': 'ES256',
      ...header,
    }, claims);
    return '$input.${_segment(key.sign(utf8.encode(input)))}';
  }

  /// A compact JWT signed with the RSA key in [pem] — the `private_key` of a
  /// Google service account.
  static String rs256({
    required Map<String, Object?> header,
    required Map<String, Object?> claims,
    required String pem,
  }) {
    final key = RsaPrivateKey.parse(pem);
    final input = _signingInput(<String, Object?>{
      'alg': 'RS256',
      ...header,
    }, claims);
    return '$input.${_segment(key.sign(utf8.encode(input)))}';
  }

  static String _signingInput(
    Map<String, Object?> header,
    Map<String, Object?> claims,
  ) =>
      '${_segment(utf8.encode(jsonEncode(header)))}.'
      '${_segment(utf8.encode(jsonEncode(claims)))}';

  /// base64url without padding, which is what a JWT segment is.
  static String _segment(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// A P-256 private key, and ECDSA over SHA-256 with it.
class EcPrivateKey {
  EcPrivateKey(this.d) {
    if (d <= BigInt.zero || d >= _n) {
      throw const KeyFormatException('the key is not a valid P-256 scalar');
    }
  }

  /// Reads a PKCS#8 (`BEGIN PRIVATE KEY`) or SEC1 (`BEGIN EC PRIVATE KEY`)
  /// key.
  factory EcPrivateKey.parse(String pem) {
    final outer = _Der.sequenceOf(_pemBody(pem));
    if (outer.length < 2) {
      throw const KeyFormatException('the key is not a private key');
    }
    final _Der sec1;
    if (outer[1].tag == _Der.sequence) {
      // PKCS#8: version, algorithm, then the SEC1 key inside an octet string.
      final algorithm = outer[1].children;
      if (algorithm.length < 2 ||
          !_same(algorithm[0].bytes, _oidEcPublicKey) ||
          !_same(algorithm[1].bytes, _oidPrime256v1)) {
        throw const KeyFormatException(
          'the key is not a P-256 key, which is the only kind App Store '
          'Connect issues',
        );
      }
      if (outer.length < 3) {
        throw const KeyFormatException('the key is not a private key');
      }
      sec1 = _Der.parse(outer[2].bytes);
    } else {
      sec1 = _Der.parse(_pemBody(pem));
    }
    final fields = sec1.children;
    if (fields.length < 2 || fields[1].tag != _Der.octetString) {
      throw const KeyFormatException('the key is not an EC private key');
    }
    return EcPrivateKey(_toInt(fields[1].bytes));
  }

  /// The private scalar.
  final BigInt d;

  /// Signs [message], returning `r || s` as two 32-byte big-endian integers.
  ///
  /// That raw form is what a JWT carries. The DER `SEQUENCE { r, s }` that
  /// `openssl` and most libraries hand back is the common way to get a token
  /// every server rejects without saying why.
  ///
  /// The nonce is derived as RFC 6979 describes rather than drawn at random:
  /// a repeated or biased nonce gives away the key, and a deterministic one
  /// cannot repeat. It also makes the output checkable against the RFC's own
  /// test vectors.
  Uint8List sign(List<int> message) {
    final hash = sha256.convert(message).bytes;
    final z = _toInt(hash) % _n;

    final x = _toBytes(d, 32);
    final h = _toBytes(z, 32);
    var v = List<int>.filled(32, 0x01);
    var k = List<int>.filled(32, 0x00);
    k = _hmac(k, <int>[...v, 0x00, ...x, ...h]);
    v = _hmac(k, v);
    k = _hmac(k, <int>[...v, 0x01, ...x, ...h]);
    v = _hmac(k, v);

    while (true) {
      v = _hmac(k, v);
      final nonce = _toInt(v);
      if (nonce > BigInt.zero && nonce < _n) {
        final r = _multiply(nonce, _g)!.x % _n;
        final s = (nonce.modInverse(_n) * (z + r * d)) % _n;
        if (r != BigInt.zero && s != BigInt.zero) {
          return Uint8List.fromList(<int>[
            ..._toBytes(r, 32),
            ..._toBytes(s, 32),
          ]);
        }
      }
      k = _hmac(k, <int>[...v, 0x00]);
      v = _hmac(k, v);
    }
  }

  static List<int> _hmac(List<int> key, List<int> data) =>
      Hmac(sha256, key).convert(data).bytes;

  // NIST P-256, from FIPS 186-4 D.1.2.3.
  static final BigInt _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  static final BigInt _a = _p - BigInt.from(3);
  static final BigInt _n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16,
  );
  static final _Point _g = (
    x: BigInt.parse(
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
      radix: 16,
    ),
    y: BigInt.parse(
      '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
      radix: 16,
    ),
  );

  /// Affine addition; null is the point at infinity.
  static _Point? _add(_Point? a, _Point? b) {
    if (a == null) return b;
    if (b == null) return a;
    final BigInt slope;
    if (a.x == b.x) {
      if ((a.y + b.y) % _p == BigInt.zero) return null;
      slope =
          ((BigInt.from(3) * a.x * a.x + _a) *
              (BigInt.two * a.y).modInverse(_p)) %
          _p;
    } else {
      slope = ((b.y - a.y) * ((b.x - a.x) % _p).modInverse(_p)) % _p;
    }
    final x = (slope * slope - a.x - b.x) % _p;
    return (x: x, y: (slope * (a.x - x) - a.y) % _p);
  }

  /// Double-and-add, most significant bit first.
  static _Point? _multiply(BigInt scalar, _Point point) {
    _Point? result;
    for (var bit = scalar.bitLength - 1; bit >= 0; bit--) {
      result = _add(result, result);
      if ((scalar >> bit).isOdd) result = _add(result, point);
    }
    return result;
  }

  static const List<int> _oidEcPublicKey = <int>[
    0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, //
  ];
  static const List<int> _oidPrime256v1 = <int>[
    0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, //
  ];
}

typedef _Point = ({BigInt x, BigInt y});

/// An RSA private key, and RSASSA-PKCS1-v1_5 over SHA-256 with it.
class RsaPrivateKey {
  RsaPrivateKey({required this.modulus, required this.privateExponent});

  /// Reads a PKCS#8 (`BEGIN PRIVATE KEY`) or PKCS#1 (`BEGIN RSA PRIVATE KEY`)
  /// key.
  factory RsaPrivateKey.parse(String pem) {
    var fields = _Der.sequenceOf(_pemBody(pem));
    if (fields.length >= 3 && fields[1].tag == _Der.sequence) {
      final algorithm = fields[1].children;
      if (algorithm.isEmpty || !_same(algorithm[0].bytes, _oidRsa)) {
        throw const KeyFormatException('the key is not an RSA key');
      }
      fields = _Der.sequenceOf(fields[2].bytes);
    }
    // version, n, e, d, then the CRT values this does not need.
    if (fields.length < 4 || fields.any((f) => f.tag != _Der.integer)) {
      throw const KeyFormatException('the key is not an RSA private key');
    }
    return RsaPrivateKey(
      modulus: _toInt(fields[1].bytes),
      privateExponent: _toInt(fields[3].bytes),
    );
  }

  final BigInt modulus;
  final BigInt privateExponent;

  /// Signs [message]. Deterministic: the same key and message always give the
  /// same bytes.
  Uint8List sign(List<int> message) {
    final length = (modulus.bitLength + 7) ~/ 8;
    final digest = <int>[..._sha256Prefix, ...sha256.convert(message).bytes];
    final padding = length - digest.length - 3;
    if (padding < 8) {
      throw const KeyFormatException('the RSA key is too short to sign with');
    }
    final encoded = <int>[
      0x00,
      0x01,
      ...List<int>.filled(padding, 0xff),
      0x00,
      ...digest,
    ];
    return _toBytes(_toInt(encoded).modPow(privateExponent, modulus), length);
  }

  /// The DER `DigestInfo` header naming SHA-256, from RFC 8017 §9.2.
  static const List<int> _sha256Prefix = <int>[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, //
    0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
  ];

  static const List<int> _oidRsa = <int>[
    0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, //
  ];
}

/// Just enough DER to walk a private key: definite lengths, no decoding of
/// anything but structure.
class _Der {
  _Der(this.tag, this.bytes);

  static const int integer = 0x02;
  static const int octetString = 0x04;
  static const int sequence = 0x30;

  final int tag;

  /// The content, without tag or length.
  final Uint8List bytes;

  List<_Der> get children => _readAll(bytes);

  static _Der parse(Uint8List data) {
    final all = _readAll(data);
    if (all.isEmpty) throw const KeyFormatException('the key is empty');
    return all.first;
  }

  /// The elements of the sequence [data] encodes.
  static List<_Der> sequenceOf(Uint8List data) {
    final outer = parse(data);
    if (outer.tag != sequence) {
      throw const KeyFormatException('the key is not a private key');
    }
    return outer.children;
  }

  static List<_Der> _readAll(Uint8List data) {
    final elements = <_Der>[];
    var offset = 0;
    while (offset < data.length) {
      if (offset + 2 > data.length) throw _truncated;
      final tag = data[offset++];
      var length = data[offset++];
      if (length & 0x80 != 0) {
        final count = length & 0x7f;
        if (count == 0 || count > 4 || offset + count > data.length) {
          throw _truncated;
        }
        length = 0;
        for (var i = 0; i < count; i++) {
          length = (length << 8) | data[offset++];
        }
      }
      if (offset + length > data.length) throw _truncated;
      elements.add(
        _Der(tag, Uint8List.sublistView(data, offset, offset + length)),
      );
      offset += length;
    }
    return elements;
  }

  static const KeyFormatException _truncated = KeyFormatException(
    'the key is truncated or is not a private key',
  );
}

/// The bytes between a PEM's `BEGIN` and `END` lines.
Uint8List _pemBody(String pem) {
  if (!pem.contains('-----BEGIN')) {
    throw const KeyFormatException('the key is not a PEM private key');
  }
  if (pem.contains('ENCRYPTED')) {
    throw const KeyFormatException(
      'the key is passphrase-protected, which no API key is',
    );
  }
  final body = pem
      // A key that has been through JSON or a .env file may hold its line
      // breaks as two characters.
      .replaceAll(r'\n', '\n')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  try {
    return base64.decode(body);
  } on FormatException {
    throw const KeyFormatException(
      'the key is not valid base64 inside its PEM',
    );
  }
}

BigInt _toInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

/// [value] big-endian, left-padded to [length] bytes.
Uint8List _toBytes(BigInt value, int length) {
  final out = Uint8List(length);
  var rest = value;
  final mask = BigInt.from(0xff);
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (rest & mask).toInt();
    rest >>= 8;
  }
  return out;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
