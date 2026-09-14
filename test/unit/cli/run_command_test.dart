import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
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

  String get output => lines.join('\n');
}

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    // The field report's pipeline: `prod`, for a flavor named `production`.
    project.write('shipway.yaml', '''
version: 1
project:
  name: acme_app
apps:
  main:
    android:
      application_id: com.acme.app
    flavors:
      development:
        suffix: .dev
      production:
        suffix: ""
    targets:
      firebase:
        groups: [qa]
pipelines:
  beta:
    - analyze
    - test
    - release: { flavor: prod, target: firebase }
''');
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
  });

  Future<int> run(List<String> args) => ShipwayCommandRunner(
    logger: logger,
    runner: runner,
    workingDirectory: project.path,
    host: HostPlatform.macos,
    environment: const <String, String>{},
  ).run(<String>['--env=persistent', ...args]);

  test(
    'a step naming a flavor that does not exist stops before any step',
    () async {
      final code = await run(<String>['run', 'beta', '--no-notify']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('Did you mean `production`?'));
      // Not after analyze and test have run: that is the cost this avoids.
      expect(runner.invocations, isEmpty);
    },
  );
}
