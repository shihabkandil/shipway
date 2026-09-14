import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../generators/generated_file.dart';
import '../../generators/generated_file_writer.dart';
import '../../core/model/project_model.dart';
import '../../generators/generator_registry.dart';
import '../../generators/orphan_sweep.dart';
import '../../inspect/xcodeproj_bridge.dart';
import '../../platform/ios/info_plist_mutator.dart';
import '../../platform/ios/legacy_xcconfig_cleanup.dart';
import '../../platform/ios/xcode_project_mutator.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway generate` — config to files.
///
/// Refuses to touch anything shipway does not own. That refusal is the feature:
/// on a real project the Gradle build file and the Xcode project were there
/// first, and generating over them would replace a working build.
class GenerateCommand extends Command<int> {
  GenerateCommand(this._contextProvider) {
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would change without writing anything.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Overwrite content you have edited inside a shipway block. '
            'Never overrides an unadopted file.',
      )
      ..addFlag(
        'prune',
        defaultsTo: true,
        help:
            'Remove files shipway generated that the config no longer '
            'describes. Never touches one you have edited.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'generate';

  @override
  String get description => 'Write the files shipway.yaml describes.';

  @override
  String get invocation =>
      'shipway generate [${GeneratorRegistry.groups.keys.join('|')}]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;
    final dryRun = results['dry-run'] as bool;
    final force = results['force'] as bool;

    final selector = results.rest.isEmpty ? 'all' : results.rest.first;
    final generators = GeneratorRegistry.select(selector);
    if (generators == null) {
      logger.err(
        'Unknown generator "$selector". '
        'Try one of: ${GeneratorRegistry.names.join(', ')}',
      );
      return ShipwayExit.userError;
    }

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final files = <GeneratedFile>[
      for (final generator in generators) ...generator.render(app),
    ];
    if (files.isEmpty) {
      logger.info(
        'Nothing to generate. This config declares no flavors, so there are '
        'no per-flavor files to write.',
      );
      return ShipwayExit.success;
    }

    final lock = await context.loadLockFile();
    final writer = GeneratedFileWriter(
      root: context.projectRoot,
      lock: lock,
      force: force,
    );

    final results_ = <WriteResult>[];
    for (final file in files) {
      results_.add(dryRun ? await writer.plan(file) : await writer.write(file));
    }

    // Swept before the lock is saved, so one write covers both. `files` rather
    // than the write results: a generator declaring a file it then skips —
    // create-once scaffolding — has still claimed it, and it is not an orphan.
    final sweep = await OrphanSweep.run(
      root: context.projectRoot,
      lock: lock,
      app: app,
      generators: generators,
      produced: files.map((f) => f.path),
      appCount: config.apps.length,
      dryRun: dryRun,
      enabled: results['prune'] as bool,
    );

    if (!dryRun &&
        (results_.any((r) => r.outcome.changesFile) || !sweep.isEmpty)) {
      await lock.save(context.projectRoot);
    }

    final exit = _report(results_, sweep: sweep, dryRun: dryRun);

    // The Xcode project is mutated after the generators, because the schemes
    // they write name the build configurations this creates. Skipped when
    // anything was blocked: half-configuring a project is worse than not
    // touching it.
    if (_touchesIos(generators) && app.hasFlavors) {
      final mutation = await _configureXcodeProject(
        app,
        dryRun: dryRun,
        skipped: exit != ShipwayExit.success,
      );
      if (mutation != null && !mutation.succeeded) {
        return ShipwayExit.environmentError;
      }
    }

    return exit;
  }

  /// True when the selected generators include anything iOS-shaped.
  bool _touchesIos(List<Generator> generators) =>
      generators.any((g) => g.name == 'ios-schemes');

