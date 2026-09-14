import 'package:shipway/src/generators/write_guards.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  const guard = DartFunctionGuard(
    path: 'lib/main_common.dart',
    caller: 'lib/main_dev.dart',
    name: 'bootstrap',
    parameter: 'flavor',
    signature: 'bootstrap({required String flavor})',
    example: 'Future<void> bootstrap({required String flavor}) async {}',
  );

  WriteBlocker? withCommon(String source) {
    project.write('lib/main_common.dart', source);
    return guard.check(project.path);
  }

  test('no main_common.dart yet is fine: shipway creates it', () {
    expect(guard.check(project.path), isNull);
  });

  test('a declaration taking the flavor satisfies it', () {
    expect(
      withCommon(
        'Future<void> bootstrap({\n  required String flavor,\n}) async {}\n',
      ),
      isNull,
    );
    expect(withCommon('void bootstrap({required String flavor}) {}\n'), isNull);
  });

  test('the field report\'s main_common.dart is refused, with an example', () {
    final blocker = withCommon('Future<void> mainCommon() async {}\n');

    expect(
      blocker?.reason,
      contains(
        'lib/main_dev.dart would call `bootstrap({required String flavor})` '
        'from lib/main_common.dart',
      ),
    );
    expect(blocker?.remedy, contains('Future<void> bootstrap('));
  });

  test('a bootstrap without the flavor parameter is refused too', () {
    expect(withCommon('Future<void> bootstrap() async {}\n'), isNotNull);
  });

  test('a call inside another function is not a declaration', () {
    expect(
      withCommon('void main() {\n  bootstrap(flavor: "dev");\n}\n'),
      isNotNull,
    );
  });

  test('a file that re-exports is not guessed about', () {
    expect(withCommon("export 'src/bootstrap.dart';\n"), isNull);
  });
}
