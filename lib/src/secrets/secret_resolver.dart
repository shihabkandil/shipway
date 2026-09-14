import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/env/host_platform.dart';
import '../core/env/run_environment.dart';
import '../core/io/process_runner.dart';
import '../core/io/redactor.dart';
import 'secret_requirements.dart';

/// Where a value was found.
enum SecretSource {
  environment,
  dotenv,
  keychain,

  /// Present, but the path it names does not exist — the same failure as being
  /// unset, only discovered later.
  missingFile,

  /// Not found anywhere the environment allows looking.
  absent,

  /// Would be asked for interactively. Only reachable on a workstation.
  prompt;

  bool get found =>
      this == SecretSource.environment ||
      this == SecretSource.dotenv ||
      this == SecretSource.keychain;
}

/// What became of one secret. Deliberately carries no value.
///
/// The type is the guarantee: `shipway secrets list` cannot print a credential
/// because it is never handed one. Anything wanting the value asks
/// [SecretResolver.read] and gets it registered with the redactor first.
class SecretStatus {
  const SecretStatus({
    required this.requirement,
    required this.source,
    this.detail,
  });

  final SecretRequirement requirement;
  final SecretSource source;

  /// Where it came from, in words — a file path, a keychain name.
  final String? detail;

  String get name => requirement.name;

  /// Whether this blocks a run: required, and not found.
  bool get blocks => requirement.isRequired && !source.found;
}

/// Resolves secrets by name, in the order the environment permits.
///
/// The chain is a property of the environment rather than a constant. On a
/// workstation it ends in a prompt; anywhere else it ends in a failure that
/// names what is missing, because a prompt on a runner is a hang, and a hang
/// burns the job timeout while reporting nothing.
class SecretResolver {
  SecretResolver({
    required this.environment,
    required this.projectRoot,
    required this.runner,
    required this.redactor,
    Map<String, String>? processEnvironment,
    this.keychainService = defaultKeychainService,
    this.flavor,
    HostPlatform? host,
  }) : host = host ?? HostPlatform.current,
       _processEnvironment = processEnvironment ?? Platform.environment;

  /// The generic-password service shipway stores secrets under.
  static const String defaultKeychainService = 'shipway';

  final RunEnvironment environment;
  final String projectRoot;
  final ProcessRunner runner;

  /// Every value read is registered here before it is returned, so a secret
  /// echoed by a subprocess never reaches a terminal or a log.
  final Redactor redactor;

  final String keychainService;

  /// The machine this is running on. Only one thing turns on it: there is no
  /// `security` keychain off macOS, so it must not be offered as a place a
  /// value could be.
  final HostPlatform host;

  /// Selects `.env.<flavor>`, when the config names a per-flavor file.
  final String? flavor;

  final Map<String, String> _processEnvironment;

  Map<String, ({String value, String file})>? _dotenv;

  /// Where each source may be consulted, in order, for this environment.
  ///
  /// The login keychain is absent off the workstation on purpose: on a headless
  /// Mac it may not be unlocked after a reboot, and depending on it is what
  /// makes self-hosted builders fail in ways that look like signing problems.
  ///
  /// It is absent off macOS for a blunter reason — there is no such keychain —
  /// and the chain is printed to the user, so listing a place nothing could
  /// ever be found is a lie about where to put a value.
  List<SecretSource> get chain => <SecretSource>[
    for (final source in _chainFor(environment))
      if (source != SecretSource.keychain || host.hasSecurityKeychain) source,
  ];

  static List<SecretSource> _chainFor(RunEnvironment environment) =>
      switch (environment) {
        RunEnvironment.workstation => const <SecretSource>[
          SecretSource.environment,
          SecretSource.dotenv,
          SecretSource.keychain,
          SecretSource.prompt,
        ],
        RunEnvironment.ephemeralCi => const <SecretSource>[
          SecretSource.environment,
        ],
        RunEnvironment.persistentRunner => const <SecretSource>[
          SecretSource.environment,
          SecretSource.dotenv,
        ],
      };

