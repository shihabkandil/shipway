import 'package:shipway/src/core/toolchain/bundled_fastlane.dart';
import 'package:shipway/src/core/toolchain/pod_repo_update.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  group('which pod refreshes the spec repo', () {
    test('plain pod when there is no Gemfile', () {
      final command = PodRepoUpdate.command(project.path);
      expect(command.executable, 'pod');
      expect(command.arguments, <String>['install', '--repo-update']);
    });

    test('plain pod when the Gemfile does not bundle CocoaPods', () {
      project.write('ios/Gemfile', 'gem "fastlane", "2.238.0"\n');
      expect(PodRepoUpdate.command(project.path).executable, 'pod');
    });

    test('the bundle when the Gemfile names CocoaPods', () {
      project.write(
        'ios/Gemfile',
        'gem "fastlane"\n'
            "  gem 'cocoapods', '~> 1.16'\n",
      );
      final command = PodRepoUpdate.command(project.path);
      expect(command.executable, 'bundle');
      expect(command.arguments, <String>[
        'exec',
        'pod',
        'install',
        '--repo-update',
      ]);
    });

    test('the bundle when only the lock file has it', () {
      project
        ..write('ios/Gemfile', 'gem "fastlane"\n')
        ..write(
          'ios/Gemfile.lock',
          'GEM\n  specs:\n    cocoapods (1.16.2)\n      cocoapods-core (= 1.16.2)\n',
        );
      expect(PodRepoUpdate.command(project.path).executable, 'bundle');
    });

    test('a gem that merely starts with the name is not CocoaPods', () {
      project
        ..write('ios/Gemfile', 'gem "cocoapods-keys"\n')
        ..write(
          'ios/Gemfile.lock',
          'GEM\n  specs:\n    cocoapods-core (1.16.2)\n',
        );
      expect(PodRepoUpdate.command(project.path).executable, 'pod');
    });
  });

  group('the environment a lane runs in', () {
    test('turns off the update check, and so its changelog', () {
      expect(
        BundledFastlane.environment(const <String, String>{}),
        <String, String>{'FASTLANE_SKIP_UPDATE_CHECK': '1'},
      );
    });

    test('keeps the credentials, and a value somebody set on purpose', () {
      final environment = BundledFastlane.environment(const <String, String>{
        'MATCH_PASSWORD': 'x',
        'FASTLANE_SKIP_UPDATE_CHECK': '0',
      });
      expect(environment['MATCH_PASSWORD'], 'x');
      expect(environment['FASTLANE_SKIP_UPDATE_CHECK'], '0');
    });
  });
}
