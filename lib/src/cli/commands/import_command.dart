import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/config_loader.dart';
import '../../core/managed/lock_file.dart';
import '../../core/model/project_model.dart';
import '../../core/model/uncertainty.dart';
import '../../inspect/config_from_project.dart';
import '../../inspect/config_writer.dart';
import '../../inspect/ios_inspector.dart';
import '../../inspect/project_inspector.dart';
import '../../inspect/xcscheme_reader.dart';
import '../../version.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway import` — derive `shipway.yaml` from an existing project.
///
/// Writes exactly one file and records everything it read as `unmanaged`. That
/// is the whole safety story: running this on a working project cannot break
/// it, and the closing line of the report says so out loud.
class ImportCommand extends Command<int> {
  ImportCommand(this._contextProvider) {
    argParser
      ..addFlag(
        'deep',
        negatable: false,
        help:
            'Ask Gradle for the resolved build model. Slower, but resolves '
            'values the fast parser cannot read.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the derived config without writing anything.',
      )
      ..addOption(
        'out',
        help: 'Where to write the config.',
        valueHelp: 'path',
        defaultsTo: ConfigLoader.defaultFileName,
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing shipway.yaml.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'import';

  @override
  String get description =>
      'Read this project and write a shipway.yaml describing it.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;
    final dryRun = results['dry-run'] as bool;
    final deep = results['deep'] as bool;
    final relativeOut = results['out'] as String;
    final outPath = p.join(context.projectRoot, relativeOut);

    if (!File(p.join(context.projectRoot, 'pubspec.yaml')).existsSync()) {
      logger.err(
        'No pubspec.yaml in ${context.projectRoot}.\n'
        'Run shipway from the root of a Flutter project.',
      );
      return ShipwayExit.userError;
    }

    if (!dryRun &&
        File(outPath).existsSync() &&
        !(results['force'] as bool) &&
        !context.assumeYes) {
      logger.err(
        '$relativeOut already exists.\n'
        'Re-run with --force to overwrite it, or --dry-run to see what import '
        'would produce.',
      );
      return ShipwayExit.userError;
    }

    final progress = logger.progress('Reading project');
    final ProjectModel model;
    try {
      model = await ProjectInspector(
        runner: context.runner,
      ).readFromDisk(context.projectRoot, deep: deep);
      progress.complete('Read project');
    } catch (_) {
      progress.fail('Could not read project');
      rethrow;
    }

    final config = ConfigFromProject.build(model);
    final yaml = ConfigWriter.render(
      config,
      generatedBy: packageVersion,
      generatedAt: context.now,
    );

    if (dryRun) {
      logger
        ..info('')
        ..info(yaml.trimRight());
      _report(model, wrote: null);
      return ShipwayExit.success;
    }

    await File(outPath).writeAsString(yaml);
    await _recordUnmanaged(context.projectRoot, model);

    _report(model, wrote: relativeOut);
    return ShipwayExit.success;
  }

  /// Records every file the readers touched as `unmanaged`.
  ///
  /// Nothing becomes writable here. `shipway adopt` is the only way ownership
  /// changes, and it asks first.
  Future<void> _recordUnmanaged(String root, ProjectModel model) async {
    final lock = await LockFile.load(root);

    void note(String? relative, {WriteMode mode = WriteMode.block}) {
      if (relative == null) return;
      if (!File(p.join(root, relative)).existsSync()) return;
      // Never downgrade a file the user already adopted.
      if (lock.ownershipOf(relative) != Ownership.unmanaged) return;
      // Nor forget that one was disowned.
      if (lock[relative]?.disownedAt != null) return;
      lock.noteUnmanaged(relative, mode: mode);
    }

    note(model.android.buildFilePath);
    note('${IosInspector.projectPath}/project.pbxproj');
    for (final scheme in model.ios.schemes.values) {
      if (!scheme.shared) continue;
      note(
        '${IosInspector.projectPath}/${XcschemeReader.sharedDirectory}/'
        '${scheme.name}.xcscheme',
        mode: WriteMode.full,
      );
    }
    for (final xcconfig in model.ios.xcconfigs.keys) {
      note(xcconfig, mode: WriteMode.full);
    }
    for (final entrypoint in model.dart.entrypoints.values) {
      note(entrypoint.path, mode: WriteMode.full);
    }
    for (final setup in model.fastlane) {
      for (final file in const <String>[
        'Fastfile',
        'Appfile',
        'Matchfile',
        'Pluginfile',
      ]) {
        note('${setup.directory}/$file', mode: WriteMode.full);
      }
    }
    note('.gitignore');

    await lock.save(root);
  }

  /// The reconciliation report.
  void _report(ProjectModel model, {required String? wrote}) {
    final logger = _context.logger;
    logger.info('');

    _reportFlavors(model);
    _reportSecretRefs(model);
    _reportFindings(model);

    logger.info('');
    if (wrote != null) {
      logger
        ..info('${green.wrap('Wrote')} $wrote')
        ..info(
          '${green.wrap('Recorded')} ${LockFile.directoryName}/'
          '${LockFile.fileName} (everything found is marked unmanaged)',
        );
    }
    // Stated plainly, because the whole point of import is that it is safe to
    // run on a project that already works.
    logger.info(
      wrote == null
          ? 'Nothing was written. No project files were modified.'
          : 'No project files were modified.',
    );
  }

  void _reportFlavors(ProjectModel model) {
    final logger = _context.logger;
    final flavors = model.allFlavors.toList()..sort();

    if (flavors.isEmpty) {
      logger.info(
        'No flavors found. shipway derived a single-flavor config from this '
        "project's bundle id and signing setup.",
      );
      return;
    }

    logger.info('Flavors found:');
    for (final flavor in flavors) {
      final platforms = <String>[
        if (model.androidFlavors.contains(flavor)) 'android',
        if (model.iosFlavors.contains(flavor)) 'ios',
      ];
      final entrypoint = model.dart.entrypointFor(flavor);
      final entrypointLabel =
          entrypoint?.path ?? (darkGray.wrap('no entrypoint') ?? '');
      logger.info(
        '  ${flavor.padRight(14)} ${platforms.join(' + ').padRight(16)} '
        '$entrypointLabel',
      );
    }
  }

  void _reportSecretRefs(ProjectModel model) {
    final logger = _context.logger;
    final names = <String>{
      for (final setup in model.fastlane) ...setup.environmentVariables,
    };
    if (names.isEmpty) return;
    final sorted = names.toList()..sort();
    const note =
        '  These are names only. shipway never reads or writes their values.';
    logger
      ..info('')
      ..info('Secret names harvested from your fastlane setup:')
      ..info('  ${sorted.join(', ')}')
      ..info(darkGray.wrap(note) ?? note);
  }

  void _reportFindings(ProjectModel model) {
    final logger = _context.logger;
    if (model.uncertainties.isEmpty) return;

    List<Uncertainty> withSeverity(UncertaintySeverity severity) =>
        model.uncertainties.where((u) => u.severity == severity).toList();

    void section(
      String title,
      List<Uncertainty> items,
      String Function(String) colour,
    ) {
      if (items.isEmpty) return;
      logger
        ..info('')
        ..info(colour(title));
      for (final item in items) {
        logger
          ..info('  ${item.field}')
          ..info('    ${item.reason}')
          ..info('    ${darkGray.wrap(item.remedy) ?? item.remedy}');
      }
    }

    final unresolved = withSeverity(UncertaintySeverity.unresolved);

    section(
      'Problems found in this project:',
      withSeverity(UncertaintySeverity.defect),
      (t) => red.wrap(t) ?? t,
    );
    section(
      'Values shipway could not determine:',
      unresolved,
      (t) => yellow.wrap(t) ?? t,
    );
    section(
      'Notes:',
      withSeverity(UncertaintySeverity.informational),
      (t) => darkGray.wrap(t) ?? t,
    );

    if (unresolved.any((u) => u.deepMayResolve)) {
      logger
        ..info('')
        ..info(
          'Re-run with `--deep` to resolve the values above by asking '
          'Gradle directly.',
        );
    }
  }
}
