import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/managed/content_hash.dart';
import '../../core/managed/lock_file.dart';
import '../../core/managed/managed_block.dart';
import '../../core/model/android_model.dart';
import '../../core/model/model_diff.dart';
import '../../core/model/project_comparison.dart';
import '../../generators/generated_file.dart';
import '../../generators/generated_file_writer.dart';
import '../../generators/generator_registry.dart';
import '../../inspect/project_from_config.dart';
import '../../inspect/project_inspector.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway adopt` — hand a file shipway does not own over to it.
///
/// The bridge between the two directions, and the only way an `unmanaged` file
/// becomes writable. It shows a semantic diff first, because the config was
/// *derived* from the project: an unforced difference here usually means a
/// reader is wrong, not that the project is.
class AdoptCommand extends Command<int> {
  AdoptCommand(this._contextProvider) {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Show what adopting would change without recording anything.',
    );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  /// Whether any file was refused because generating it would break the
  /// build. Set while adopting, read for the exit code.
  bool _refused = false;

  @override
  String get name => 'adopt';

  @override
  String get description =>
      'Let shipway write to a file that was here before it.';

  @override
  String get invocation => 'shipway adopt <path|all>';

  @override
  Future<int> run() async {
    final context = _context;
    final logger = context.logger;
    final dryRun = argResults!['dry-run'] as bool;
    _refused = false;

    if (argResults!.rest.isEmpty) {
      logger.err(
        'Say what to adopt: a path, or `all`.\n'
        'Run `shipway generate --dry-run` to see which files are blocked.',
      );
      return ShipwayExit.userError;
    }
    final target = argResults!.rest.first;

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final candidates = <GeneratedFile>[
      for (final generator in GeneratorRegistry.all) ...generator.render(app),
    ];

    final wanted = target == 'all'
        ? candidates
        : candidates.where((f) => f.path == target).toList();

    if (wanted.isEmpty) {
      logger.err(
        'shipway does not generate "$target", so there is nothing to adopt.\n'
        'It manages: ${candidates.map((f) => f.path).join(', ')}',
      );
      return ShipwayExit.userError;
    }

    final lock = await context.loadLockFile();
    final adoptable = <GeneratedFile>[];
    for (final file in wanted) {
      if (!File(p.join(context.projectRoot, file.path)).existsSync()) continue;
      if (lock.ownershipOf(file.path) != Ownership.unmanaged) continue;
      adoptable.add(file);
    }

    if (adoptable.isEmpty) {
      logger.info(
        target == 'all'
            ? 'Nothing to adopt: shipway already owns every file it manages '
                  'that exists here.'
            : '$target is already owned by shipway, or does not exist yet.',
      );
      return ShipwayExit.success;
    }

    await _showSemanticDiff();

    var adopted = 0;
    for (final file in adoptable) {
      if (await _adoptOne(file, lock, dryRun: dryRun)) adopted++;
    }

    if (!dryRun && adopted > 0) await lock.save(context.projectRoot);

    logger.info('');
    if (dryRun) {
      logger.info('Nothing was written. Re-run without --dry-run to adopt.');
    } else {
      logger
        ..info('Adopted $adopted file${adopted == 1 ? '' : 's'}.')
        ..info(
          adopted == 0
              ? 'Nothing changed.'
              : 'shipway may now write to '
                    '${adopted == 1 ? 'it' : 'them'}. Run `shipway generate`.',
        );
    }
    // A refusal is a decision somebody has to make, like a conflict.
    return _refused ? ShipwayExit.userError : ShipwayExit.success;
  }

