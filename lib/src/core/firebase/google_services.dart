import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One Android app listed in a `google-services.json`.
class GoogleServicesApp {
  const GoogleServicesApp({
    required this.packageName,
    required this.appId,
    this.projectId,
    this.projectNumber,
  });

  final String packageName;

  /// `mobilesdk_app_id`, which is what App Distribution calls the app.
  final String appId;

  final String? projectId;
  final String? projectNumber;
}

/// What looking for one app in a `google-services.json` found.
class GoogleServicesLookup {
  const GoogleServicesLookup.found(GoogleServicesApp this.app)
    : problem = null,
      fix = null;

  const GoogleServicesLookup.failed({
    required String this.problem,
    required String this.fix,
  }) : app = null;

  final GoogleServicesApp? app;
  final String? problem;
  final String? fix;
}

/// Reads which Firebase app a build belongs to.
///
/// Matched on package name, never by position. Firebase lists every Android
/// app in a project in the same download, so a file shared by a dev and a prod
/// flavor holds both, and the first entry is the right answer for only one of
/// them.
abstract final class GoogleServices {
  /// Every Android app in [contents].
  ///
  /// Throws [FormatException] when [contents] is not JSON.
  static List<GoogleServicesApp> appsIn(String contents) {
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    final project = decoded['project_info'];
    final projectId = project is Map ? project['project_id']?.toString() : null;
    final projectNumber = project is Map
        ? project['project_number']?.toString()
        : null;

    final clients = decoded['client'];
    if (clients is! List) return const <GoogleServicesApp>[];
    return <GoogleServicesApp>[
      for (final client in clients)
        if (_app(client, projectId, projectNumber) case final app?) app,
    ];
  }

  /// The app for [packageName] in the file at [path], resolved against
  /// [root].
  static GoogleServicesLookup lookup(
    String root,
    String path,
    String packageName,
  ) {
    final file = File(p.isAbsolute(path) ? path : p.join(root, path));
    if (!file.existsSync()) {
      return GoogleServicesLookup.failed(
        problem: '$path does not exist.',
        fix:
            'Download it from the Firebase console, or correct the path in '
            'shipway.yaml.',
      );
    }

    final List<GoogleServicesApp> apps;
    try {
      apps = appsIn(file.readAsStringSync());
    } on FormatException {
      return GoogleServicesLookup.failed(
        problem: '$path is not valid JSON.',
        fix: 'Download it again from the Firebase console.',
      );
    }

    for (final app in apps) {
      if (app.packageName == packageName) {
        return GoogleServicesLookup.found(app);
      }
    }
    final listed = apps.map((a) => a.packageName).join(', ');
    return GoogleServicesLookup.failed(
      problem:
          '$path has no Android app for $packageName'
          '${apps.isEmpty ? '' : '; it lists $listed'}.',
      fix:
          'Register $packageName in that Firebase project and download the '
          'file again, or name the app id with '
          'targets.firebase.android_app_id_ref.',
    );
  }

  static GoogleServicesApp? _app(
    Object? client,
    String? projectId,
    String? projectNumber,
  ) {
    if (client is! Map) return null;
    final info = client['client_info'];
    if (info is! Map) return null;
    final android = info['android_client_info'];
    final packageName = android is Map ? android['package_name'] : null;
    final appId = info['mobilesdk_app_id'];
    if (packageName is! String || appId is! String) return null;
    return GoogleServicesApp(
      packageName: packageName,
      appId: appId,
      projectId: projectId,
      projectNumber: projectNumber,
    );
  }
}
