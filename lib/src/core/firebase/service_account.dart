import 'dart:convert';
import 'dart:io';

/// What a service-account JSON says about itself — never the key.
///
/// Read so a release can say who is about to upload, and to which project
/// that account belongs. Using the wrong project's account looks exactly like
/// using the right one until App Distribution refuses the upload.
class ServiceAccountIdentity {
  const ServiceAccountIdentity({this.email, this.projectId});

  final String? email;
  final String? projectId;

  /// The identity in the file at [path], or null when it is not a readable
  /// JSON object.
  static ServiceAccountIdentity? read(String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(File(path).readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return ServiceAccountIdentity(
      email: decoded['client_email']?.toString(),
      projectId: decoded['project_id']?.toString(),
    );
  }
}