  /// Creates the `<BuildType>-<flavor>` configurations, points Info.plist at
  /// the display-name build setting, and adds the Firebase copy step — backing
  /// up and restoring both files around the change.
  Future<MutationResult?> _configureXcodeProject(
    ResolvedApp app, {
    required bool dryRun,
    required bool skipped,
  }) async {
    final context = _context;
    final logger = context.logger;

    final plistMutator = InfoPlistMutator(
      runner: context.runner,
      root: context.projectRoot,
    );

    // Seeding the unflavored build types with the plist's current literal is a
    // one-time migration. Once the plist references APP_DISPLAY_NAME the
    // literal is gone, and re-deriving it every run would both be wrong — the
    // package name is not the display name — and overwrite a value the user may
    // since have changed.
    final plistAlreadyConfigured = await plistMutator.isConfigured();
    final baseDisplayName = plistAlreadyConfigured
        ? null
        : (await plistMutator.readDisplayName() ?? app.projectName);

    final configurations = <DesiredConfiguration>[
      if (baseDisplayName != null)
        for (final buildType in flutterBuildTypes)
          DesiredConfiguration(
            name: buildType,
            basedOn: buildType,
            buildSettings: <String, String>{
              InfoPlistMutator.displayNameSetting: baseDisplayName,
            },
          ),
      ...XcodeProjectMutator.configurationsFor(
        app.flavors.map((f) => f.name),
        bundleIdFor: (flavor) => app.flavor(flavor)?.iosBundleId,
        displayNameFor: (flavor) =>
            app.flavor(flavor)?.displayNameOr(app.projectName),
        teamId: app.iosTeamId,
      ),
    ];

    if (dryRun) {
      final flavored = configurations
          .where((c) => c.name.contains('-'))
          .toList();
      logger
        ..info('')
        ..info('Xcode project:')
        ..info(
          '  would ensure ${flavored.length} build '
          'configuration${flavored.length == 1 ? '' : 's'}: '
          '${flavored.map((c) => c.name).join(', ')}',
        );
      if (!plistAlreadyConfigured) {
        logger.info(
          '  would point ${InfoPlistMutator.plistPath} '
          '${InfoPlistMutator.displayNameKey} at '
          '${InfoPlistMutator.displayNameReference}, so each flavor gets its '
          'own name on the home screen',
        );
      }
      return null;
    }

    if (skipped) {
      logger
        ..info('')
        ..info(
          'Skipped the Xcode project: something above is blocked, and '
          'half-configuring it is worse than leaving it alone.',
        );
      return null;
    }

    final scriptPath = XcodeprojBridge.locateScript();
    if (scriptPath == null) {
      logger.err(
        'shipway could not find its own Xcode bridge. This is a packaging '
        'bug, not a problem with your project.',
      );
      return const MutationResult(
        changed: false,
        changes: <String>[],
        failureReason: 'bridge missing',
      );
    }

    final progress = logger.progress('Configuring Xcode project');
    final mutation =
        await XcodeProjectMutator(
          runner: context.runner,
          scriptPath: scriptPath,
          root: context.projectRoot,
        ).configure(
          configurations: configurations,
          firebasePlists: _firebasePlists(app),
        );

    if (!mutation.succeeded) {
      progress.fail('Could not configure the Xcode project');
      logger.err(mutation.failureReason!);
      final remedy = mutation.failureRemedy;
      if (remedy != null) logger.info(remedy);
      logger.info(
        mutation.restored
            ? 'project.pbxproj was restored'
                  '${mutation.backupPath == null ? '' : '; a copy is at '
                            '${mutation.backupPath}'}.'
            : 'project.pbxproj could NOT be restored automatically. '
                  'Recover it from ${mutation.backupPath ?? 'version control'}.',
      );
      return mutation;
    }

    // Only after the build settings exist, so the plist never references a
    // setting nothing defines.
    final plist = await plistMutator.pointDisplayNameAtBuildSetting();
    if (!plist.succeeded) {
      progress.fail('Could not update Info.plist');
      logger.err(plist.failureReason!);
      final remedy = plist.failureRemedy;
      if (remedy != null) logger.info(remedy);
      return MutationResult(
        changed: mutation.changed,
        changes: mutation.changes,
        failureReason: plist.failureReason,
      );
    }

    final total = mutation.changes.length + (plist.changed ? 1 : 0);
    progress.complete(
      total == 0
          ? 'Xcode project already configured'
          : 'Configured Xcode project ($total change'
                '${total == 1 ? '' : 's'})',
    );
    if (plist.changed) {
      logger.info(
        '  ${InfoPlistMutator.plistPath} now uses '
        '${InfoPlistMutator.displayNameReference}; unflavored builds keep '
        '"${baseDisplayName ?? app.projectName}".',
      );
    }

