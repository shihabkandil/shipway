import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/shipway_config.dart';
import '../../secrets/repository_secrets.dart';
import '../../secrets/secret_export.dart';
import '../../secrets/secret_requirements.dart';
import '../../secrets/secret_resolver.dart';
import '../../secrets/secret_store.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway secrets list|check|set|import|export`.
///
/// `list` and `check` answer the same question — what does this project need,
/// and is it here? — and neither ever prints a value. That is a property of the
/// types rather than of care: the resolver hands back a [SecretStatus] carrying
/// a source, never a secret.
///
/// `check` exists to be the first step of a CI job. It turns a twenty-minute
/// build that dies at the upload into a five-second failure naming
/// `ASC_KEY_P8_BASE64`.
///
/// `set` and `import` are the only things in shipway that hold a credential,
/// and they hold it exactly long enough to hand it to the keychain. `export`
/// holds none at all: it emits the *names* a CI repository needs, which is the
/// half of the loop a generated workflow cannot close for you.
class SecretsCommand extends Command<int> {
  SecretsCommand(this._contextProvider) {
    argParser
      ..addFlag('json', negatable: false, help: 'Emit the report as JSON.')
      ..addOption(
        'flavor',
        abbr: 'f',
        help: 'Resolve .env.<flavor> rather than .env.',
      )
      ..addOption(
        'from-file',
        help: 'set: read the value from this file rather than prompting.',
        valueHelp: 'path',
      )
      ..addFlag(
        'stdin',
        negatable: false,
        help: 'set: read the value from standard input.',
      )
      ..addFlag(
        'base64',
        negatable: false,
        help:
            'set: base64-encode the value before storing it. What the '
            'ASC key and the Android keystore need.',
      )
      ..addOption(
        'from',
        help: 'import: the .env file to read. Defaults to this flavor\'s.',
        valueHelp: 'path',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'import: replace values already in the keychain.',
      )
      ..addOption(
        'format',
        help: 'export: what shape to emit.',
        allowed: ExportFormat.names,
        defaultsTo: 'gh',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'secrets';

  @override
  String get description =>
      'Show which credentials this project needs, and whether they are set.';

  @override
  String get invocation => 'shipway secrets list|check|set|import|export';

  static const List<String> _actions = <String>[
    'list',
    'check',
    'set',
    'import',
    'export',
  ];

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final action = results.rest.isEmpty ? 'list' : results.rest.first;
    if (!_actions.contains(action)) {
      logger.err(
        'Unknown action "$action". Expected one of: ${_actions.join(', ')}.',
      );
      return ShipwayExit.userError;
    }

    final config = await context.requireConfig();
    final environment = context.environment;

    if (action == 'export') return _export(config);

    final requirements = SecretRequirements.of(
      config,
      environment: environment.environment,
      appId: context.appId,
      flavor: results['flavor'] as String?,
    );
    // `set` and `import` come before the empty-list shortcut: a config that
    // declares nothing yet is a reason not to validate a name, not a reason to
    // refuse to store one.
    if (action == 'set') return _set(results, requirements);
    if (action == 'import') return _import(results, requirements);

    if (requirements.isEmpty) {
      logger.info(
        'This config declares no credentials. Add signing or targets to '
        'shipway.yaml and they will be listed here.',
      );
      return ShipwayExit.success;
    }

    final resolver = SecretResolver(
      environment: environment.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      flavor: results['flavor'] as String?,
      host: context.host,
    );
    final statuses = await resolver.statuses(requirements);

    if (results['json'] as bool) {
      logger.info(_json(statuses, resolver));
    } else {
      _report(statuses, resolver, checking: action == 'check');
    }

    final blocking = statuses.where((s) => s.blocks).toList();
    if (action == 'check' && blocking.isNotEmpty) {
      return ShipwayExit.environmentError;
    }
    return ShipwayExit.success;
  }

  /// `shipway secrets export` — the names a CI repository needs.
  ///
  /// No value is read, so none can be written. What comes out is a checklist.
  int _export(ShipwayConfig config) {
    final context = _context;
    final secrets = RepositorySecrets.of(config, appId: context.appId);
    context.logger.write(
      SecretExport.render(
        secrets,
        format: ExportFormat.parse(argResults!['format'] as String)!,
      ),
    );
    return ShipwayExit.success;
  }

  /// `shipway secrets set <NAME>` — put one value in the login keychain.
  Future<int> _set(
    ArgResults results,
    List<SecretRequirement> requirements,
  ) async {
    final context = _context;
    final logger = context.logger;

    if (results.rest.length < 2) {
      logger.err('Say which credential to set: `shipway secrets set <NAME>`.');
      if (requirements.isNotEmpty) {
        logger.info(
          'This config asks for: '
          '${requirements.map((r) => r.name).join(', ')}.',
        );
      }
      return ShipwayExit.userError;
    }
    final name = results.rest[1];

    final value = await _valueFor(name, results);
    if (value == null) return ShipwayExit.userError;

    final store = SecretStore(
      runner: context.runner,
      redactor: context.redactor,
      host: context.host,
    );
    try {
      await store.set(name, value);
    } on SecretStoreFailure catch (failure) {
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return context.host.hasSecurityKeychain
          ? ShipwayExit.userError
          : ShipwayExit.environmentError;
    }

    logger.info('Stored $name in the login keychain.');
    if (requirements.isNotEmpty && !requirements.any((r) => r.name == name)) {
      // Not refused: a value may be stored before the config that wants it.
      // But a typo here is silent — the real name still reports missing — so
      // it is worth one line now rather than a puzzled `check` later.
      logger.warn(
        '$name is not one this config asks for. '
        '`shipway secrets list` shows the names it wants.',
      );
    }
    return ShipwayExit.success;
  }

  /// Where a value comes from, in the order the flags allow.
  ///
  /// Null means the reason has already been reported.
  Future<String?> _valueFor(String name, ArgResults results) async {
    final context = _context;
    final logger = context.logger;
    final encode = results['base64'] as bool;
    final fromFile = results['from-file'] as String?;

    if (fromFile != null && (results['stdin'] as bool)) {
      logger.err('Pass either --from-file or --stdin, not both.');
      return null;
    }

    if (fromFile != null) {
      final file = File(
        p.isAbsolute(fromFile)
            ? fromFile
            : p.join(context.projectRoot, fromFile),
      );
      if (!file.existsSync()) {
        logger.err('No such file: $fromFile');
        return null;
      }
      // Encoded from the bytes rather than from text, so a key file survives
      // whatever it happens to contain. `base64` on Linux wraps at 76 columns
      // by default and the wrapped form is not what a lane can decode, which
      // is the reason shipway does this rather than telling you the command.
      return encode
          ? base64.encode(file.readAsBytesSync())
          : file.readAsStringSync().trim();
    }

    if (results['stdin'] as bool) {
      final read = await stdin.transform(utf8.decoder).join();
      return encode ? base64.encode(utf8.encode(read)) : read.trim();
    }

    if (!context.environment.environment.mayPrompt || context.assumeYes) {
      logger.err(
        'Nothing to read the value from, and this run may not prompt.',
      );
      logger.info('Pass --from-file <path> or --stdin.');
      return null;
    }

    final typed = logger.prompt('Value for $name:', hidden: true).trim();
    if (typed.isEmpty) {
      logger.err('Nothing entered, so nothing was stored.');
      return null;
    }
    return encode ? base64.encode(utf8.encode(typed)) : typed;
  }

  /// `shipway secrets import` — move a .env file into the login keychain.
  ///
  /// Nothing already stored is replaced without `--force`: the point of moving
  /// values off disk is not to lose the ones already moved.
  Future<int> _import(
    ArgResults results,
    List<SecretRequirement> requirements,
  ) async {
    final context = _context;
    final logger = context.logger;

    final flavor = results['flavor'] as String?;
    final relative =
        results['from'] as String? ??
        (flavor == null ? '.env' : '.env.$flavor');
    final file = File(
      p.isAbsolute(relative) ? relative : p.join(context.projectRoot, relative),
    );
    if (!file.existsSync()) {
      logger.err('No such file: $relative');
      return ShipwayExit.userError;
    }

    final values = SecretResolver.parseDotenv(file.readAsStringSync());
    if (values.isEmpty) {
      logger.info(
        '$relative holds no assignments, so there was nothing to do.',
      );
      return ShipwayExit.success;
    }

    final store = SecretStore(
      runner: context.runner,
      redactor: context.redactor,
      host: context.host,
    );
    final force = results['force'] as bool;
    final wanted = requirements.map((r) => r.name).toSet();

    var stored = 0;
    var kept = 0;
    final failed = <String, String>{};

    logger.info('');
    for (final entry in values.entries) {
      if (!force && await store.has(entry.key)) {
        kept++;
        logger.info('     kept ${entry.key}');
        continue;
      }
      try {
        await store.set(entry.key, entry.value);
        stored++;
        final note = wanted.isEmpty || wanted.contains(entry.key)
            ? ''
            : '  ${darkGray.wrap('(not asked for by this config)') ?? ''}';
        logger.info('   stored ${entry.key}$note');
      } on SecretStoreFailure catch (failure) {
        failed[entry.key] = failure.message;
        logger.info('  ${red.wrap('skipped') ?? 'skipped'} ${entry.key}');
      }
    }

    logger
      ..info('')
      ..info('$stored stored, $kept already there, ${failed.length} skipped.');
    for (final entry in failed.entries) {
      logger.info('  ${entry.key}: ${entry.value}');
    }
    if (kept > 0 && !force) {
      logger.info('Pass --force to replace the ones already in the keychain.');
    }
    // The file is still on disk, and saying so is the difference between a
    // credential moved and a credential copied.
    logger.info(
      '$relative is unchanged. Delete it once you are satisfied the values '
      'resolve — `shipway secrets check` will say.',
    );

    return failed.isEmpty ? ShipwayExit.success : ShipwayExit.userError;
  }

  void _report(
    List<SecretStatus> statuses,
    SecretResolver resolver, {
    required bool checking,
  }) {
    final context = _context;
    final logger = context.logger;
    final environment = context.environment;

    logger
      ..info('')
      ..info(
        darkGray.wrap(
              'Environment: ${environment.environment.flagName} '
              '(${environment.explanation}). Looking in: '
              '${resolver.chain.map(_sourceLabel).join(' → ')}.',
            ) ??
            '',
      )
      ..info('');

    for (final status in statuses) {
      final label = _label(status);
      logger.info('  $label ${status.name}');

      final detail = status.source.found
          ? '${status.requirement.wantedBy} — found in ${status.detail}'
          : status.requirement.wantedBy;
      logger.info('           ${darkGray.wrap(detail) ?? detail}');

      if (status.source == SecretSource.missingFile) {
        logger.info(
          '           ${red.wrap('names ${status.detail}, which does not exist') ?? ''}',
        );
      }
    }

    final blocking = statuses.where((s) => s.blocks).toList();
    final found = statuses.where((s) => s.source.found).length;

    logger
      ..info('')
      ..info('$found of ${statuses.length} resolved.');

    if (blocking.isEmpty) {
      if (checking) logger.info(green.wrap('Nothing is missing.') ?? '');
      return;
    }

    logger
      ..info('')
      ..err(
        '${blocking.length} required '
        '${blocking.length == 1 ? 'credential is' : 'credentials are'} '
        'missing: ${blocking.map((s) => s.name).join(', ')}',
      );

    // The remedy depends on where you are, because the chain does.
    if (environment.environment.mayPrompt) {
      logger.info(
        'Set them in your environment, or add them to '
        '${resolver.dotenvPath} (git-ignored).',
      );
    } else {
      logger.info(
        'This environment reads only '
        '${resolver.chain.map(_sourceLabel).join(' and ')}, so they must be '
        'provided there — as repository secrets, or in '
        '${resolver.dotenvPath} on the runner.',
      );
    }
  }

  String _label(SecretStatus status) => switch (status.source) {
    final SecretSource s when s.found => green.wrap('    ok') ?? 'ok',
    SecretSource.missingFile => red.wrap('no file') ?? 'no file',
    _ when status.requirement.isRequired => red.wrap('missing') ?? 'missing',
    _ => yellow.wrap('  unset') ?? 'unset',
  };

  static String _sourceLabel(SecretSource source) => switch (source) {
    SecretSource.environment => 'environment',
    SecretSource.dotenv => '.env',
    SecretSource.keychain => 'keychain',
    SecretSource.prompt => 'a prompt',
    _ => source.name,
  };

  String _json(List<SecretStatus> statuses, SecretResolver resolver) {
    final environment = _context.environment;
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'environment': environment.environment.flagName,
      'environmentSource': environment.source.name,
      'chain': resolver.chain.map((s) => s.name).toList(),
      'secrets': <Map<String, dynamic>>[
        for (final status in statuses)
          <String, dynamic>{
            'name': status.name,
            'required': status.requirement.isRequired,
            'wantedBy': status.requirement.wantedBy,
            'source': status.source.name,
            'present': status.source.found,
            'blocks': status.blocks,
          },
      ],
      'blocking': statuses.where((s) => s.blocks).map((s) => s.name).toList(),
    });
  }
}
