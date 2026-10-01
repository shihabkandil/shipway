import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/config/shipway_config.dart';
import '../core/env/machine_memory.dart';
import '../core/fastlane/release_target.dart';
import '../core/gradle/gradle_limits.dart';
import '../core/io/process_runner.dart';
import '../secrets/secret_materialiser.dart';
import '../secrets/secret_requirements.dart';
import '../secrets/secret_resolver.dart';
import 'exit_codes.dart';
import 'run_context.dart';

/// What a build machine needs done before a lane runs, and undone after.
///
/// A generated workflow used to do all of this in YAML: install the gems,
/// write each credential file from a secret, hope the machine was thrown away
/// afterwards. That last part is true of a hosted runner and false of every
/// other machine, and a team moving to a self-hosted Mac found out one
/// hand-edit at a time — a cache to turn off, a `bundle install` to add, a
/// cleanup step for each file.
///
/// Doing it here means the workflow has almost nothing in it to get wrong, and
/// what is written is removed by the thing that wrote it, in a `finally`.
///
/// Off the workstation only. A developer's machine already has its bundle, its
/// key files and a `gradle.properties` sized for it, and none of that is
/// shipway's to rearrange.
class ReleasePreparation {
  ReleasePreparation(this._context);

  final RunContext _context;

  SecretMaterialiser? _materialiser;

  /// Every preparation holding files right now. More than one when a pipeline
  /// releases both platforms at once, and a signal has to reach all of them.
  static final Set<ReleasePreparation> _holdingFiles = <ReleasePreparation>{};
  static final List<StreamSubscription<ProcessSignal>> _signals =
      <StreamSubscription<ProcessSignal>>[];

  bool get _applies => _context.environment.environment.requiresCleanup;

  /// Readies the machine for [target]'s lane, adding to [environment] what the
  /// lane must be run with.
  ///
  /// Returns an exit code when the release cannot go ahead — already
  /// explained to the user — and null when it can.
  Future<int?> prepare({
    required ShipwayConfig config,
    required ReleaseTarget target,
    required String flavor,
    required Map<String, String> environment,
  }) async {
    if (!_applies) return null;

    final secrets = await _materialise(config, target, flavor, environment);
    if (secrets != null) return secrets;

    final bundle = await _installBundle(target);
    if (bundle != null) return bundle;

    if (target.platform == 'android') await _limitGradle(environment);
    return null;
  }

  /// Removes every file [prepare] wrote. Runs whatever the release did.
  Future<void> cleanUp() async {
    _materialiser?.cleanUp();
    _materialiser = null;
    _holdingFiles.remove(this);
    if (_holdingFiles.isEmpty) {
      for (final subscription in _signals) {
        await subscription.cancel();
      }
      _signals.clear();
    }
  }

  Future<int?> _materialise(
    ShipwayConfig config,
    ReleaseTarget target,
    String flavor,
    Map<String, String> environment,
  ) async {
    final context = _context;
    final logger = context.logger;
    final resolver = SecretResolver(
      environment: context.environment.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      processEnvironment: context.processEnvironment,
      flavor: flavor,
      host: context.host,
    );
    final materialiser = _materialiser = SecretMaterialiser(
      projectRoot: context.projectRoot,
      read: resolver.read,
      baseDirectory: SecretMaterialiser.baseDirectoryFor(
        context.processEnvironment,
      ),
    );

    // The same derivation the pre-flight used, so what is written is exactly
    // what was just reported as satisfiable.
    final paths = SecretRequirements.of(
      config,
      environment: context.environment.environment,
      appId: context.appId,
      flavor: flavor,
    ).where((r) => r.isPath && r.appliesTo(target.id)).map((r) => r.name);

    try {
      // Registered before anything is written, so there is no moment at which
      // a file exists and a cancelled job would leave it.
      _watchSignals();
      environment.addAll(await materialiser.pathVariables(paths));
      if (target.platform == 'android') {
        await materialiser.androidSigning(
          config.appOrNull(context.appId)?.signing.android,
        );
      }
    } on MaterialisationFailure catch (failure) {
      logger
        ..err(failure.what)
        ..info('  ${failure.fix}');
      return ShipwayExit.environmentError;
    } on FileSystemException catch (failure) {
      logger
        ..err('Could not write a credential file: ${failure.message}')
        ..info('  ${failure.path ?? materialiser.baseDirectory}');
      return ShipwayExit.environmentError;
    }

    final written = materialiser.written;
    if (written.isNotEmpty) {
      // Names, never contents — and on a build machine the names are worth
      // having in the log, because they are what to look for if a run is ever
      // killed hard enough to leave them.
      logger.detail(
        'Wrote ${written.length} credential '
        'file${written.length == 1 ? '' : 's'} for this run: '
        '${written.join(', ')}',
      );
    }
    return null;
  }

