import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/managed/lock_file.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway disown <path>` — hand a file shipway writes back to you.
///
/// The inverse of `adopt`, and the way to keep a hand edit to a generated
/// file. A field report added a lane to a generated Fastfile and could not
/// tell whether the next `generate` would overwrite it, or how to say it
/// should not.
///
/// Deliberately not an "accept this edit" command. Recording the edited file
/// as shipway's own baseline would make the next `generate` see no edit, and
/// overwrite it without a word the moment `shipway.yaml` changed. Handing the
/// file back is the only answer that keeps the edit.
class DisownCommand extends Command<int> {
  DisownCommand(this._contextProvider) {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Say what would change without recording anything.',
    );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'disown';

  @override
  String get description =>
      'Stop shipway writing to a file, and keep it exactly as it is.';

  @override
  String get invocation => 'shipway disown <path>';

  @override
  Future<int> run() async {
    final context = _context;
    final logger = context.logger;
    final dryRun = argResults!['dry-run'] as bool;

    if (argResults!.rest.isEmpty) {
      logger.err('Say which file: `shipway disown <path>`.');
      return ShipwayExit.userError;
    }
    final path = p.posix.normalize(
      argResults!.rest.first.replaceAll(r'\', '/'),
    );

    final lock = await context.loadLockFile();
    final entry = lock[path];
    if (entry == null || entry.ownership == Ownership.unmanaged) {
      logger.info(
        entry?.disownedAt != null
            ? '$path is already yours.'
            : 'shipway does not write to $path, so there is nothing to disown.',
      );
      return ShipwayExit.success;
    }

    if (!dryRun) {
      lock.record(
        LockEntry(
          path: path,
          ownership: Ownership.unmanaged,
          mode: entry.mode,
          disownedAt: context.now,
        ),
      );
      await lock.save(context.projectRoot);
    }

    logger.info(
      '${dryRun ? 'Would hand' : 'Handed'} $path back to you. '
      '`shipway generate` will leave it alone from now on.',
    );
    if (entry.mode == WriteMode.block) {
      logger.info(
        '  Its shipway markers are still there. Nothing reads them now, so '
        'delete them if you like.',
      );
    }
    logger.info('  `shipway adopt $path` hands it back to shipway.');
    return ShipwayExit.success;
  }
}