  /// Reports on [requirement] without exposing its value.
  Future<SecretStatus> status(SecretRequirement requirement) async {
    for (final source in chain) {
      final found = await _read(requirement.name, source);
      if (found == null) continue;

      if (requirement.isPath && !_fileExists(found)) {
        return SecretStatus(
          requirement: requirement,
          source: SecretSource.missingFile,
          detail: found,
        );
      }
      return SecretStatus(
        requirement: requirement,
        source: source,
        detail: source == SecretSource.dotenv
            ? (await _loadDotenv())[requirement.name]?.file
            : _describe(source),
      );
    }

    return SecretStatus(
      requirement: requirement,
      source: SecretSource.absent,
      detail: environment.mayPrompt
          ? null
          : 'not set, and this environment cannot prompt',
    );
  }

  Future<List<SecretStatus>> statuses(
    Iterable<SecretRequirement> requirements,
  ) async => <SecretStatus>[
    for (final requirement in requirements) await status(requirement),
  ];

  /// The actual value, registered with the redactor before it is returned.
  Future<String?> read(String name) async {
    for (final source in chain) {
      final value = await _read(name, source);
      if (value == null) continue;
      redactor.register(value);
      return value;
    }
    return null;
  }

  Future<String?> _read(String name, SecretSource source) async =>
      switch (source) {
        SecretSource.environment => _nonEmpty(_processEnvironment[name]),
        SecretSource.dotenv => _nonEmpty((await _loadDotenv())[name]?.value),
        SecretSource.keychain => await _readKeychain(name),
        // A prompt is not a lookup; it is what the caller does when the chain
        // runs out, and only where the environment allows it.
        _ => null,
      };

  String? _describe(SecretSource source) => switch (source) {
    SecretSource.environment => 'environment',
    SecretSource.dotenv => dotenvPath,
    SecretSource.keychain => 'keychain ($keychainService)',
    _ => null,
  };

  /// `.env.<flavor>` when a flavor is in play, otherwise `.env`.
  String get dotenvPath => flavor == null ? '.env' : '.env.$flavor';

  /// `.env`, with `.env.<flavor>` layered over it when a flavor is in play.
  ///
  /// Layered rather than either-or. Teams keep what every flavor shares in
  /// `.env` and what differs in the flavor's file; reading only the flavor's
  /// file reported a variable missing that was set exactly where people put
  /// it.
  Future<Map<String, ({String value, String file})>> _loadDotenv() async {
    final cached = _dotenv;
    if (cached != null) return cached;

    final values = <String, ({String value, String file})>{};
    for (final name in <String>['.env', if (flavor != null) '.env.$flavor']) {
      final file = File(p.join(projectRoot, name));
      if (!file.existsSync()) continue;
      for (final entry in parseDotenv(await file.readAsString()).entries) {
        values[entry.key] = (value: entry.value, file: name);
      }
    }
    return _dotenv = values;
  }

  Future<String?> _readKeychain(String name) async {
    if (!environment.mayUseLoginKeychain || !host.hasSecurityKeychain) {
      return null;
    }

    final result = await runner.run('security', <String>[
      'find-generic-password',
      '-s',
      keychainService,
      '-a',
      name,
      '-w',
    ]);
    // A missing item is an ordinary answer, not a failure worth reporting.
    if (!result.ok) return null;
    return _nonEmpty(result.stdout.trim());
  }

  bool _fileExists(String path) =>
      File(p.isAbsolute(path) ? path : p.join(projectRoot, path)).existsSync();

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;

  /// A deliberately small `.env` parser.
  ///
  /// Handles what these files actually contain — `KEY=value`, comments, blank
  /// lines, optional `export`, and quoted values — and nothing more. A full
  /// shell parser would invite people to put logic in a secrets file.
  static Map<String, String> parseDotenv(String contents) {
    final values = <String, String>{};
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final withoutExport = line.startsWith('export ')
          ? line.substring('export '.length).trim()
          : line;
      final separator = withoutExport.indexOf('=');
      if (separator <= 0) continue;

      final key = withoutExport.substring(0, separator).trim();
      var value = withoutExport.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }
    return values;
  }
}