  /// `bundle install`, when the bundle is not already satisfied.
  ///
  /// A hosted workflow's `bundler-cache` did this as a side effect of caching.
  /// With no cache action there is nothing to do it, and the failure is a
  /// lane that cannot find fastlane. `bundle check` first, because on a
  /// machine that keeps its gems the answer is nearly always "already there"
  /// and that costs a second rather than a resolve.
  Future<int?> _installBundle(ReleaseTarget target) async {
    final context = _context;
    final logger = context.logger;
    final directory = p.join(context.projectRoot, target.platform);
    // No Gemfile is the toolchain probe's to report, with what to run.
    if (!File(p.join(directory, 'Gemfile')).existsSync()) return null;

    final check = await context.runner.run('bundle', const <String>[
      'check',
    ], workingDirectory: directory);
    // No bundler at all is the probe's to report too.
    if (check.ok || check.notFound) return null;

    logger.info(
      'The bundle in ${target.platform}/ is not installed. Running '
      '`bundle install`.',
    );
    final prefix = darkGray.wrap('bundle │ ') ?? '';
    final tail = <String>[];
    try {
      await for (final line in context.runner.stream('bundle', const <String>[
        'install',
        '--retry',
        '3',
      ], workingDirectory: directory)) {
        logger.detail('$prefix$line');
        tail.add(line);
        if (tail.length > 20) tail.removeAt(0);
      }
    } on ProcessExitException catch (failure) {
      logger.err(
        '`bundle install` failed in ${target.platform}/ '
        '(exit ${failure.exitCode}).',
      );
      // Shown at `detail` while it ran, so without --verbose the reason would
      // otherwise be nowhere.
      for (final line in tail) {
        logger.info('  $line');
      }
      return ShipwayExit.environmentError;
    }
    return null;
  }

  Future<void> _limitGradle(Map<String, String> environment) async {
    final context = _context;
    final total = await MachineMemory.totalBytes(
      context.runner,
      host: context.host,
    );
    final limits = GradleLimits.forMemory(total);
    environment.addAll(
      limits.environment(
        existing:
            environment[GradleLimits.gradleOptsVariable] ??
            context.processEnvironment[GradleLimits.gradleOptsVariable],
      ),
    );
    context.logger.info(
      limits.memoryKnown
          ? 'Gradle is limited to ${limits.summary}: this machine has '
                '${(total! / (1024 * 1024 * 1024)).toStringAsFixed(0)} GB.'
          : 'Gradle is limited to ${limits.summary}: shipway could not read '
                'how much memory this machine has.',
    );
  }

  /// A job cancelled from the GitHub UI is sent SIGINT, then SIGTERM. Neither
  /// runs a `finally`, so both are caught and the files removed first.
  void _watchSignals() {
    _holdingFiles.add(this);
    if (_signals.isNotEmpty) return;
    for (final signal in <ProcessSignal>[
      ProcessSignal.sigint,
      ProcessSignal.sigterm,
    ]) {
      try {
        _signals.add(
          signal.watch().listen((received) {
            for (final preparation in _holdingFiles.toList()) {
              preparation._materialiser?.cleanUp();
            }
            // The conventional code for "ended by this signal".
            exit(128 + (received == ProcessSignal.sigint ? 2 : 15));
          }),
        );
      } on SignalException {
        // Not watchable on this platform. The `finally` still covers every
        // ending that is not a signal.
      }
    }
  }
}
