import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/gradle/android_build_facts.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:shipway/src/doctor/check.dart';
import 'package:shipway/src/doctor/checks/android_sdk_checks.dart';
import 'package:shipway/src/doctor/checks/toolchain_checks.dart';
import 'package:shipway/src/doctor/doctor.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

/// A project and an SDK, both on disk, sharing one temp directory.
class _Fixture {
  _Fixture(this.root);

  final Directory root;

  String get project => p.join(root.path, 'project');
  String get sdk => p.join(root.path, 'sdk');

  static Future<_Fixture> create({
    String? compileSdk = 'compileSdk = 37',
    String? agp = '8.11.1',
    List<String> platforms = const <String>['android-36', 'android-37.0'],
    bool kotlin = true,
  }) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('shipway_compile_sdk'),
    );
    addTearDown(() => fixture.root.delete(recursive: true));

    fixture
      ..write('project/pubspec.yaml', 'name: demo\n')
      ..write(
        'project/android/app/build.gradle${kotlin ? '.kts' : ''}',
        'android {\n'
            '    namespace = "com.acme.app"\n'
            '    // compileSdk = 34 was the old value\n'
            '    ${compileSdk ?? ''}\n'
            '    defaultConfig {\n        targetSdk = 36\n    }\n'
            '}\n',
      );
    if (agp != null) {
      fixture.write(
        'project/android/settings.gradle${kotlin ? '.kts' : ''}',
        kotlin
            ? 'plugins {\n'
                  '    id("dev.flutter.flutter-plugin-loader") version "1.0.0"\n'
                  '    id("com.android.application") version "$agp" apply false\n'
                  '}\n'
            : 'plugins {\n'
                  '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"\n'
                  "    id 'com.android.application' version '$agp' apply false\n"
                  '}\n',
      );
    }
    for (final platform in platforms) {
      Directory(
        p.join(fixture.sdk, 'platforms', platform),
      ).createSync(recursive: true);
    }
    return fixture;
  }

  void write(String relative, String contents) {
    File(p.join(root.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  DoctorContext context({
    RecordingProcessRunner? runner,
    Map<String, String>? environment,
    HostPlatform host = HostPlatform.macos,
  }) => DoctorContext(
    runner: runner ?? RecordingProcessRunner(),
    projectRoot: project,
    config: null,
    now: DateTime.utc(2026, 10, 1),
    host: host,
    environment: environment ?? <String, String>{'ANDROID_HOME': sdk},
  );
}

void main() {
  group('compileSdk against the Android Gradle Plugin', () {
    test('the field report: 37 with AGP 8.11.1 fails, naming both', () async {
      final fixture = await _Fixture.create();
      final result = await CompileSdkCheck().run(fixture.context());

      expect(result.status, CheckStatus.fail);
      expect(
        result.detail,
        'compileSdk 37 needs AGP 9 or newer; this project has 8.11.1.',
      );
      expect(result.fixHint, contains("hash string 'android-37'"));
      expect(result.fixHint, contains('android/settings.gradle.kts'));
      expect(result.fixHint, contains('9.1.1'));
    });

    test(
      'it fails without an SDK to look in, since the files say enough',
      () async {
        final fixture = await _Fixture.create();
        final result = await CompileSdkCheck().run(
          fixture.context(environment: const <String, String>{}),
        );
        expect(result.status, CheckStatus.fail);
      },
    );

    test(
      '37 with the AGP that fixed it passes, naming what it found',
      () async {
        final fixture = await _Fixture.create(agp: '9.1.1');
        final result = await CompileSdkCheck().run(fixture.context());

        expect(result.status, CheckStatus.ok);
        expect(result.detail, contains('compileSdk 37'));
        expect(result.detail, contains('AGP 9.1.1'));
        expect(result.detail, contains('android-37.0 installed'));
      },
    );

    test(
      'below the documented minimum, but not known to fail, warns',
      () async {
        final fixture = await _Fixture.create(agp: '9.0.0');
        final result = await CompileSdkCheck().run(fixture.context());
        expect(result.status, CheckStatus.warn);
        expect(result.detail, contains('9.1.1'));
        expect(result.detail, contains('9.0.0'));

        final older = await _Fixture.create(
          compileSdk: 'compileSdk = 36',
          agp: '8.7.0',
        );
        expect(
          (await CompileSdkCheck().run(older.context())).status,
          CheckStatus.warn,
        );
      },
    );

    test('a combination nothing is known about passes', () async {
      final fixture = await _Fixture.create(
        compileSdk: 'compileSdk = 38',
        agp: '8.0.0',
        platforms: const <String>['android-38'],
      );
      final result = await CompileSdkCheck().run(fixture.context());
      expect(result.status, CheckStatus.ok);
    });

    test(
      'a platform that is not installed names the sdkmanager command',
      () async {
        final fixture = await _Fixture.create(
          compileSdk: 'compileSdk = 35',
          agp: '8.11.1',
        );
        final result = await CompileSdkCheck().run(fixture.context());

        expect(result.status, CheckStatus.warn);
        expect(result.detail, contains('compileSdk 35'));
        expect(result.detail, contains(fixture.sdk));
        expect(result.fixHint, contains('sdkmanager "platforms;android-35"'));

        final api37 = await _Fixture.create(
          agp: '9.1.1',
          platforms: const <String>['android-36'],
        );
        expect(
          (await CompileSdkCheck().run(api37.context())).fixHint,
          contains('sdkmanager "platforms;android-37.0"'),
        );
      },
    );

    test(
      'flutter.compileSdkVersion is skipped with the reason, not guessed',
      () async {
        final fixture = await _Fixture.create(
          compileSdk: 'compileSdk = flutter.compileSdkVersion',
        );
        final result = await CompileSdkCheck().run(fixture.context());
        expect(result.status, CheckStatus.skip);
        expect(result.detail, contains('flutter.compileSdkVersion'));
        expect(result.detail, contains('android/app/build.gradle.kts'));
      },
    );

    test('no compileSdk at all is skipped', () async {
      final fixture = await _Fixture.create(compileSdk: null);
      expect(
        (await CompileSdkCheck().run(fixture.context())).status,
        CheckStatus.skip,
      );
    });

    test(
      'an AGP version held in a variable is said, and not compared',
      () async {
        final fixture = await _Fixture.create(agp: r'$agpVersion');
        final result = await CompileSdkCheck().run(fixture.context());
        expect(result.status, CheckStatus.ok);
        expect(result.detail, contains('not readable statically'));
      },
    );

    test('reads Groovy, and the older buildscript classpath', () async {
      final fixture = await _Fixture.create(
        compileSdk: 'compileSdkVersion 37',
        agp: null,
        kotlin: false,
      );
      fixture.write(
        'project/android/build.gradle',
        'buildscript {\n    dependencies {\n'
            "        classpath 'com.android.tools.build:gradle:8.5.2'\n"
            '    }\n}\n',
      );
      final result = await CompileSdkCheck().run(fixture.context());
      expect(result.status, CheckStatus.fail);
      expect(result.detail, contains('this project has 8.5.2'));
      expect(result.fixHint, contains('android/build.gradle'));
    });

    test('is one of the default checks', () {
      final ids = Doctor.defaultChecks().map((check) => check.id);
      expect(ids, containsAll(<String>['compile_sdk', 'toolchain_drift']));
    });
  });

  group('reading the build files', () {
    CompileSdk? parse(String source) =>
        AndroidBuildFacts.parseCompileSdk(source, file: 'f');

    test('every spelling of a literal compileSdk', () {
      expect(parse('compileSdk = 37')!.level, 37);
      expect(parse('compileSdk 36')!.level, 36);
      expect(parse('compileSdkVersion 35')!.level, 35);
      expect(parse('compileSdkVersion(34)')!.level, 34);
      expect(parse('compileSdkVersion "android-33"')!.level, 33);
      expect(parse('compileSdk {\n  version = release(36)\n}')!.level, 36);
    });

    test('does not mistake a neighbour or a comment for it', () {
      expect(parse('compileSdkExtension = 12'), isNull);
      expect(parse('compileSdkPreview = "Baklava"'), isNull);
      expect(parse('// compileSdk = 30\n/* compileSdk = 31 */'), isNull);
      expect(parse('minSdk = 24\ntargetSdk = 36'), isNull);
    });

    test('anything not a number is an expression', () {
      expect(
        parse('compileSdk = flutter.compileSdkVersion')!.expression,
        'flutter.compileSdkVersion',
      );
      expect(parse('compileSdk rootProject.ext.compileSdk')!.level, isNull);
    });

    test('the AGP version from each place it lives', () {
      AgpDeclaration? agp(String source) =>
          AndroidBuildFacts.parseAgp(source, file: 'f');

      expect(
        agp(
          'id("com.android.application") version "9.1.1" apply false',
        )!.version,
        '9.1.1',
      );
      expect(
        agp(
          'id "com.android.application" version "8.11.1" apply false',
        )!.version,
        '8.11.1',
      );
      expect(
        agp('classpath("com.android.tools.build:gradle:8.1.0")')!.version,
        '8.1.0',
      );
      expect(agp('// id("com.android.application") version "7.0.0"\n'), isNull);
      expect(agp('id("com.android.application")'), isNull);
      final variable = agp(
        r'classpath "com.android.tools.build:gradle:$agp_version"',
      )!;
      expect(variable.version, isNull);
      expect(variable.expression, r'$agp_version');
    });

    test('a URL in a build file is not a comment', () {
      expect(
        AndroidBuildFacts.stripComments('url = "https://maven.acme.io" // x'),
        'url = "https://maven.acme.io" ',
      );
    });
  });

  group('finding the SDK', () {
    test('local.properties wins, as it does for Gradle', () async {
      final fixture = await _Fixture.create();
      final other = Directory(p.join(fixture.root.path, 'other-sdk'))
        ..createSync();
      fixture.write(
        'project/android/local.properties',
        'flutter.sdk=/opt/flutter\nsdk.dir=${other.path}\n',
      );
      expect(
        AndroidSdk.locate(
          fixture.project,
          environment: <String, String>{'ANDROID_HOME': fixture.sdk},
        ),
        other.path,
      );
    });

    test(
      'then ANDROID_HOME, ANDROID_SDK_ROOT and the default location',
      () async {
        final fixture = await _Fixture.create();
        String? locate(Map<String, String> environment) =>
            AndroidSdk.locate(fixture.project, environment: environment);

        expect(
          locate(<String, String>{
            'ANDROID_HOME': fixture.sdk,
            'ANDROID_SDK_ROOT': '/nowhere',
          }),
          fixture.sdk,
        );
        expect(
          locate(<String, String>{'ANDROID_SDK_ROOT': fixture.sdk}),
          fixture.sdk,
        );

        final home = Directory(p.join(fixture.root.path, 'home'));
        final defaultSdk = Directory(
          p.join(home.path, 'Library', 'Android', 'sdk'),
        )..createSync(recursive: true);
        expect(locate(<String, String>{'HOME': home.path}), defaultSdk.path);
        expect(locate(const <String, String>{}), isNull);
      },
    );

    test('reads platform directories, with and without a minor version', () {
      expect(AndroidSdk.parsePlatform('android-36')!.minor, isNull);
      final minor = AndroidSdk.parsePlatform('android-37.0')!;
      expect(minor.level, 37);
      expect(minor.minor, 0);
      expect(AndroidSdk.parsePlatform('android-Baklava'), isNull);
    });
  });

  group('toolchain drift', () {
    Future<_Fixture> withRecord({String? flutter, String? xcode}) async {
      final fixture = await _Fixture.create();
      final lock = LockFile.empty()
        ..recordToolchain(flutter: flutter, xcode: xcode);
      await lock.save(fixture.project);
      return fixture;
    }

    RecordingProcessRunner machine({
      String flutter = '3.47.2',
      String xcode = '26.6',
    }) => RecordingProcessRunner()
      ..stub(
        'flutter --version --machine',
        stdout: jsonEncode(<String, String>{
          'frameworkVersion': flutter,
          'channel': 'stable',
        }),
      )
      ..stub('xcodebuild -version', stdout: 'Xcode $xcode\nBuild version 1');

    test('nothing recorded yet is skipped, and asks nothing', () async {
      final fixture = await _Fixture.create();
      final runner = machine();
      final result = await ToolchainDriftCheck().run(
        fixture.context(runner: runner),
      );
      expect(result.status, CheckStatus.skip);
      expect(runner.invocations, isEmpty);
    });

    test('the same versions pass', () async {
      final fixture = await withRecord(flutter: '3.47.2', xcode: '26.6');
      final result = await ToolchainDriftCheck().run(
        fixture.context(runner: machine()),
      );
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('Flutter 3.47.2'));
      expect(result.detail, contains('Xcode 26.6'));
    });

    test('a different Flutter warns, naming both versions', () async {
      final fixture = await withRecord(flutter: '3.47.2', xcode: '26.6');
      final result = await ToolchainDriftCheck().run(
        fixture.context(runner: machine(flutter: '3.41.0')),
      );
      expect(result.status, CheckStatus.warn);
      expect(result.detail, 'Flutter 3.41.0 here, 3.47.2 at the last release.');
      expect(result.status.blocks, isFalse);
    });

    test('a different Xcode warns too, and both are listed together', () async {
      final fixture = await withRecord(flutter: '3.47.2', xcode: '26.6');
      final result = await ToolchainDriftCheck().run(
        fixture.context(
          runner: machine(flutter: '3.50.0', xcode: '16.4'),
        ),
      );
      expect(result.status, CheckStatus.warn);
      expect(result.detail, contains('Flutter 3.50.0 here, 3.47.2'));
      expect(result.detail, contains('Xcode 16.4 here, 26.6'));
    });

    test('Xcode is not asked for where it cannot exist', () async {
      final fixture = await withRecord(flutter: '3.47.2', xcode: '26.6');
      final runner = machine();
      final result = await ToolchainDriftCheck().run(
        fixture.context(runner: runner, host: HostPlatform.linux),
      );
      expect(result.status, CheckStatus.ok);
      expect(runner.ran('xcodebuild'), isFalse);
    });

    test('understands the banner when --machine is not honoured', () async {
      final fixture = await withRecord(flutter: '3.47.2');
      final runner = RecordingProcessRunner()
        ..stub(
          'flutter --version',
          stdout: 'Flutter 3.47.2 • channel stable • https://github.com/x',
        );
      final result = await ToolchainDriftCheck().run(
        fixture.context(runner: runner),
      );
      expect(result.status, CheckStatus.ok);
    });

    test('a lock file that is not JSON is a warning, not a crash', () async {
      final fixture = await _Fixture.create()
        ..write('project/.shipway/lock.json', 'not json');
      final result = await ToolchainDriftCheck().run(fixture.context());
      expect(result.status, CheckStatus.warn);
      expect(result.detail, contains('lock.json'));
    });
  });
}
