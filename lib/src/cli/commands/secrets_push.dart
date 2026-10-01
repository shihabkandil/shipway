import 'package:mason_logger/mason_logger.dart';

import '../../core/config/shipway_config.dart';
import '../../core/env/run_environment.dart';
import '../../secrets/repository_secrets.dart';
import '../../secrets/secret_push.dart';
import '../../secrets/secret_requirements.dart';
import '../../secrets/secret_resolver.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway secrets push` — set this project's CI secrets on its GitHub
/// repository, from the values this machine already has.
///
/// The one secrets action that writes somewhere other people can see, so it
/// says what it is about to do before doing it: which names, read from where,
/// sent to which repository. Nothing is uploaded until that has been agreed
/// to — by a person where there is one, by `--yes` where there is not.
class SecretsPush {
  const SecretsPush(this.context);

  final RunContext context;

  /// Where the values are read, as opposed to where they are going.
  ///
  /// `--env` everywhere else says where shipway is *running*, and so which
  /// sources may be read. A field report reached for `secrets push --env ci`
  /// meaning "the CI secrets", and taken literally that would read only the
  /// process environment — on a laptop, nothing — and report everything
  /// missing. So on this action alone `--env ci` is read as what was meant:
  /// the destination, which is already the only one there is. The source is
  /// then whatever this machine would otherwise be taken for. `--env
  /// workstation` and `--env persistent` cannot name a destination, and keep
  /// their usual meaning.
  static ResolvedEnvironment sourceEnvironment(
    RunContext context,
    ShipwayConfig config,
  ) {
    final flag = context.environmentFlag;
    return EnvironmentDetector.resolve(
      flag: RunEnvironment.parse(flag) == RunEnvironment.ephemeralCi
          ? null
          : flag,
      configured: config.ci.environment,
      environment: context.processEnvironment,
    );
  }

  Future<int> run(
    ShipwayConfig config, {
    required SecretScope scope,
    required bool dryRun,
    String? repository,
    String? flavor,
  }) async {
    final logger = context.logger;

    final secrets = RepositorySecrets.of(
      config,
      appId: context.appId,
      scope: scope,
    );
    if (secrets.isEmpty) {
      logger.info(
        scope.isEverything
            ? 'This config needs no repository secrets yet. Add signing or '
                  'targets to shipway.yaml and they will be pushed from here.'
            : 'Nothing in this config needs a repository secret for '
                  '${scope.label}.',
      );
      return ShipwayExit.success;
    }

    final source = sourceEnvironment(context, config);
    final resolver = SecretResolver(
      environment: source.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      processEnvironment: context.processEnvironment,
      flavor: flavor,
      host: context.host,
    );
    final push = SecretPush(
      resolver: resolver,
      redactor: context.redactor,
      projectRoot: context.projectRoot,
    );
    final gh = GitHubCli(
      runner: context.runner,
      workingDirectory: context.projectRoot,
    );

    final String target;
    try {
      await gh.requireReady();
      target = repository ?? await gh.currentRepository();
    } on GitHubCliFailure catch (failure) {
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return ShipwayExit.environmentError;
    }

    final entries = await push.plan(secrets);
    final ready = entries.where((e) => e.resolved).toList();
    final missing = entries.where((e) => !e.resolved).toList();

    _printPlan(
      entries,
      repository: target,
      scope: scope,
      source: source,
      resolver: resolver,
    );

    if (ready.isEmpty) {
      logger.err(
        'None of the ${entries.length} resolve on this machine, so there is '
        'nothing to push.',
      );
      logger.info('`shipway secrets set <NAME>` stores one in the keychain.');
      return ShipwayExit.environmentError;
    }

    if (dryRun) {
      logger.info('Dry run: nothing was sent to $target.');
      _reportMissing(missing);
      return missing.isEmpty
          ? ShipwayExit.success
          : ShipwayExit.environmentError;
    }

    final count = '${ready.length} ${ready.length == 1 ? 'secret' : 'secrets'}';
    if (!context.assumeYes) {
      if (!source.environment.mayPrompt) {
        logger.err(
          'This would overwrite $count on $target, and this run may not ask '
          'first.',
        );
        logger.info('Pass --yes to go ahead, or --dry-run to only look.');
        return ShipwayExit.userError;
      }
      final agreed = logger.confirm(
        'Set $count on $target? Any that exist there are overwritten.',
      );
      if (!agreed) {
        logger.info('Nothing was sent.');
        return ShipwayExit.userError;
      }
    }

    logger.info('');
    final outcomes = await push.push(
      ready,
      gh: gh,
      repository: target,
      onOutcome: (outcome) => logger.info(
        outcome.ok
            ? '  ${green.wrap('   set') ?? 'set'} ${outcome.entry.name}'
            : '  ${red.wrap('failed') ?? 'failed'} ${outcome.entry.name}: '
                  '${outcome.error}',
      ),
    );

    final failed = outcomes.where((o) => !o.ok).toList();
    logger
      ..info('')
      ..info(
        '${outcomes.length - failed.length} set on $target, '
        '${failed.length} failed, ${missing.length} skipped.',
      );
    _reportMissing(missing);
    return failed.isEmpty && missing.isEmpty
        ? ShipwayExit.success
        : ShipwayExit.environmentError;
  }

  /// Named, by the name to set *here*: the repository's name for a file
  /// secret is not one anybody can set locally.
  void _reportMissing(List<PushEntry> missing) {
    if (missing.isEmpty) return;
    context.logger.err(
      'Not pushed, because they do not resolve on this machine: '
      '${missing.map((e) => e.localName).join(', ')}',
    );
  }

  void _printPlan(
    List<PushEntry> entries, {
    required String repository,
    required SecretScope scope,
    required ResolvedEnvironment source,
    required SecretResolver resolver,
  }) {
    final logger = context.logger;
    final scoped = scope.label == null ? '' : ' for ${scope.label}';
    final chain = resolver.chain
        .where((s) => s != SecretSource.prompt)
        .map(_sourceLabel)
        .join(' → ');

    logger
      ..info('')
      ..info('Repository secrets$scoped → $repository')
      ..info(
        darkGray.wrap(
              'Read on this machine (${source.environment.flagName}, '
              '${source.explanation}) from: $chain.',
            ) ??
            '',
      );
    if (RunEnvironment.parse(context.environmentFlag) ==
            RunEnvironment.ephemeralCi &&
        source.environment != RunEnvironment.ephemeralCi) {
      logger.info(
        darkGray.wrap(
              '--env ci names the destination here, which push always '
              'targets; it does not narrow where values are read.',
            ) ??
            '',
      );
    }
    logger.info('');

    for (final entry in entries) {
      final label = entry.resolved
          ? green.wrap('   push') ?? 'push'
          : red.wrap('missing') ?? 'missing';
      logger.info('  $label ${entry.name}');
      final detail = '${entry.resolved ? 'from ' : ''}${entry.origin}';
      logger.info('          ${darkGray.wrap(detail) ?? detail}');
    }
    logger.info('');
  }

  static String _sourceLabel(SecretSource source) => switch (source) {
    SecretSource.environment => 'environment',
    SecretSource.dotenv => '.env',
    SecretSource.keychain => 'keychain',
    _ => source.name,
  };
}
