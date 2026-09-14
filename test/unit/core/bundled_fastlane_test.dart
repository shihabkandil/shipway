import 'package:shipway/src/core/toolchain/bundled_fastlane.dart';
import 'package:test/test.dart';

import '../../support/fastlane_toolchain.dart';
import '../../support/recording_process_runner.dart';

void main() {
  test('fastlane is loaded from the bundle, never found on PATH', () {
    // `bundle exec fastlane` searches PATH, where Homebrew's wrapper replaces
    // GEM_HOME and throws the bundle away. A binstub's loader cannot be
    // shadowed.
    expect(
      BundledFastlane.arguments(<String>['android', 'firebase', 'flavor:dev']),
      <String>[
        'exec',
        'ruby',
        '-e',
        'load Gem.bin_path("fastlane", "fastlane")',
        '--',
        'android',
        'firebase',
        'flavor:dev',
      ],
    );
  });

  group('reading the toolchain', () {
    test('every fact the probe prints', () {
      final toolchain = FastlaneToolchain.parse(
        toolchainProbeOutput(fastlane: '2.238.0'),
      );
      expect(toolchain.ruby, '/Users/dev/.rvm/rubies/ruby-3.3.6/bin/ruby');
      expect(toolchain.rubyVersion, '3.3.6');
      expect(toolchain.bundler, '2.6.3');
      expect(toolchain.fastlane, '2.238.0');
      expect(toolchain.gemHome, '/Users/dev/.rvm/gems/ruby-3.3.6');
    });

    test('warnings on the same stream are not facts', () {
      final toolchain = FastlaneToolchain.parse('''
Ignoring json-2.6.1 because its extensions are not built.
WARNING: RUBYOPT=-W0 is set
ruby_version=3.1.1
fastlane=
''');
      expect(toolchain.rubyVersion, '3.1.1');
      // Empty means the bundle has no fastlane, not a version called "".
      expect(toolchain.fastlane, isNull);
      expect(toolchain.ruby, isNull);
    });
  });

  group('asking a bundle about itself', () {
    late RecordingProcessRunner runner;

    setUp(() => runner = RecordingProcessRunner());

    Future<FastlaneProbe> probe() => BundledFastlane.probe(
      runner,
      directory: '/project/android',
      platform: 'android',
    );

    test('runs in the platform directory, through bundler', () async {
      stubFastlaneToolchain(runner);

      final result = await probe();

      expect(result.toolchain?.fastlane, isNotNull);
      final invocation = runner.invocation('RUBY_VERSION');
      expect(invocation.executable, 'bundle');
      expect(invocation.workingDirectory, '/project/android');
    });

    test('a bundle that was never installed says to install it', () async {
      runner.stub(
        'RUBY_VERSION',
        exitCode: 7,
        stderr:
            "Could not find gem 'fastlane (= 2.238.0)' in locally installed "
            'gems.\nRun `bundle install` to install missing gems.',
      );

      final failure = (await probe()).failure;

      expect(failure?.what, contains('not installed'));
      expect(failure?.fix, contains('`bundle install` in android/'));
      // Installed for one Ruby and run with another looks identical, so the
      // way to tell them apart is part of the advice.
      expect(failure?.fix, contains('which ruby bundle'));
    });

    test('no Gemfile points at generate', () async {
      runner.stub(
        'RUBY_VERSION',
        exitCode: 10,
        stderr: 'Could not locate Gemfile or .bundle/ directory',
      );
      expect(
        (await probe()).failure?.fix,
        contains('shipway generate fastlane'),
      );
    });

    test('no bundler at all', () async {
      runner.stub('RUBY_VERSION', exitCode: 127, stderr: 'not found');
      expect(
        (await probe()).failure?.what,
        contains('bundler is not available'),
      );
    });

    test('a bundle without fastlane in it', () async {
      runner.stub('RUBY_VERSION', stdout: 'ruby_version=3.3.6\nfastlane=\n');
      expect(
        (await probe()).failure?.what,
        contains('does not include fastlane'),
      );
    });
  });
}