    await _cleanUpLegacyXcconfigs(app);
    return mutation;
  }

  /// Deletes the per-flavor xcconfigs an earlier shipway attached to the
  /// flavored configurations, now that they are pointed back at the stock ones.
  Future<void> _cleanUpLegacyXcconfigs(ResolvedApp app) async {
    final context = _context;
    final logger = context.logger;
    final lock = await context.loadLockFile();

    final result = await LegacyXcconfigCleanup.run(
      root: context.projectRoot,
      lock: lock,
      flavors: app.flavors.map((f) => f.name),
    );
    if (result.isEmpty) return;

    if (result.removed.isNotEmpty) {
      await lock.save(context.projectRoot);
      logger.info(
        '  removed ${result.removed.join(', ')} — a flavor configuration now '
        'inherits the same xcconfig its build type uses, so these were doing '
        'nothing.',
      );
    }
    for (final path in result.kept) {
      logger.info(
        '  $path is no longer referenced by any build configuration. shipway '
        'left it alone because you have edited it.',
      );
    }
  }

  /// Which plist each configuration should copy, keyed by configuration name.
  Map<String, String> _firebasePlists(ResolvedApp app) {
    final plists = <String, String>{};
    for (final flavor in app.flavors) {
      final plist = flavor.firebaseIos;
      if (plist == null) continue;
      for (final configuration in flavor.iosConfigurations) {
        plists[configuration] = plist;
      }
    }
    return plists;
  }

  int _report(
    List<WriteResult> results, {
    required SweepReport sweep,
    required bool dryRun,
  }) {
    final logger = _context.logger;
    logger.info('');

    for (final result in results) {
      logger.info('  ${_label(result, dryRun: dryRun)} ${result.path}');
      final description = result.file.description;
      if (description != null && result.outcome != WriteOutcome.unchanged) {
        logger.info('           ${darkGray.wrap(description) ?? description}');
      }
      final reason = result.reason;
      if (reason != null) {
        logger.info('           $reason');
        final remedy = result.remedy;
        if (remedy != null) {
          logger.info('           ${darkGray.wrap(remedy) ?? remedy}');
        }
      }
      if (dryRun && _context.verbose && result.diff.isNotEmpty) {
        for (final line in result.diff.trimRight().split('\n')) {
          logger.info('           ${darkGray.wrap(line) ?? line}');
        }
      }
    }

    for (final orphan in sweep.results) {
      final label = orphan.outcome.isRemoval
          ? (dryRun ? ' remove' : 'removed')
          : (dryRun ? 'release' : 'release');
      final colour = orphan.outcome.isRemoval ? red : yellow;
      logger
        ..info('  ${colour.wrap(label) ?? label} ${orphan.path}')
        ..info('           ${darkGray.wrap(orphan.detail) ?? orphan.detail}');
    }

    if (sweep.skipped == SweepSkipReason.monorepo) {
      logger.info(
        darkGray.wrap(
              '  Skipped cleanup: this config declares more than one app, and '
              'generated paths are not app-scoped yet.',
            ) ??
            '',
      );
    }

    final conflicts = results.where((r) => r.outcome.isConflict).toList();
    final failures = results
        .where((r) => r.outcome == WriteOutcome.failed)
        .toList();
    final changed = results.where((r) => r.outcome.changesFile).length;
    final unchanged = results
        .where((r) => r.outcome == WriteOutcome.unchanged)
        .length;

    logger.info('');
    if (dryRun) {
      logger.info(
        '$changed to write, $unchanged already correct'
        '${conflicts.isEmpty ? '' : ', ${conflicts.length} blocked'}'
        '${sweep.isEmpty ? '' : ', ${sweep.results.length} to clean up'}.',
      );
      if (!_context.verbose && results.any((r) => r.diff.isNotEmpty)) {
        logger.info(
          darkGray.wrap('Re-run with --verbose to see the diffs.') ?? '',
        );
      }
      logger.info('Nothing was written.');
    } else {
      logger.info(
        '$changed written, $unchanged unchanged'
        '${conflicts.isEmpty ? '' : ', ${conflicts.length} blocked'}'
        '${sweep.isEmpty ? '' : ', ${sweep.results.length} cleaned up'}.',
      );
    }

    if (conflicts.isNotEmpty) {
      final unadopted = conflicts
          .where((c) => c.outcome == WriteOutcome.conflictUnmanaged)
          .toList();
      logger.info('');
      if (unadopted.isNotEmpty) {
        logger.info(
          '${yellow.wrap('Blocked')} — shipway does not own '
          '${unadopted.length} of these files.',
        );
        logger.info(
          'Run `shipway adopt ${unadopted.length == 1 ? unadopted.single.path : 'all'}` '
          'to review the difference and hand them over.',
        );
      }
      // A conflict is a decision the user has to make, so it is a user error
      // rather than a silent partial success.
      return ShipwayExit.userError;
    }

    if (failures.isNotEmpty) return ShipwayExit.environmentError;
    return ShipwayExit.success;
  }

  String _label(WriteResult result, {required bool dryRun}) =>
      switch (result.outcome) {
        WriteOutcome.create =>
          green.wrap(dryRun ? '  create' : ' created') ?? 'create',
        WriteOutcome.update =>
          green.wrap(dryRun ? '  update' : ' updated') ?? 'update',
        WriteOutcome.unchanged => darkGray.wrap('    skip') ?? 'skip',
        WriteOutcome.conflictUnmanaged => yellow.wrap('conflict') ?? 'conflict',
        WriteOutcome.conflictEdited => yellow.wrap('  edited') ?? 'edited',
        WriteOutcome.conflictContent => yellow.wrap('conflict') ?? 'conflict',
        WriteOutcome.failed => red.wrap('  failed') ?? 'failed',
        WriteOutcome.declined => darkGray.wrap('   yours') ?? 'yours',
      };
}
