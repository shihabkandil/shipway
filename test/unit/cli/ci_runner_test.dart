import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/config/config_exception.dart';
import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/generators/resolve_app.dart';
import 'package:shipway/src/generators/workflow_generator.dart';
import 'package:shipway/src/inspect/config_writer.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Captures output and answers prompts, so `init` is testable with no
/// terminal. [choice] is what `chooseOne` returns; [asked] is what it was
/// asked.
class _CapturingLogger extends Logger {
  final List<String> lines = <String>[];
  final List<String> asked = <String>[];
  String? choice;

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

  @override
  Progress progress(String message, {ProgressOptions? options}) {
    lines.add(message);
    return super.progress(message, options: options);
  }

  @override
  bool confirm(String? message, {bool defaultValue = false}) => true;

  @override
  T chooseOne<T extends Object?>(
    String? message, {
    required List<T> choices,
    T? defaultValue,
    String Function(T choice)? display,
  }) {
    asked.add(message ?? '');
    return choices.firstWhere(
      (c) => c.toString().startsWith(choice ?? '\u0000'),
      orElse: () => defaultValue as T,
    );
  }

  String get output => lines.join('\n');
}

const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    flavors:
      dev:
        suffix: .dev
''';

void main() {
  group('ci.runner in shipway.yaml', () {
    test('is hosted when nobody has said', () {
      final config = ConfigLoader.parse(_config);
      expect(config.ci.runner, isNull);
      expect(config.ci.effectiveRunner, CiRunner.hosted);
      expect(ResolveApp.resolve(config).ciRunner, CiRunner.hosted);
    });

    test('self-hosted reaches the generators', () {
      final config = ConfigLoader.parse(
        '${_config}ci:\n  runner: self-hosted\n',
      );
      expect(config.ci.runner, CiRunner.selfHosted);
      expect(ResolveApp.resolve(config).ciRunner, CiRunner.selfHosted);
    });

    test('anything else is refused, naming the key', () {
      expect(
        () => ConfigLoader.parse('${_config}ci:\n  runner: my-mac\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('runner'),
          ),
        ),
      );
    });

    test('does not change what kind of machine a laptop thinks it is', () {
      // The reason it is a key of its own. `ci.environment: persistent` is
      // read by every machine that loads the config, and would stop a
      // developer's shipway from ever prompting.
      final config = ConfigLoader.parse(
        '${_config}ci:\n  runner: self-hosted\n',
      );
      expect(config.ci.environment, isNull);
      expect(
        EnvironmentDetector.resolve(
          configured: config.ci.environment,
          environment: const <String, String>{},
        ).environment,
        RunEnvironment.workstation,
      );
    });

    test('tells the runner what it is through the workflow instead', () {
      expect(
        WorkflowGenerator.environmentFor(CiRunner.selfHosted),
        RunEnvironment.persistentRunner,
      );
      expect(
        WorkflowGenerator.environmentFor(CiRunner.hosted),
        RunEnvironment.ephemeralCi,
      );
    });

    test('survives being written and read back', () {
      final config = ConfigLoader.parse(
        _config,
      ).withCi(const CiConfig(runner: CiRunner.selfHosted, environment: 'ci'));
      final yaml = ConfigWriter.render(
        config,
        generatedBy: 'test',
        generatedAt: DateTime.utc(2026, 10, 1),
      );
      final reread = ConfigLoader.parse(yaml);
      expect(reread.ci.runner, CiRunner.selfHosted);
      expect(reread.ci.environment, 'ci');
    });

    test('is not written when nobody decided', () {
      // `import` cannot know, and a guess written down reads as a decision.
      final yaml = ConfigWriter.render(
        ConfigLoader.parse(_config),
        generatedBy: 'test',
        generatedAt: DateTime.utc(2026, 10, 1),
      );
      expect(yaml, isNot(contains('ci:')));
    });
  });

  group('shipway init', () {
    late _CapturingLogger logger;
    late FixtureProject project;

    setUp(() async {
      logger = _CapturingLogger();
      project = await FixtureProject.create();
      addTearDown(project.dispose);
      project
        ..withPubspec(name: 'acme_app')
        ..withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
        }
    }
}
''')
        ..withEntrypoint('dev');
    });

    Future<int> init(
      List<String> args, {
      Map<String, String> environment = const <String, String>{},
    }) => ShipwayCommandRunner(
      logger: logger,
      runner: RecordingProcessRunner(),
      workingDirectory: project.path,
      environment: environment,
    ).run(<String>['--no-color', ...args, 'init']);

    CiRunner? written() =>
        ConfigLoader.parse(project.read('shipway.yaml')).ci.runner;

    test('asks where CI will run, and records the answer', () async {
      logger.choice = 'A self-hosted runner';
      expect(await init(const <String>[]), ShipwayExit.success);

      expect(logger.asked, <String>['Where will CI run?']);
      expect(written(), CiRunner.selfHosted);
      expect(project.read('shipway.yaml'), contains('runner: self-hosted'));
    });

    test('records hosted when that is the answer', () async {
      logger.choice = 'GitHub-hosted';
      await init(const <String>[]);
      expect(written(), CiRunner.hosted);
    });

    test('writes nothing for "not decided"', () async {
      logger.choice = 'Not decided';
      await init(const <String>[]);
      expect(written(), isNull);
      expect(project.read('shipway.yaml'), isNot(contains('ci:')));
    });

    test('does not ask under --yes', () async {
      expect(await init(const <String>['--yes']), ShipwayExit.success);
      expect(logger.asked, isEmpty);
      expect(written(), isNull);
    });

    test('does not ask on a runner, where a question is a hang', () async {
      expect(
        await init(
          const <String>[],
          environment: const <String, String>{'CI': 'true'},
        ),
        ShipwayExit.success,
      );
      expect(logger.asked, isEmpty);
      expect(written(), isNull);
    });

    test('takes the answer from --runner without asking', () async {
      final code = await ShipwayCommandRunner(
        logger: logger,
        runner: RecordingProcessRunner(),
        workingDirectory: project.path,
        environment: const <String, String>{},
      ).run(<String>['--no-color', '--yes', 'init', '--runner', 'self-hosted']);

      expect(code, ShipwayExit.success);
      expect(logger.asked, isEmpty);
      expect(written(), CiRunner.selfHosted);
      expect(logger.output, contains('shipway generate ci'));
    });
  });

  group('shipway generate ci', () {
    late _CapturingLogger logger;
    late FixtureProject project;

    setUp(() async {
      logger = _CapturingLogger();
      project = await FixtureProject.create();
      addTearDown(project.dispose);
    });

    Future<int> generate() => ShipwayCommandRunner(
      logger: logger,
      runner: RecordingProcessRunner(),
      workingDirectory: project.path,
      environment: const <String, String>{},
    ).run(<String>['--no-color', 'generate', 'ci']);

    test('writes the self-hosted workflow when the config says so', () async {
      project.write('shipway.yaml', '${_config}ci:\n  runner: self-hosted\n');

      expect(await generate(), ShipwayExit.success);

      final workflow = project.read(WorkflowGenerator.path);
      expect(WorkflowGenerator.runnerOf(workflow), CiRunner.selfHosted);
      expect(workflow, contains('--env persistent'));
      expect(logger.output, isNot(contains('was not written for')));
    });

    test('writes the hosted one by default', () async {
      project.write('shipway.yaml', _config);
      expect(await generate(), ShipwayExit.success);
      expect(
        WorkflowGenerator.runnerOf(project.read(WorkflowGenerator.path)),
        CiRunner.hosted,
      );
    });

    test('says so when the workflow on disk is for the other kind of '
        'runner, and leaves it alone', () async {
      // The workflow is create-once. Changing ci.runner therefore changes
      // nothing already there, and silence would leave a config saying
      // self-hosted beside a workflow that caches a toolchain.
      project.write('shipway.yaml', _config);
      await generate();
      final hosted = project.read(WorkflowGenerator.path);

      project.write('shipway.yaml', '${_config}ci:\n  runner: self-hosted\n');
      logger.lines.clear();
      await generate();

      expect(project.read(WorkflowGenerator.path), hosted);
      expect(logger.output, contains('was not written for a self-hosted'));
      expect(logger.output, contains('shipway generate ci'));
    });
  });
}
