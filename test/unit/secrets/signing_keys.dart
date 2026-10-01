/// Throwaway keys for the signing and verification tests.
///
/// Generated with `openssl` for these tests and attached to no account. Held
/// as bare base64 and wrapped in their PEM armour at run time, so that no
/// file in the package contains something a secret scanner — pub's included —
/// would be right to stop a publish over.
library;

String _pem(String label, List<String> body) =>
    '-----BEGIN $label-----\n${body.join('\n')}\n-----END $label-----\n';

/// A P-256 key in PKCS#8, the form of an App Store Connect `.p8`.
final String ecPkcs8Pem = _pem('PRIVATE KEY', const <String>[
  'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgBbLQeQd3+s00Iq2W',
  'kLTl/MLzPC9jQ3igs3AO9dvzY6+hRANCAAQVbRFMyLAzNwYZLdQnAv27xNH91Oz5',
  '0bpNt9/y3f0BP8wiZ9z0ZRC/ftbnyKmNi6LMF8XUh7G212D2C+9ZMj54',
]);

/// The same key in SEC1, as `openssl ecparam -genkey` writes it.
final String ecSec1Pem = _pem('EC PRIVATE KEY', const <String>[
  'MHcCAQEEIAWy0HkHd/rNNCKtlpC05fzC8zwvY0N4oLNwDvXb82OvoAoGCCqGSM49',
  'AwEHoUQDQgAEFW0RTMiwMzcGGS3UJwL9u8TR/dTs+dG6Tbff8t39AT/MImfc9GUQ',
  'v37W58ipjYuizBfF1Iexttdg9gvvWTI+eA==',
]);

/// A 2048-bit RSA key in PKCS#8, the form of a service account's
/// `private_key`.
final String rsaPkcs8Pem = _pem('PRIVATE KEY', const <String>[
  'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCVz6/h1UIkvHvN',
  '2uVIOYClPg0fh9bDx/h8ghezh778z5wF8eZrG2TpcraGV6Aq9DZKZzp5PFuD/kMk',
  'ftLDnbqn5oblnMuCKxMtUu7mljJkgPS1X0w8ifMqYrmpA5O/4vRC9+NXVp8z7Pa7',
  '24BJnKuwp+qUJoBVOy6NJfp2a/BQ6zxlVZ2cLxeim6RkX8HN3Z6DvyWfY6B4vv+l',
  'tcbqQTaTl1MN/lW8pC/Ce56QcbgQ2LKB9lLCvJpJoWnSW8AKtip+HF7wPRI0iHai',
  'gTgeGeQs6+SDDz6CtTrROweGcNy8wok8ZHrq2zc6ErUQnk+7o+ZoieGmEzFvZ2BX',
  '8qucxTPLAgMBAAECggEAOI+uyJVzQRp2pbyg93laZEj+vGpVgBqWay/U0gAM8DdU',
  'IXx4sfSoT2lzl1orCzyj6Mh7r71Fkhqj7/oACkIZcH3dbYCa51zrAyA+OYn4obB8',
  'c6P0zSCKUfTvQuwqUvbVoRklWNrIBdtQNpIDqAdCXVKwgtncdxF+nGT74M0U8P+j',
  'q1tc81HHd5N1eVKzZfXRxwziiCUZY6zyCqKviXdqacFiaXoph/ugI2xI556QjnHt',
  't1H8QfogOGtDE2xTNwpmOAf+NacIDQsG7GJUve35HGww3IhRHqjlN/1MOoqqWKAv',
  'hEmXXPX0C5rZITraO4Pvf079j0AU8YjrpyNhFL3x2QKBgQDGzC+AK/Xe0O/g18RD',
  'kjkD3E023KWQD+s19zIbe9hPcTNMRMTcY+KUDMSqIlVTVB2QTTx0OjtfUjk8V32U',
  'TYLWfVVECcStsC1uJHdcGbSnhrGdQJ+023XWkMC2COtTcrEH8+GxobGGcW7xO0P/',
  'e0N/o6TKaL7xlm++LWUjRZczaQKBgQDA6xMV0lwMnywSNpprg99U4tssQLSaKRTJ',
  'B2/pcc3GH4g4hXt41pb4cnHdb9F+8viJTtZwefbpHMWyUpdgOfqk4S7/pvU7fROG',
  'rhqmYpxHLCUmCSRcaj3LXOC45toKJctgmEik/wI682lrrEyoLfq4JkCWnRzAKhpu',
  'SOshxyPrEwKBgDBHblHGW1PdkiQcwoFWhZo2alokg+DUvN7CRdz+2q2QZFDlcpnD',
  'eEdUQn6/D9HI39UnrMLdUYX4xgWticX2fQvyLD710FoOKzpQiNxJMeJth70U8LRP',
  'h/Kv/N04lU4S0IOJ6wnkpuRrr/HN3tmw6deZum+duKGbU0/wXluOjwXhAoGASX3D',
  'yX5Xfp9sZIvUi7yy6V16bQNBSbD4sBRbN60Y3K7Kb+25ubDV1lOSuO6N+jSJJZWY',
  '70QnIWrKjUIVVJ0BtKnsA4wQw9bEB3xvvo62Rg61ICY/ac03OS9qlEWtLkxzi5q3',
  'odNbgCWWNWRv12mcp2Y7GKVFfJcNdpHksPtx3W0CgYEApd5HS1gh7DBRKx3T+aTv',
  '52vA7mwRVUGAGQRjhNGTcl4zzinwM7Xq8O46otldeSbljXnwJg7nzyfl6GTyXBcd',
  'WyFHQgl4vzw6QOkUvIbA03ixNsKWp4oK9g9Uew2nUFCuHQivM7ePYHkrvZIsc9oP',
  'hUiTdwlBPnm8n7br+ZGWDsI=',
]);

/// What `openssl dgst -sha256 -sign` produces for `header.payload` under
/// [rsaPkcs8Pem]. PKCS#1 v1.5 is deterministic, so this is the one right
/// answer.
const String rsaSignatureOfHeaderPayload =
    'CESvnch/7jX7ILSrTBKZYHTAyEow4GmpugrYyXZNVosyXdr26u+KZujaD6An8QrE'
    'E3BQNmaVJoaymX+9BDl4FSLQjXrhjCSuSstQ5YPtZxv16/I/sghX/1hVzBavlb//'
    'XFDn2U3/34vjPJRsjPCsxs8qdy+Eyk0pUXzfqYt8ci3dS9vzk90SMx0eJlmrlnGd'
    '9h6qOFfbGzUjbOvEcpjugJyWKX/XlZ4pbC7+iOM6FZC2f3k4fiLKKSWb8HirHdyB'
    '4FyY0Af8+8/1dpgvIszy5UPgn6ZzMiQFm8NtsQ7SFPORmVtCKMYZc0GjZF0zvKYv'
    'qbZ4pAGaydxmtoIPPaUHow==';
