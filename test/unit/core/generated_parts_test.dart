import 'package:shipway/src/core/dart/generated_parts.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project.write('pubspec.yaml', '''
name: acme_app
dev_dependencies:
  build_runner: ^2.4.0
''');
  });

  const source = "part 'user.g.dart';\n\nclass User {}\n";

  test('build_runner is recognised from dev_dependencies', () {
    expect(GeneratedParts.usesBuildRunner(project.path), isTrue);
    project.write('pubspec.yaml', 'name: acme_app\n');
    expect(GeneratedParts.usesBuildRunner(project.path), isFalse);
  });

  test('a generated part that was never generated', () {
    project.write('lib/models/user.dart', source);

    final stale = GeneratedParts.find(project.path).single;

    expect(stale.part, 'lib/models/user.g.dart');
    expect(stale.source, 'lib/models/user.dart');
    expect(stale.missing, isTrue);
  });

  test('a generated part older than its source', () {
    project
      ..write('lib/models/user.dart', source)
      ..write('lib/models/user.g.dart', '// generated\n');
    project
        .file('lib/models/user.g.dart')
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));

    final stale = GeneratedParts.find(project.path).single;
    expect(stale.missing, isFalse);
  });

  test('seconds apart is not stale: a checkout writes files in any order', () {
    project
      ..write('lib/models/user.dart', source)
      ..write('lib/models/user.g.dart', '// generated\n');
    project
        .file('lib/models/user.g.dart')
        .setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 2)),
        );

    expect(GeneratedParts.find(project.path), isEmpty);
  });

  test('a hand-written part is not generated code', () {
    project.write('lib/widgets.dart', "part 'src/button.dart';\n");
    expect(GeneratedParts.find(project.path), isEmpty);
  });
}
