import 'package:shipway/src/core/fastlane/fastfile_lanes.dart';
import 'package:shipway/src/core/fastlane/release_target.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

void main() {
  test('only lanes that can be run count', () {
    const source = '''
platform :android do
  lane :play do |options|
  end

  private_lane :helper do
  end

  # lane :firebase do
end
''';
    // A private lane cannot be run from the command line, and a commented-out
    // one is not there at all.
    expect(FastfileLanes.publicIn(source), <String>{'play'});
  });

  group('why a lane cannot run', () {
    late FixtureProject project;

    setUp(() async {
      project = await FixtureProject.create();
      addTearDown(project.dispose);
    });

    const path = 'android/fastlane/Fastfile';

    Future<MissingLane?> check() =>
        FastfileLanes.check(project.path, ReleaseTarget.firebase);

    test('no Fastfile at all', () async {
      final missing = await check();
      expect(missing?.what, contains('There is no $path'));
      expect(missing?.fix, contains('shipway generate fastlane'));
    });

    test('nothing, when the lane is there', () async {
      project.write(
        path,
        'platform :android do\n  lane :firebase do\n  end\n'
        'end\n',
      );
      expect(await check(), isNull);
    });

    test('a Fastfile shipway wrote only needs regenerating', () async {
      project.write(path, 'lane :play do\nend\n');
      await (LockFile.empty()..record(
            const LockEntry(
              path: path,
              ownership: Ownership.generated,
              mode: WriteMode.full,
            ),
          ))
          .save(project.path);

      final missing = await check();
      expect(missing?.what, contains('targets.firebase'));
      expect(missing?.fix, 'Run `shipway generate fastlane`.');
    });

    test('the project\'s own Fastfile is never replaced unseen', () async {
      // Regenerating over a hand-written Fastfile destroys somebody's release
      // process, so the advice has to say that adopting replaces it.
      project.write(path, 'lane :play do\nend\n');

      final missing = await check();
      expect(missing?.what, contains('your project\'s own'));
      expect(missing?.fix, contains('Add a `firebase` lane'));
      expect(missing?.fix, contains('shipway adopt $path'));
    });
  });
}
