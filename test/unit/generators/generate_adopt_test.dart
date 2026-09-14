import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

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

  void clear() => lines.clear();
}

/// A scheme with the parts a generated one must preserve: the blueprint
/// identifier and Flutter's prepare step.
const String _runnerScheme = '''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1510" version = "1.3">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <PreActions>
         <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
            <ActionContent title = "Run Prepare Flutter Framework Script" scriptText = "/bin/sh &quot;\$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh&quot; prepare">
            </ActionContent>
         </ExecutionAction>
      </PreActions>
      <BuildActionEntries>
         <BuildActionEntry buildForRunning = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "97C146ED1CF9000F007C117D" BuildableName = "Runner.app" BlueprintName = "Runner" ReferencedContainer = "container:Runner.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug"></TestAction>
   <LaunchAction buildConfiguration = "Debug"></LaunchAction>
   <ProfileAction buildConfiguration = "Profile"></ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release"></ArchiveAction>
</Scheme>
''';

void main() {
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late FixtureProject project;

  /// A project already configured exactly the way shipway would configure it.
  /// This is the round-trip case: import, adopt, generate, expect no change.
  Future<void> makeAgreeingProject({bool kotlin = true}) async {
    final flavors = kotlin
        ? '''
    flavorDimensions += "environment"

    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Acme Dev")
        }

        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
        }
    }'''
        : '''
    flavorDimensions "environment"

    productFlavors {
        dev {
            dimension "environment"
            applicationIdSuffix ".dev"
            resValue "string", "app_name", "Acme Dev"
        }

        prod {
            dimension "environment"
            resValue "string", "app_name", "Acme"
        }
    }''';

    project
      ..withPubspec(name: 'acme_app')
      ..withGradle('''
android {
    defaultConfig {
        applicationId ${kotlin ? '= ' : ''}"com.acme.app"
    }
$flavors
}
''', kotlin: kotlin)
      ..withEntrypoint('dev')
      ..withEntrypoint('prod')
      ..withIosProject()
      ..write(
        'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
        _runnerScheme,
      )
      ..withSharedScheme('dev', launch: 'Debug-dev', archive: 'Release-dev')
      ..withSharedScheme('prod', launch: 'Debug-prod', archive: 'Release-prod');

    stubConfigure(runner, flavors: const <String>['dev', 'prod']);
    stubPlutil(runner);
    stubBridge(
      runner,
      stubBridgeJson(
        configurations: <String, String>{
          'Debug': 'com.acme.app',
          'Release': 'com.acme.app',
          'Profile': 'com.acme.app',
          'Debug-dev': 'com.acme.app.dev',
          'Release-dev': 'com.acme.app.dev',
          'Profile-dev': 'com.acme.app.dev',
          'Debug-prod': 'com.acme.app',
          'Release-prod': 'com.acme.app',
          'Profile-prod': 'com.acme.app',
        },
      ),
    );
  }

  setUp(() async {
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  Future<int> run(List<String> args) => ShipwayCommandRunner(
    logger: logger,
    runner: runner,
    workingDirectory: project.path,
  ).run(<String>['--no-color', '--yes', ...args]);

  group('generate refuses to touch what shipway does not own', () {
    setUp(makeAgreeingProject);

    test('blocks on the unadopted Gradle file and names adopt', () async {
      await run(<String>['import']);
      logger.clear();

      final exit = await run(<String>['generate', 'android-flavors']);

      expect(exit, ShipwayExit.userError);
      expect(logger.output, contains('conflict'));
      expect(logger.output, contains('was here before shipway'));
      expect(logger.output, contains('shipway adopt'));
    });

    test('leaves the file byte-identical when blocked', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');

      await run(<String>['generate']);

      expect(project.read('android/app/build.gradle.kts'), before);
    });

    test('--force does not override an unadopted file', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');
      logger.clear();

      final exit = await run(<String>['generate', '--force']);

      // Adoption is a decision, not a flag typed in a hurry.
      expect(exit, ShipwayExit.userError);
      expect(project.read('android/app/build.gradle.kts'), before);
      expect(logger.output, contains('shipway adopt'));
    });

    test('--dry-run writes nothing even for files it could create', () async {
      await run(<String>['import']);
      final before = project.allFiles();
      logger.clear();

      await run(<String>['generate', '--dry-run']);

      expect(project.allFiles(), before);
      expect(logger.output, contains('Nothing was written.'));
    });
  });

  group('adopt', () {
    setUp(makeAgreeingProject);

    test('reports that the config already describes the project', () async {
      await run(<String>['import']);
      logger.clear();

      await run(<String>['adopt', 'all']);

      expect(logger.output, contains('already describes this project exactly'));
    });

    test('changes ownership without changing file content', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');

      await run(<String>['adopt', 'all']);

      expect(
        project.read('android/app/build.gradle.kts'),
        before,
        reason: 'adopt records ownership; generate is what writes',
      );
      expect(project.read('.shipway/lock.json'), contains('"adopted"'));
    });

    test('unblocks generate', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      expect(await run(<String>['generate']), ShipwayExit.success);
    });

    test('rejects a path shipway does not manage', () async {
      await run(<String>['import']);
      logger.clear();

      final exit = await run(<String>['adopt', 'lib/some_widget.dart']);

      expect(exit, ShipwayExit.userError);
      expect(logger.output, contains('does not generate'));
    });

    test('needs a target', () async {
      await run(<String>['import']);
      logger.clear();
      expect(await run(<String>['adopt']), ShipwayExit.userError);
      expect(logger.output, contains('a path, or `all`'));
    });
  });

  for (final kotlin in <bool>[true, false]) {
    final dialect = kotlin ? 'Kotlin' : 'Groovy';

    group('round trip on a $dialect project', () {
      setUp(() => makeAgreeingProject(kotlin: kotlin));

      /// The single most valuable test in the project: a project already
      /// configured the way shipway would configure it must survive
      /// import -> adopt -> generate untouched, apart from shipway's markers.
      test('import, adopt, generate changes no build configuration', () async {
        final gradlePath =
            'android/app/${kotlin ? 'build.gradle.kts' : 'build.gradle'}';

        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final after = project.read(gradlePath);

        // The flavors are unchanged in substance: same names, same suffixes,
        // same display names, still inside `android { }`.
        expect(after, contains('applicationIdSuffix'));
        expect(after, contains('.dev'));
        expect(after, contains('Acme Dev'));
        expect(after, contains('dev'));
        expect(after, contains('prod'));
        expect(after, contains('BEGIN shipway (managed)'));
        expect(after, contains('END shipway'));
        // And nothing outside the block was disturbed.
        expect(after, contains('applicationId'));
        expect(after, contains('com.acme.app'));
      });

      test('re-running generate is a no-op', () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final snapshot = <String, String>{
          for (final path in project.allFiles()) path: project.read(path),
        };
        logger.clear();

        final exit = await run(<String>['generate']);

        expect(exit, ShipwayExit.success);
        for (final entry in snapshot.entries) {
          expect(
            project.read(entry.key),
            entry.value,
            reason: '${entry.key} changed on a second generate',
          );
        }
        expect(logger.output, contains('0 written'));
      });

      test('status reports no drift after generate', () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);
        logger.clear();

        await run(<String>['status']);

        expect(logger.output, contains('In sync.'));
      });
    });
  }

  group('generated content', () {
    setUp(makeAgreeingProject);

    test(
      'schemes are written shared and keep the blueprint and prepare step',
      () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final scheme = project.read(
          'ios/Runner.xcodeproj/xcshareddata/xcschemes/dev.xcscheme',
        );
        // A scheme without these is syntactically fine and does not build.
        expect(scheme, contains('97C146ED1CF9000F007C117D'));
        expect(scheme, contains('xcode_backend.sh'));
        expect(scheme, contains('buildConfiguration="Debug-dev"'));
        expect(scheme, contains('buildConfiguration="Release-dev"'));
        expect(scheme, contains('buildConfiguration="Profile-dev"'));
        // Never xcuserdata.
        expect(project.exists('ios/Runner.xcodeproj/xcuserdata'), isFalse);
      },
    );

    test('no per-flavor xcconfig is written', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      // A flavored build configuration must keep the base configuration of the
      // build type it derives from. Attaching one of shipway's own here
      // displaces ios/Flutter/Release.xcconfig, and with it the
      // Generated.xcconfig that carries FLUTTER_TARGET, the dart-defines and
      // the version numbers — so the build silently compiles lib/main.dart and
      // ships an Info.plist with no CFBundleVersion.
      expect(project.exists('ios/Flutter/dev.xcconfig'), isFalse);
      expect(project.exists('ios/Flutter/prod.xcconfig'), isFalse);
    });

    test('the gitignore block covers every secret-bearing path', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      final gitignore = project.read('.gitignore');
      for (final pattern in const <String>[
        '.env',
        '*.p8',
        '*.jks',
        '*.keystore',
        '**/key.properties',
        '**/service-account*.json',
      ]) {
        expect(gitignore, contains(pattern));
      }
      // Ownership is a team-wide fact and must stay committed.
      expect(gitignore, isNot(contains('.shipway/lock.json')));
      // An example file must stay trackable.
      expect(gitignore, contains('!.env*.example'));
    });
  });

  group('iOS display name', () {
    setUp(makeAgreeingProject);

    test('points Info.plist at the build setting', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      await run(<String>['generate']);

      final replace = runner.invocation('plutil -replace');
      expect(
        replace.arguments,
        containsAllInOrder(<String>[
          'CFBundleDisplayName',
          '-string',
          r'$(APP_DISPLAY_NAME)',
        ]),
      );
      expect(logger.output, contains(r'$(APP_DISPLAY_NAME)'));
    });

    test('defines APP_DISPLAY_NAME for the unflavored build types too', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      final request =
          jsonDecode(runner.invocation('configure').stdin!)
              as Map<String, dynamic>;
      final byName = <String, Map<String, dynamic>>{
        for (final c
            in (request['configurations'] as List<dynamic>)
                .cast<Map<String, dynamic>>())
          c['name'] as String: c,
      };

      // Once the plist says \$(APP_DISPLAY_NAME), a configuration that does not
      // define it produces an app with an *empty* name. The unflavored build
      // types must therefore keep whatever the plist said before.
      for (final buildType in const <String>['Debug', 'Release', 'Profile']) {
        final settings =
            byName[buildType]!['buildSettings'] as Map<String, dynamic>;
        expect(settings['APP_DISPLAY_NAME'], 'Demo App');
      }
    });

    test('gives each flavor its own display name', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      final request =
          jsonDecode(runner.invocation('configure').stdin!)
              as Map<String, dynamic>;
      final byName = <String, Map<String, dynamic>>{
        for (final c
            in (request['configurations'] as List<dynamic>)
                .cast<Map<String, dynamic>>())
          c['name'] as String: c,
      };

      expect(
        (byName['Release-dev']!['buildSettings']
            as Map<String, dynamic>)['APP_DISPLAY_NAME'],
        'Acme Dev',
      );
      expect(
        (byName['Release-prod']!['buildSettings']
            as Map<String, dynamic>)['APP_DISPLAY_NAME'],
        'Acme',
      );
    });

    test('mentions it in --dry-run without touching the plist', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      await run(<String>['generate', '--dry-run']);

      expect(logger.output, contains('own name on the home screen'));
      expect(runner.ran('plutil -replace'), isFalse);
    });
  });

  group('editing a managed block', () {
    setUp(makeAgreeingProject);

    Future<void> setUpGenerated() async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);
    }

    test('an edit inside the block is refused with a diff', () async {
      await setUpGenerated();
      final edited = project
          .read('android/app/build.gradle.kts')
          .replaceAll('Acme Dev', 'Hand Edited');
      project.write('android/app/build.gradle.kts', edited);
      logger.clear();

      final exit = await run(<String>['generate', 'android-flavors']);

      // Refusing to do what was asked is a user error, the same as a conflict
      // on an unadopted file: something needs a decision.
      expect(exit, ShipwayExit.userError);
      expect(logger.output, contains('edited'));
      expect(logger.output, contains('--force'));
      expect(
        project.read('android/app/build.gradle.kts'),
        contains('Hand Edited'),
        reason: 'the edit must survive a refusal',
      );
    });

    test('--force discards the edit', () async {
      await setUpGenerated();
      project.write(
        'android/app/build.gradle.kts',
        project
            .read('android/app/build.gradle.kts')
            .replaceAll('Acme Dev', 'Hand Edited'),
      );

      await run(<String>['generate', 'android-flavors', '--force']);

      expect(
        project.read('android/app/build.gradle.kts'),
        contains('Acme Dev'),
      );
    });

    test('an edit outside the block is left alone', () async {
      await setUpGenerated();
      final withExtra = project
          .read('android/app/build.gradle.kts')
          .replaceFirst('android {', 'android {\n    // my own note');
      project.write('android/app/build.gradle.kts', withExtra);

      await run(<String>['generate', 'android-flavors']);

      // Editing around the block is the user's right and not a conflict.
      expect(
        project.read('android/app/build.gradle.kts'),
        contains('// my own note'),
      );
    });
  });

  group('a project that already declares its flavors', () {
    const gradlePath = 'android/app/build.gradle.kts';

    setUp(() async {
      await makeAgreeingProject();
      // The field report's shape: flavors the project creates itself, with a
      // value of its own that shipway does not manage.
      project.withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    flavorDimensions += "environment"

    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Acme Dev")
            manifestPlaceholders["deepLinkHost"] = "dev.acme.app"
        }

        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
        }
    }
}
''');
    });

    test(
      'generate creates each flavor once and keeps what is the project\'s',
      () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        logger.clear();

        expect(
          await run(<String>['generate']),
          ShipwayExit.success,
          reason: logger.output,
        );

        final gradle = project.read(gradlePath);
        // Before this, the block's create("dev") sat beside the project's own,
        // and Gradle refused the second.
        expect(RegExp(r'create\("dev"\)').allMatches(gradle), hasLength(1));
        expect(RegExp(r'create\("prod"\)').allMatches(gradle), hasLength(1));
        expect(RegExp('flavorDimensions').allMatches(gradle), hasLength(1));
        expect(gradle, contains('getByName("dev")'));
        expect(
          gradle,
          contains('manifestPlaceholders["deepLinkHost"] = "dev.acme.app"'),
        );
        // The block comes first, so getByName finds the flavor it created.
        expect(
          gradle.indexOf('create("dev")'),
          lessThan(gradle.indexOf('getByName("dev")')),
        );
      },
    );

    test('adopt shows the rewrite before anything is written', () async {
      await run(<String>['import']);
      final before = project.read(gradlePath);
      logger.clear();

      await run(<String>['adopt', gradlePath, '--dry-run']);

      expect(logger.output, contains('getByName("dev")'));
      expect(project.read(gradlePath), before);
    });

    test('what cannot be rewritten stops adopt, naming the line', () async {
      project.withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    flavorDimensions += "environment"
    productFlavors.create("dev") {
        dimension = "environment"
    }
}
''');
      await run(<String>['import']);
      final before = project.read(gradlePath);
      logger.clear();

      final exit = await run(<String>['adopt', 'all']);

      expect(exit, ShipwayExit.userError);
      expect(logger.output, contains('$gradlePath:6'));
      expect(logger.output, contains('getByName'));
      expect(logger.output, contains('Not adopted.'));
      expect(project.read(gradlePath), before);
    });
  });

  group('entrypoints that call into an existing main_common.dart', () {
    setUp(makeAgreeingProject);

    test('are not written while it has no bootstrap', () async {
      project.write(
        'lib/main_common.dart',
        'Future<void> mainCommon() async {}\n',
      );
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      final exit = await run(<String>['generate', 'entrypoints']);

      expect(exit, ShipwayExit.userError);
      expect(logger.output, contains('bootstrap({required String flavor})'));
      expect(logger.output, contains('lib/main_common.dart'));
      expect(project.read('lib/main_dev.dart'), 'void main() {}\n');
    });

    test('are written once it has one', () async {
      project.write(
        'lib/main_common.dart',
        'Future<void> bootstrap({required String flavor}) async {}\n',
      );
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      expect(
        await run(<String>['generate', 'entrypoints']),
        ShipwayExit.success,
        reason: logger.output,
      );
      expect(
        project.read('lib/main_dev.dart'),
        contains("common.bootstrap(flavor: 'dev')"),
      );
    });
  });
}
