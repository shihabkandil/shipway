import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/secrets/secret_materialiser.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

const AndroidSigningConfig _signing = AndroidSigningConfig(
  keystoreRef: 'ANDROID_KEYSTORE_BASE64',
  keyProperties: KeyPropertiesConfig(
    storePasswordRef: 'STORE_PW',
    keyPasswordRef: 'KEY_PW',
    keyAlias: 'release',
  ),
);

void main() {
  late FixtureProject project;
  late Directory base;
  late Map<String, String> secrets;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    base = await Directory.systemTemp.createTemp('shipway_base');
    addTearDown(() async {
      if (base.existsSync()) await base.delete(recursive: true);
    });
    secrets = <String, String>{
      'PLAY_SERVICE_ACCOUNT_JSON': '{"client_email":"ci@acme.iam"}',
      'ANDROID_KEYSTORE_BASE64': base64.encode(<int>[1, 2, 3, 4]),
      'STORE_PW': 'store-secret',
      'KEY_PW': 'key-secret',
    };
  });

  SecretMaterialiser materialiser() => SecretMaterialiser(
    projectRoot: project.path,
    read: (name) async => secrets[name],
    baseDirectory: base.path,
  );

  List<String> leftInBase() => <String>[
    for (final entity in base.listSync()) p.basename(entity.path),
  ];

  group('a path variable', () {
    test('is written from the secret holding its content', () async {
      final subject = materialiser();
      final environment = await subject.pathVariables(<String>[
        'PLAY_SERVICE_ACCOUNT_JSON_PATH',
      ]);

      final path = environment['PLAY_SERVICE_ACCOUNT_JSON_PATH']!;
      expect(p.isAbsolute(path), isTrue);
      expect(
        File(path).readAsStringSync().trim(),
        secrets['PLAY_SERVICE_ACCOUNT_JSON'],
      );
    });

    test('goes outside the checkout', () async {
      // Inside it, a file is one `git add -A` or one uploaded artifact away
      // from leaving the machine.
      final environment = await materialiser().pathVariables(<String>[
        'PLAY_SERVICE_ACCOUNT_JSON_PATH',
      ]);
      expect(p.isWithin(project.path, environment.values.single), isFalse);
      expect(p.isWithin(base.path, environment.values.single), isTrue);
    });

    test('follows the naming a flavor\'s own account uses', () async {
      secrets['FIREBASE_DEV_SERVICE_ACCOUNT_JSON'] = '{}';
      final environment = await materialiser().pathVariables(<String>[
        'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH',
      ]);
      expect(environment.keys, <String>[
        'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH',
      ]);
    });

    test('that already names a real file is left alone', () async {
      // A self-hosted machine may keep its service account on disk. That is
      // its owner's decision, and the file is not shipway's to shadow.
      project.write('keys/play.json', '{}');
      secrets['PLAY_SERVICE_ACCOUNT_JSON_PATH'] = 'keys/play.json';

      final subject = materialiser();
      expect(
        await subject.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']),
        isEmpty,
      );
      expect(subject.isEmpty, isTrue);
      expect(leftInBase(), isEmpty);
    });

    test('naming a file that is gone is rewritten from the content', () async {
      secrets['PLAY_SERVICE_ACCOUNT_JSON_PATH'] = '/nowhere/play.json';
      final environment = await materialiser().pathVariables(<String>[
        'PLAY_SERVICE_ACCOUNT_JSON_PATH',
      ]);
      expect(File(environment.values.single).existsSync(), isTrue);
    });

    test('with no content secret writes nothing', () async {
      // The pre-flight has already named it as missing; a zero-byte file
      // would turn that into a JSON parse error inside the lane.
      secrets.remove('PLAY_SERVICE_ACCOUNT_JSON');
      final subject = materialiser();
      expect(
        await subject.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']),
        isEmpty,
      );
      expect(leftInBase(), isEmpty);
    });
  });

  group('Android signing', () {
    test('rebuilds the keystore and key.properties', () async {
      final subject = materialiser();
      expect(await subject.androidSigning(_signing), isTrue);

      final properties = project.read('android/key.properties');
      expect(properties, startsWith(SecretMaterialiser.keyPropertiesMarker));
      expect(properties, contains('storePassword=store-secret'));
      expect(properties, contains('keyPassword=key-secret'));
      expect(properties, contains('keyAlias=release'));

      // Absolute: Gradle resolves storeFile from android/app, and a relative
      // one silently names a file that is not there.
      final storeFile = RegExp(
        r'^storeFile=(.+)$',
        multiLine: true,
      ).firstMatch(properties)!.group(1)!;
      expect(p.isAbsolute(storeFile), isTrue);
      expect(File(storeFile).readAsBytesSync(), <int>[1, 2, 3, 4]);
    });

    test('tolerates a keystore secret wrapped across lines', () async {
      // `base64` wraps at 76 columns on Linux, and that is what gets pasted.
      secrets['ANDROID_KEYSTORE_BASE64'] = 'AQID\nBA==\n';
      expect(await materialiser().androidSigning(_signing), isTrue);
    });

    test('falls back to the conventional password names', () async {
      secrets
        ..['ANDROID_STORE_PASSWORD'] = 'a'
        ..['ANDROID_KEY_PASSWORD'] = 'b';
      await materialiser().androidSigning(
        const AndroidSigningConfig(keystoreRef: 'ANDROID_KEYSTORE_BASE64'),
      );
      final properties = project.read('android/key.properties');
      expect(properties, contains('storePassword=a'));
      expect(properties, contains('keyPassword=b'));
      expect(properties, contains('keyAlias=upload'));
    });

    test('never replaces a key.properties that is not its own', () async {
      // The machine signs with that one. Replacing it is replacing somebody's
      // working build, and removing it afterwards would be worse.
      project.write('android/key.properties', 'storeFile=/keys/mine.jks\n');
      final subject = materialiser();

      expect(await subject.androidSigning(_signing), isFalse);
      subject.cleanUp();

      expect(
        project.read('android/key.properties'),
        'storeFile=/keys/mine.jks\n',
      );
    });

    test('replaces its own leftover from a run that was killed', () async {
      // The marker says it is shipway's; the keystore it names is gone, so
      // nothing is using it.
      project.write(
        'android/key.properties',
        '${SecretMaterialiser.keyPropertiesMarker}\n'
            'storeFile=/gone/upload-keystore.jks\n',
      );
      expect(await materialiser().androidSigning(_signing), isTrue);
      expect(
        project.read('android/key.properties'),
        contains('storePassword=store-secret'),
      );
    });

    test('leaves alone one a release in progress is still using', () async {
      final first = materialiser();
      await first.androidSigning(_signing);
      final before = project.read('android/key.properties');

      final second = materialiser();
      expect(await second.androidSigning(_signing), isFalse);
      second.cleanUp();

      // The second run's cleanup must not take the first run's file.
      expect(project.read('android/key.properties'), before);
      first.cleanUp();
      expect(project.exists('android/key.properties'), isFalse);
    });

    test('says so when the keystore secret is not base64', () async {
      secrets['ANDROID_KEYSTORE_BASE64'] = 'not base64 at all!';
      final subject = materialiser();
      await expectLater(
        subject.androidSigning(_signing),
        throwsA(
          isA<MaterialisationFailure>().having(
            (f) => f.what,
            'what',
            contains('ANDROID_KEYSTORE_BASE64'),
          ),
        ),
      );
      expect(project.exists('android/key.properties'), isFalse);
    });

    test('names the password that is missing, and writes nothing', () async {
      secrets.remove('KEY_PW');
      await expectLater(
        materialiser().androidSigning(_signing),
        throwsA(
          isA<MaterialisationFailure>().having(
            (f) => f.what,
            'what',
            allOf(contains('KEY_PW'), isNot(contains('STORE_PW'))),
          ),
        ),
      );
      expect(project.exists('android/key.properties'), isFalse);
    });

    test('does nothing when no keystore is configured or set', () async {
      expect(await materialiser().androidSigning(null), isFalse);
      secrets.remove('ANDROID_KEYSTORE_BASE64');
      expect(await materialiser().androidSigning(_signing), isFalse);
      expect(project.exists('android/key.properties'), isFalse);
    });
  });

  group('cleaning up', () {
    test('removes everything it wrote', () async {
      final subject = materialiser();
      final environment = await subject.pathVariables(<String>[
        'PLAY_SERVICE_ACCOUNT_JSON_PATH',
      ]);
      await subject.androidSigning(_signing);
      expect(subject.written, hasLength(3));

      subject.cleanUp();

      expect(File(environment.values.single).existsSync(), isFalse);
      expect(project.exists('android/key.properties'), isFalse);
      expect(leftInBase(), isEmpty);
      expect(subject.isEmpty, isTrue);
    });

    test('twice is as good as once', () async {
      final subject = materialiser();
      await subject.androidSigning(_signing);
      subject
        ..cleanUp()
        ..cleanUp();
      expect(leftInBase(), isEmpty);
    });

    test('does not throw when the files are already gone', () async {
      // It runs in a `finally`; an exception there would replace the failure
      // somebody actually needs to read.
      final subject = materialiser();
      await subject.androidSigning(_signing);
      base.deleteSync(recursive: true);
      File(p.join(project.path, 'android', 'key.properties')).deleteSync();

      expect(subject.cleanUp, returnsNormally);
    });

    test('removes the files when writing failed halfway', () async {
      // The service account is on disk before the keystore turns out to be
      // unreadable. The caller's `finally` has to be enough.
      secrets['ANDROID_KEYSTORE_BASE64'] = '!!!';
      final subject = materialiser();
      try {
        await subject.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']);
        await subject.androidSigning(_signing);
        fail('expected a failure');
      } on MaterialisationFailure {
        // Expected.
      } finally {
        subject.cleanUp();
      }
      expect(leftInBase(), isEmpty);
    });
  });

  group('sweeping after a run that was killed', () {
    test('removes that project\'s run directories and marked '
        'key.properties', () async {
      final killed = materialiser();
      await killed.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']);
      await killed.androidSigning(_signing);
      // No cleanUp: the process is gone.

      final removed = SecretMaterialiser.sweep(
        projectRoot: project.path,
        baseDirectory: base.path,
      );

      expect(removed, hasLength(2));
      expect(leftInBase(), isEmpty);
      expect(project.exists('android/key.properties'), isFalse);
    });

    test('leaves another checkout\'s files alone', () async {
      // Two runners on one machine share a temporary directory. Cleaning up
      // after one job must not pull the keystore out from under the other.
      final other = await FixtureProject.create();
      addTearDown(other.dispose);
      final theirs = SecretMaterialiser(
        projectRoot: other.path,
        read: (name) async => secrets[name],
        baseDirectory: base.path,
      );
      await theirs.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']);

      expect(
        SecretMaterialiser.sweep(
          projectRoot: project.path,
          baseDirectory: base.path,
        ),
        isEmpty,
      );
      expect(leftInBase(), hasLength(1));
    });

    test('leaves a key.properties it did not write', () {
      project.write('android/key.properties', 'storeFile=/keys/mine.jks\n');
      expect(
        SecretMaterialiser.sweep(
          projectRoot: project.path,
          baseDirectory: base.path,
        ),
        isEmpty,
      );
      expect(project.exists('android/key.properties'), isTrue);
    });

    test('finds nothing on a clean machine', () {
      expect(
        SecretMaterialiser.sweep(
          projectRoot: project.path,
          baseDirectory: p.join(base.path, 'does-not-exist'),
        ),
        isEmpty,
      );
    });
  });

  group('where the files go', () {
    test('the runner\'s own temporary directory, when it gives one', () {
      // GitHub empties it around every job, on self-hosted machines too: a
      // second thing that removes the files.
      expect(
        SecretMaterialiser.baseDirectoryFor(<String, String>{
          'RUNNER_TEMP': base.path,
        }),
        base.path,
      );
    });

    test('the system\'s otherwise', () {
      for (final environment in <Map<String, String>>[
        const <String, String>{},
        const <String, String>{'RUNNER_TEMP': ''},
        const <String, String>{'RUNNER_TEMP': '/does/not/exist'},
      ]) {
        expect(
          SecretMaterialiser.baseDirectoryFor(environment),
          Directory.systemTemp.path,
        );
      }
    });
  });
}
