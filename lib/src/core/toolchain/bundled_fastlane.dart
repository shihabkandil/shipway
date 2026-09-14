import '../io/process_runner.dart';

/// The Ruby, Bundler and fastlane a lane is about to run on.
class FastlaneToolchain {
  const FastlaneToolchain({
    this.ruby,
    this.rubyVersion,
    this.bundler,
    this.fastlane,
    this.fastlanePath,
    this.gemHome,
  });

  /// Reads what [BundledFastlane.probeScript] prints: one `key=value` a line.
  ///
  /// Only the keys the probe writes are taken. Ruby and bundler print their
  /// own warnings to the same stream, and one containing `=` must not become a
  /// fact.
  factory FastlaneToolchain.parse(String output) {
    final facts = <String, String>{};
    for (final line in output.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (_keys.contains(key) && value.isNotEmpty) facts[key] = value;
    }
    return FastlaneToolchain(
      ruby: facts['ruby'],
      rubyVersion: facts['ruby_version'],
      bundler: facts['bundler'],
      fastlane: facts['fastlane'],
      fastlanePath: facts['fastlane_path'],
      gemHome: facts['gem_home'],
    );
  }

  static const Set<String> _keys = <String>{
    'ruby',
    'ruby_version',
    'bundler',
    'fastlane',
    'fastlane_path',
    'gem_home',
  };

  /// The Ruby executable bundler resolved.
  final String? ruby;
  final String? rubyVersion;
  final String? bundler;

  /// The fastlane version in the bundle, or null when the bundle has none.
  final String? fastlane;
  final String? fastlanePath;
  final String? gemHome;
}

/// Why a platform's bundle cannot run a lane, and the one thing to do.
class FastlaneToolchainFailure {
  const FastlaneToolchainFailure({required this.what, required this.fix});

  final String what;
  final String fix;
}

/// What asking a bundle about itself found: exactly one of the two is set.
class FastlaneProbe {
  const FastlaneProbe.found(FastlaneToolchain this.toolchain) : failure = null;

  const FastlaneProbe.failed(FastlaneToolchainFailure this.failure)
    : toolchain = null;

  final FastlaneToolchain? toolchain;
  final FastlaneToolchainFailure? failure;
}

/// How shipway runs fastlane: from the project's bundle, never by name.
///
/// `bundle exec fastlane` finds `fastlane` by searching `PATH`. Homebrew's is a
/// shell script that resets `GEM_HOME` and `GEM_PATH` and runs its own Ruby, so
/// whenever it is ahead of the project's Ruby on `PATH` it throws the bundle
/// away: the Gemfile's pins and the Pluginfile's plugins are not loaded, and a
/// release fails for reasons that look like a broken plugin.
///
/// Loading the executable through `Gem.bin_path` inside the bundle is what a
/// bundler binstub does, and nothing on `PATH` can stand in front of it.
/// Verified on a machine with the Homebrew shim first on `PATH`:
/// `bundle exec fastlane` crashed inside Homebrew's Ruby, while this ran the
/// bundled 2.238.0 on the project's Ruby and passed lane options through.
abstract final class BundledFastlane {
  /// The Ruby a binstub runs, without writing a binstub into the project.
  static const String loader = 'load Gem.bin_path("fastlane", "fastlane")';

  /// `bundle` arguments that run fastlane with [fastlaneArguments].
  ///
  /// `--` ends Ruby's own options, so nothing meant for fastlane is read by
  /// the interpreter.
  static List<String> arguments(List<String> fastlaneArguments) => <String>[
    'exec',
    'ruby',
    '-e',
    loader,
    '--',
    ...fastlaneArguments,
  ];

  /// Prints the facts [FastlaneToolchain.parse] reads.
  static const String probeScript = r'''
spec = Gem.loaded_specs["fastlane"]
puts "ruby=#{RbConfig.ruby}"
puts "ruby_version=#{RUBY_VERSION}"
puts "bundler=#{Bundler::VERSION}"
puts "fastlane=#{spec&.version}"
puts "fastlane_path=#{spec&.bin_file("fastlane")}"
puts "gem_home=#{Gem.dir}"
''';

  /// Asks the bundle in [directory] what a lane would run on.
  ///
  /// Cheap — a second or two — and run before anything slow, so a bundle that
  /// was never installed, or was installed for a different Ruby, fails here
  /// rather than after a release build. [platform] is only for the message.
  static Future<FastlaneProbe> probe(
    ProcessRunner runner, {
    required String directory,
    required String platform,
  }) async {
    final result = await runner.run('bundle', const <String>[
      'exec',
      'ruby',
      '-e',
      probeScript,
    ], workingDirectory: directory);

    if (result.notFound) {
      return FastlaneProbe.failed(
        FastlaneToolchainFailure(
          what: 'bundler is not available.',
          fix:
              'Install it with `gem install bundler`, then run '
              '`bundle install` in $platform/.',
        ),
      );
    }

    if (!result.ok) {
      final output = result.output;
      if (output.contains('Could not locate Gemfile')) {
        return FastlaneProbe.failed(
          FastlaneToolchainFailure(
            what:
                'There is no $platform/Gemfile, so there is no fastlane to run.',
            fix: 'Run `shipway generate fastlane`.',
          ),
        );
      }
      final notInstalled = RegExp(
        r'Could not find|GemNotFound|bundle install',
      ).hasMatch(output);
      return FastlaneProbe.failed(
        FastlaneToolchainFailure(
          what: notInstalled
              ? 'The bundle in $platform/ is not installed for the Ruby that '
                    '`bundle` runs.'
              : 'The bundle in $platform/ could not be loaded: '
                    '${_firstLine(output)}',
          fix:
              'Run `bundle install` in $platform/. If it is installed, a '
              'different Ruby is first on PATH: compare `which ruby bundle`.',
        ),
      );
    }

    final toolchain = FastlaneToolchain.parse(result.stdout);
    if (toolchain.fastlane == null) {
      return FastlaneProbe.failed(
        FastlaneToolchainFailure(
          what: 'The bundle in $platform/ does not include fastlane.',
          fix:
              'Add `gem "fastlane"` to $platform/Gemfile, or run '
              '`shipway generate fastlane`.',
        ),
      );
    }
    return FastlaneProbe.found(toolchain);
  }

  static String _firstLine(String output) {
    for (final line in output.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return 'no output';
  }
}
