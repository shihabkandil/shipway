import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Captures what the CLI printed.
class _CapturingLogger extends Logger {
  final List<String> lines = <String>[];

  @override
  void info(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void err(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      lines.add(message ?? '');

  @override
  void detail(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void write(String? message) => lines.add(message ?? '');

  String get output => lines.join('\n');
}

const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    # QA lives here.
    flavors:
      prod:
        suffix: ""
''';

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  /// keytool writes no file of its own here, so the double writes one for it —
  /// otherwise every run would report the failure the real tool has when a
  /// password and its confirmation differ.
  void keytoolWrites() {
    runner.onRun = (invocation) {
      if (!invocation.commandLine.contains('-genkeypair')) return;
      final arguments = invocation.arguments;
      final path = arguments[arguments.indexOf('-keystore') + 1];
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x50, 0x4b, 0x03, 0x04]);
    };
  }

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project.write('shipway.yaml', _config);
    project.write('android/app/build.gradle.kts', 'android { }\n');
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    keytoolWrites();
  });

  Future<int> run(List<String> args, {HostPlatform? host}) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: host ?? HostPlatform.macos,
      ).run(<String>['--config=${project.path}/shipway.yaml', ...args]);

  group('ios-signing', () {
    /// A match repository, cloned by the double into wherever git was told to
    /// put it. Contents are nonsense on purpose: match encrypts files in place
    /// and leaves their names alone, which is the whole reason coverage is
    /// answerable without a passphrase.
    void matchRepoWith(List<String> profiles) {
      runner.onRun = (invocation) {
        if (invocation.arguments.first != 'clone') return;
        final destination = invocation.arguments.last;
        for (final relative in profiles) {
          File(p.join(destination, p.joinAll(p.posix.split(relative))))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('ENCRYPTED');
        }
      };
      runner.stub('git clone');
    }

    setUp(() {
      project.write('shipway.yaml', '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    ios:
      bundle_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
      prod:
        suffix: ""
''');
    });

    test('reports full coverage and succeeds', () async {
      matchRepoWith(<String>[
        'profiles/appstore/AppStore_com.acme.app.mobileprovision',
        'profiles/appstore/AppStore_com.acme.app.dev.mobileprovision',
      ]);

      final code = await run(<String>[
        'setup',
        'ios-signing',
        '--match-url',
        'git@github.com:acme/certs.git',
      ]);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('com.acme.app.dev'));
    });

    test('names the bundle ids with no profile, and fails', () async {
      // Reporting a gap as success would be worse than silence: the build
      // fails later, at signing, naming a profile instead of a flavor.
      matchRepoWith(<String>[
        'profiles/appstore/AppStore_com.acme.app.mobileprovision',
      ]);

      final code = await run(<String>[
        'setup',
        'ios-signing',
        '--match-url',
        'git@github.com:acme/certs.git',
      ]);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('com.acme.app.dev'));
      expect(logger.output, contains('no appstore profile'));
    });

    test('a development profile does not count as coverage', () async {
      matchRepoWith(<String>[
        'profiles/development/Development_com.acme.app.mobileprovision',
        'profiles/development/Development_com.acme.app.dev.mobileprovision',
      ]);

      final code = await run(<String>[
        'setup',
        'ios-signing',
        '--match-url',
        'git@github.com:acme/certs.git',
      ]);

      expect(code, ShipwayExit.environmentError);
    });

    test('it never decrypts, and never asks for the passphrase', () async {
      matchRepoWith(<String>[
        'profiles/appstore/AppStore_com.acme.app.mobileprovision',
        'profiles/appstore/AppStore_com.acme.app.dev.mobileprovision',
      ]);

      await run(<String>[
        'setup',
        'ios-signing',
        '--match-url',
        'git@github.com:acme/certs.git',
      ]);

      // The only thing it runs is a clone. No openssl, no match, no fastlane.
      for (final invocation in runner.invocations) {
        expect(invocation.executable, 'git', reason: invocation.commandLine);
      }
      expect(logger.output, isNot(contains('MATCH_PASSWORD is')));
    });

    test(
      'the repository is recorded in shipway.yaml, and no value is',
      () async {
        matchRepoWith(<String>[
          'profiles/appstore/AppStore_com.acme.app.mobileprovision',
          'profiles/appstore/AppStore_com.acme.app.dev.mobileprovision',
        ]);

        await run(<String>[
          'setup',
          'ios-signing',
          '--match-url',
          'git@github.com:acme/certs.git',
        ]);

        final written = project.read('shipway.yaml');
        expect(
          written,
          contains('match_git_url: git@github.com:acme/certs.git'),
        );
      },
    );

    test(
      'an empty repository says so rather than reporting coverage',
      () async {
        matchRepoWith(const <String>[]);

        final code = await run(<String>[
          'setup',
          'ios-signing',
          '--match-url',
          'git@github.com:acme/certs.git',
        ]);

        expect(code, ShipwayExit.environmentError);
        expect(logger.output, contains('empty'));
      },
    );

    test('--create changes the advice, not the safety', () async {
      // Creating a certificate spends one of a team's limited allowance, so
      // shipway says what to run rather than running it.
      matchRepoWith(<String>[
        'profiles/appstore/AppStore_com.acme.app.mobileprovision',
      ]);

      await run(<String>[
        'setup',
        'ios-signing',
        '--match-url',
        'git@github.com:acme/certs.git',
        '--create',
      ]);

      expect(logger.output, contains('fastlane match appstore'));
      expect(
        runner.invocations.any((i) => i.executable != 'git'),
        isFalse,
        reason: 'nothing but the clone should have run',
      );
    });

    test('without a url anywhere, it says where to put one', () async {
      final code = await run(<String>['setup', 'ios-signing']);
      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('match_git_url'));
    });
  });

  group('firebase', () {
    void firebaseConfig() {
      project.write('shipway.yaml', '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    android:
      application_id: com.acme.app
    ios:
      bundle_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
      prod:
        suffix: ""
    targets:
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
        ios_app_id_ref: FB_IOS_APP_ID
''');
    }

    void placeAndroid(String flavor, String appId) => project.write(
      'android/app/src/$flavor/google-services.json',
      '{"project_info":{"project_id":"acme"},'
          '"client":[{"client_info":{"mobilesdk_app_id":"$appId",'
          '"android_client_info":{"package_name":"com.acme.app.$flavor"}}}]}',
    );

    void placeIos(String flavor, String appId) => project.write(
      'ios/config/$flavor/GoogleService-Info.plist',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<plist version="1.0"><dict>'
          '<key>BUNDLE_ID</key><string>com.acme.app.$flavor</string>'
          '<key>GOOGLE_APP_ID</key><string>$appId</string>'
          '<key>PROJECT_ID</key><string>acme</string>'
          '</dict></plist>',
    );

    setUp(firebaseConfig);

    test('says what to download when there is nothing to find', () async {
      final code = await run(<String>['setup', 'firebase']);
      expect(code, ShipwayExit.environmentError);
      // The paths matter more than the advice: this is the one thing a reader
      // cannot guess.
      expect(logger.output, contains('android/app/src/<flavor>'));
      expect(logger.output, contains('ios/config/<flavor>'));
    });

    test('correlates each file with its flavor', () async {
      placeAndroid('dev', '1:111:android:aaa');
      placeIos('dev', '1:111:ios:bbb');

      final code = await run(<String>['setup', 'firebase']);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('1:111:android:aaa'));
      expect(logger.output, contains('1:111:ios:bbb'));
    });

    test('warns when one flavor has a file and another does not', () async {
      // Builds fine, fails at runtime, reporting to the wrong project — which
      // is exactly the kind of thing that should be said out loud.
      placeAndroid('dev', '1:111:android:aaa');

      await run(<String>['setup', 'firebase']);

      expect(logger.output, contains('prod'));
      expect(logger.output, contains('google-services.json'));
    });

    test('records the paths in shipway.yaml', () async {
      placeAndroid('dev', '1:111:android:aaa');
      placeIos('dev', '1:111:ios:bbb');

      await run(<String>['setup', 'firebase']);

      final written = project.read('shipway.yaml');
      expect(
        written,
        contains('android: android/app/src/dev/google-services.json'),
      );
      expect(written, contains('ios: ios/config/dev/GoogleService-Info.plist'));
    });

    test('a path the config already records is left alone', () async {
      // A team that put these somewhere unusual and wrote it down keeps their
      // answer.
      project.write('shipway.yaml', '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    flavors:
      dev:
        suffix: .dev
        firebase:
          android: somewhere/else/google-services.json
''');
      placeAndroid('dev', '1:111:android:aaa');

      await run(<String>['setup', 'firebase']);

      expect(
        project.read('shipway.yaml'),
        contains('somewhere/else/google-services.json'),
      );
    });

    test('stores the app ids under the names the config uses', () async {
      placeAndroid('dev', '1:111:android:aaa');
      placeIos('dev', '1:111:ios:bbb');

      await run(<String>['setup', 'firebase']);

      final stored = runner.invocations.where(
        (i) => i.commandLine.contains('add-generic-password'),
      );
      expect(stored, isNotEmpty);
      expect(
        stored.map((i) => i.arguments.join(' ')).join('\n'),
        allOf(contains('FB_ANDROID_APP_ID'), contains('FB_IOS_APP_ID')),
      );
    });

    void placeAndroidApps(String flavor, Map<String, String> apps) =>
        project.writeJson(
          'android/app/src/$flavor/google-services.json',
          <String, Object>{
            'project_info': <String, Object>{'project_id': 'acme'},
            'client': <Object>[
              for (final app in apps.entries)
                <String, Object>{
                  'client_info': <String, Object>{
                    'mobilesdk_app_id': app.value,
                    'android_client_info': <String, Object>{
                      'package_name': app.key,
                    },
                  },
                },
            ],
          },
        );

    /// What `security add-generic-password` was given for [name], if anything.
    String? storedValue(String name) {
      final matches = runner.invocations.where(
        (i) =>
            i.commandLine.contains('add-generic-password') &&
            i.arguments.contains(name),
      );
      return matches.isEmpty ? null : matches.single.stdin;
    }

    test(
      'a file listing several apps shows and stores the flavor\'s own',
      () async {
        project.write('shipway.yaml', '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    android:
      application_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
        firebase:
          distribution:
            android_app_id_ref: FB_DEV_APP_ID
      prod:
        suffix: ""
    targets:
      firebase:
        groups: [qa]
''');
        // Production first, the way Firebase writes the file. The first entry
        // used to be taken as the dev flavor's app.
        placeAndroidApps('dev', <String, String>{
          'com.acme.app': '1:111:android:prod',
          'com.acme.app.dev': '1:111:android:dev',
        });

        await run(<String>['setup', 'firebase']);

        expect(logger.output, contains('app id 1:111:android:dev'));
        expect(logger.output, isNot(contains('1:111:android:prod')));
        expect(storedValue('FB_DEV_APP_ID'), contains('1:111:android:dev'));
      },
    );

    test('one variable for flavors in different apps is not stored', () async {
      placeAndroid('dev', '1:111:android:aaa');
      placeAndroidApps('prod', <String, String>{
        'com.acme.app': '1:222:android:bbb',
      });

      await run(<String>['setup', 'firebase']);

      // Either value would send the other flavor's builds to the wrong app.
      expect(storedValue('FB_ANDROID_APP_ID'), isNull);
      expect(logger.output, contains('different Firebase apps'));
      expect(
        logger.output,
        contains('flavors.<name>.firebase.distribution.android_app_id_ref'),
      );
    });

    test('it never downloads anything', () async {
      placeAndroid('dev', '1:111:android:aaa');

      await run(<String>['setup', 'firebase']);

      // A google-services.json belongs to one Firebase app. Fetching the wrong
      // one surfaces as an app reporting to somebody else's analytics.
      for (final invocation in runner.invocations) {
        expect(
          invocation.executable,
          isNot(anyOf('firebase', 'flutterfire', 'curl')),
          reason: invocation.commandLine,
        );
      }
    });
  });

  group('android-signing', () {
    test(
      'the password reaches keytool on stdin, never as an argument',
      () async {
        // `ps` shows every argument of every running process, and key generation
        // is slow enough to read one off comfortably.
        final code = await run(<String>['setup', 'android-signing']);

        expect(code, ShipwayExit.success);
        final keytool = runner.invocation('-genkeypair');
        expect(keytool.arguments, isNot(contains('-storepass')));
        expect(keytool.arguments, isNot(contains('-keypass')));
        // Twice: the value, then its confirmation.
        final stdin = keytool.stdin!;
        final lines = stdin.trimRight().split('\n');
        expect(lines, hasLength(2));
        expect(lines.first, lines.last);
        expect(lines.first, hasLength(32));
      },
    );

    test('the generated password is nowhere in the output', () async {
      await run(<String>['setup', 'android-signing']);

      final password = runner
          .invocation('-genkeypair')
          .stdin!
          .split('\n')
          .first;
      expect(logger.output, isNot(contains(password)));
    });

    test('key.properties points where Gradle resolves from', () async {
      // `storeFile` is resolved relative to android/app. A path relative to
      // the repository root fails by resolving to a file that is not there,
      // and an absolute one works on exactly one machine.
      await run(<String>['setup', 'android-signing']);

      final properties = project.read('android/key.properties');
      expect(properties, contains('storeFile=../upload-keystore.jks'));
      expect(properties, contains('keyAlias=upload'));
    });

    test('shipway.yaml gains the names and no value', () async {
      await run(<String>['setup', 'android-signing']);

      final patched = project.read('shipway.yaml');
      final android = ConfigLoader.parse(
        patched,
      ).apps['main']!.signing.android!;

      expect(android.keystoreRef, 'ANDROID_KEYSTORE_BASE64');
      expect(android.keyProperties!.keyAlias, 'upload');
      // The edit is surgical: the file is still the one somebody wrote.
      expect(patched, contains('# QA lives here.'));

      final password = runner
          .invocation('-genkeypair')
          .stdin!
          .split('\n')
          .first;
      expect(patched, isNot(contains(password)));
    });

    test('the passwords and the keystore go to the keychain', () async {
      await run(<String>['setup', 'android-signing']);

      final stored = <String>[
        for (final invocation in runner.invocations)
          if (invocation.commandLine.contains('add-generic-password'))
            invocation.arguments[invocation.arguments.indexOf('-a') + 1],
      ];
      expect(
        stored,
        containsAll(<String>[
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_PASSWORD',
          'ANDROID_KEYSTORE_BASE64',
        ]),
      );
    });

    test('an existing keystore is never overwritten', () async {
      // Losing an upload key means an app already on Play cannot be updated.
      project.write('android/upload-keystore.jks', 'the real one');

      final code = await run(<String>['setup', 'android-signing']);

      expect(code, ShipwayExit.userError);
      expect(project.read('android/upload-keystore.jks'), 'the real one');
      expect(runner.ran('-genkeypair'), isFalse);
      expect(logger.output, contains('cannot be updated without it'));
    });

    test('names a team already uses rather than renaming them', () async {
      project.write('shipway.yaml', '''
$_config    signing:
      android:
        keystore_ref: OUR_KEYSTORE
        key_properties:
          store_password_ref: OUR_STORE_PASSWORD
          key_password_ref: OUR_KEY_PASSWORD
''');

      await run(<String>['setup', 'android-signing']);

      final android = ConfigLoader.parse(
        project.read('shipway.yaml'),
      ).apps['main']!.signing.android!;
      expect(android.keystoreRef, 'OUR_KEYSTORE');
      expect(android.keyProperties!.storePasswordRef, 'OUR_STORE_PASSWORD');
    });

    test('says so when Gradle would still use the debug key', () async {
      // Writing key.properties signs nothing on its own. A release built with
      // the debug key installs and uploads, and Play rejects it.
      await run(<String>['setup', 'android-signing']);

      expect(logger.output, contains('does not read key.properties'));
    });

    test('stays quiet when Gradle already reads it', () async {
      project.write(
        'android/app/build.gradle.kts',
        'val p = file("key.properties")\n',
      );

      await run(<String>['setup', 'android-signing']);

      expect(logger.output, isNot(contains('does not read key.properties')));
    });

    test('off macOS it refuses before creating anything', () async {
      final code = await run(<String>[
        'setup',
        'android-signing',
      ], host: HostPlatform.linux);

      expect(code, ShipwayExit.environmentError);
      expect(runner.invocations, isEmpty);
      expect(project.exists('android/upload-keystore.jks'), isFalse);
    });
  });

  test('an unknown action names the ones that exist', () async {
    final code = await run(<String>['setup', 'nonsense']);

    expect(code, ShipwayExit.userError);
    expect(logger.output, contains('android-signing'));
  });

  test('no action at all says what to pick', () async {
    final code = await run(<String>['setup']);

    expect(code, ShipwayExit.userError);
    expect(logger.output, contains('android-signing'));
  });
}
