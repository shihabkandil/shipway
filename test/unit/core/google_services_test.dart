import 'dart:convert';

import 'package:shipway/src/core/firebase/google_services.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

Map<String, Object> _client(String packageName, String appId) =>
    <String, Object>{
      'client_info': <String, Object>{
        'mobilesdk_app_id': appId,
        'android_client_info': <String, Object>{'package_name': packageName},
      },
    };

/// The shape Firebase actually downloads: every Android app in the project in
/// one file, production first.
String _twoApps() => jsonEncode(<String, Object>{
  'project_info': <String, Object>{
    'project_id': 'acme-dev',
    'project_number': '111',
  },
  'client': <Object>[
    _client('com.acme.app', '1:111:android:prod'),
    _client('com.acme.app.dev', '1:111:android:dev'),
  ],
});

void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  GoogleServicesLookup lookup(String packageName) => GoogleServices.lookup(
    project.path,
    'android/app/google-services.json',
    packageName,
  );

  test('matches on package name, not position', () {
    // Taking the first entry is right for exactly one flavor, and uploads
    // every other flavor's build to that one's app.
    project.write('android/app/google-services.json', _twoApps());

    final app = lookup('com.acme.app.dev').app;

    expect(app?.appId, '1:111:android:dev');
    expect(app?.projectId, 'acme-dev');
    expect(app?.projectNumber, '111');
  });

  test('a package the file does not list names the ones it does', () {
    project.write('android/app/google-services.json', _twoApps());

    final result = lookup('com.acme.app.staging');

    expect(result.app, isNull);
    expect(result.problem, contains('com.acme.app.staging'));
    expect(result.problem, contains('com.acme.app, com.acme.app.dev'));
    expect(result.fix, contains('android_app_id_ref'));
  });

  test('a missing file names the path', () {
    final result = lookup('com.acme.app');
    expect(result.app, isNull);
    expect(result.problem, contains('android/app/google-services.json'));
  });

  test('a file that is not JSON says so', () {
    project.write('android/app/google-services.json', '<html>');
    expect(lookup('com.acme.app').problem, contains('not valid JSON'));
  });

  test('entries that are not Android apps are skipped', () {
    project.write(
      'android/app/google-services.json',
      jsonEncode(<String, Object>{
        'client': <Object>[
          <String, Object>{
            'client_info': <String, Object>{'mobilesdk_app_id': '1:1:web:x'},
          },
          'nonsense',
          _client('com.acme.app', '1:111:android:prod'),
        ],
      }),
    );
    expect(lookup('com.acme.app').app?.appId, '1:111:android:prod');
  });
}