  /// Shows how the config and the project disagree, before any file changes.
  ///
  /// Semantic rather than textual, and shown once for the whole adoption: the
  /// question a user needs answered is "do these describe the same app", not
  /// "which bytes differ".
  Future<void> _showSemanticDiff() async {
    final context = _context;
    final logger = context.logger;

    final actual = await ProjectInspector(
      runner: context.runner,
    ).readFromDisk(context.projectRoot);
    final expected = ProjectFromConfig.build(
      await context.requireConfig(),
      root: context.projectRoot,
      appId: context.appId,
      gradleDsl: actual.android.gradleDsl ?? GradleDsl.kotlin,
    );
    final diff = compare(expected, actual);

    logger.info('');
    if (diff.isEmpty) {
      logger.info(
        '${green.wrap('shipway.yaml already describes this project exactly.')} '
        'Adopting changes no file content.',
      );
      return;
    }

    final headline =
        'shipway.yaml and this project disagree in ${diff.length} '
        'place${diff.length == 1 ? '' : 's'}:';
    logger.info(yellow.wrap(headline) ?? headline);
    for (final change in diff.changes) {
      logger.info('  ${_glyph(change.kind)} ${change.describe()}');
    }
    logger
      ..info('')
      ..info(
        darkGray.wrap(
              'shipway.yaml was derived from this project, so a difference '
              'here usually means a reader got something wrong rather than '
              'that your project is wrong. Prefer editing shipway.yaml to '
              'match reality over letting `generate` change your build.',
            ) ??
            '',
      );
  }

  /// Wraps the existing region in markers and records ownership.
  ///
  /// Adoption is a no-op on file content in the common case: if what is there
  /// already matches what shipway would write, only the markers appear.
  Future<bool> _adoptOne(
    GeneratedFile file,
    LockFile lock, {
    required bool dryRun,
  }) async {
    final context = _context;
    final logger = context.logger;
    final target = File(p.join(context.projectRoot, file.path));
    final current = await target.readAsString();

    // Plan against a lock that already grants ownership, so the writer reports
    // the content change adoption would enable rather than the conflict it is
    // about to resolve.
    final provisional = LockFile.empty()
      ..record(
        LockEntry(
          path: file.path,
          ownership: Ownership.adopted,
          mode: file.mode,
        ),
      );
    final planned = await GeneratedFileWriter(
      root: context.projectRoot,
      lock: provisional,
    ).plan(file);

    logger.info('');
    logger.info(cyan.wrap(file.path) ?? file.path);

    // Handing over a file that `generate` would then break is not a favour.
    if (planned.outcome == WriteOutcome.conflictContent) {
      _refused = true;
      logger
        ..err('  ${planned.reason}')
        ..info('  ${planned.remedy}')
        ..info('  Not adopted.');
      return false;
    }

    if (planned.outcome == WriteOutcome.unchanged) {
      logger.info('  Already matches what shipway would write.');
    } else if (planned.diff.isNotEmpty) {
      logger.info('  `shipway generate` would change it:');
      for (final line in planned.diff.trimRight().split('\n')) {
        logger.info('    ${darkGray.wrap(line) ?? line}');
      }
    }

    if (!context.assumeYes && !dryRun) {
      final ok = logger.confirm(
        '  Let shipway write to it?',
        defaultValue: true,
      );
      if (!ok) {
        logger.info('  Skipped.');
        return false;
      }
    }
    if (dryRun) return true;

    // Adoption records ownership; it does not rewrite content. `generate` is
    // what changes the file, and only once the user has seen this diff.
    lock.record(
      LockEntry(
        path: file.path,
        ownership: Ownership.adopted,
        mode: file.mode,
        hash: ContentHash.of(current),
        blockHash: file.mode == WriteMode.block
            ? _existingBlockHash(current)
            : ContentHash.of(current),
        adoptedAt: context.now,
      ),
    );
    return true;
  }

  /// Hash of an existing managed block, when the file already has one.
  ///
  /// Null when there is no block yet: there is nothing of ours for the user to
  /// have edited, so the next write must not be treated as a conflict.
  static String? _existingBlockHash(String current) {
    final block = ManagedBlock.find(current);
    return block == null ? null : ContentHash.of(block.body);
  }

  static String _glyph(ChangeKind kind) => switch (kind) {
    ChangeKind.onlyInProject => yellow.wrap('+') ?? '+',
    ChangeKind.onlyInConfig => yellow.wrap('-') ?? '-',
    ChangeKind.different => yellow.wrap('~') ?? '~',
  };
}
