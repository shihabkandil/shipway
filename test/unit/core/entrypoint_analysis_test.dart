import 'package:shipway/src/core/toolchain/entrypoint_analysis.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Verbatim `dart analyze --no-fatal-warnings` output from Dart 3.13, exit 3.
const String _undefinedBootstrap = '''
Analyzing main_dev.dart...

  error - main_dev.dart:4:10 - The function 'bootstrap' isn't defined. Try importing the library that defines 'bootstrap', correcting the name to the name of an existing function, or defining a function named 'bootstrap'. - undefined_function
warning - main_dev.dart:5:7 - The value of the local variable 'unused' isn't used. Try removing the variable or using it. - unused_local_variable

2 issues found.''';

void main() {
  late FixtureProject project;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    runner = RecordingProcessRunner();
  });

  Future<EntrypointAnalysis> analyse() => EntrypointAnalysis.run(
    runner,
    root: project.path,
    entrypoint: 'lib/main_dev.dart',
  );

  void resolved() =>
      project.write('.dart_tool/package_config.json', '{"configVersion":2}');

  test('unresolved packages skip it rather than fail everything', () async {
    // Every import is an error before `pub get`, which would call a healthy
    // project broken. `flutter build` fetches packages itself.
    final analysis = await analyse();

    expect(analysis.failed, isFalse);
    expect(analysis.skipped, contains('flutter pub get'));
    expect(runner.invocations, isEmpty);
  });

  test('analyses just the entrypoint, with warnings allowed', () async {
    resolved();

    final analysis = await analyse();

    expect(analysis.failed, isFalse);
    final invocation = runner.invocation('dart analyze');
    expect(invocation.arguments, <String>[
      'analyze',
      '--no-fatal-warnings',
      'lib/main_dev.dart',
    ]);
    expect(invocation.workingDirectory, project.path);
  });

  test('reports the errors, and only the errors', () async {
    resolved();
    runner.stub('dart analyze', exitCode: 3, stdout: _undefinedBootstrap);

    final analysis = await analyse();

    expect(analysis.failed, isTrue);
    expect(analysis.errors, hasLength(1));
    expect(analysis.errors.single, contains("'bootstrap' isn't defined"));
  });

  test('a failure it cannot read is not a reason to stop', () async {
    resolved();
    runner.stub('dart analyze', exitCode: 64, stderr: 'Could not find a file');

    final analysis = await analyse();

    expect(analysis.failed, isFalse);
    expect(analysis.skipped, contains('exited 64'));
  });

  test('no dart at all', () async {
    resolved();
    runner.stub('dart analyze', exitCode: 127);
    expect((await analyse()).skipped, contains('not on PATH'));
  });
}
