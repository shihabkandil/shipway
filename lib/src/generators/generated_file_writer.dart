import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/managed/content_hash.dart';
import '../core/managed/lock_file.dart';
import '../core/managed/managed_block.dart';
import '../core/managed/text_diff.dart';
import '../core/gradle/gradle_scanner.dart';
import 'generated_file.dart';
import 'write_guards.dart';

/// What writing one file would do, or did.
enum WriteOutcome {
  /// The file did not exist and would be created.
  create,

  /// The file exists and its managed content would change.
  update,

  /// Already exactly right.
  unchanged,

  /// shipway does not own this file. Requires `shipway adopt`.
  conflictUnmanaged,

  /// shipway owns it, but the user edited the part shipway owns.
  conflictEdited,

  /// Writing it would leave the project unable to build — a flavor declared
  /// twice, a function the generated code calls that nothing defines.
  conflictContent,

  /// The file could not be written for a reason shipway cannot resolve.
  failed;

  bool get isConflict =>
      this == WriteOutcome.conflictUnmanaged ||
      this == WriteOutcome.conflictEdited ||
      this == WriteOutcome.conflictContent;

  bool get changesFile =>
      this == WriteOutcome.create || this == WriteOutcome.update;
}

/// The result of planning or performing one file write.
class WriteResult {
  const WriteResult({
    required this.file,
    required this.outcome,
    this.diff = '',
    this.reason,
    this.remedy,
  });

  final GeneratedFile file;
  final WriteOutcome outcome;

  /// Unified diff of what would change, empty when nothing would.
  final String diff;

  /// Why this is a conflict or a failure.
  final String? reason;

  /// The single next action.
  final String? remedy;

  String get path => file.path;
}

/// Writes generated files, and is the only thing that decides whether shipway
/// is allowed to.
///
/// Every generator funnels through here so ownership, hashing, marker
/// placement, diffing and `--force` are implemented once. A generator can be
/// wrong about content; only this class can be wrong about safety.
class GeneratedFileWriter {
  GeneratedFileWriter({
    required this.root,
    required this.lock,
    this.force = false,
  });

  final String root;
  final LockFile lock;

  /// Overwrite content the user edited inside shipway's own region.
  ///
  /// Never overrides [Ownership.unmanaged]: an unowned file requires an
  /// explicit `shipway adopt`, not a flag, because `--force` is typed in a
  /// hurry and adoption is a decision.
  final bool force;

  /// Works out what would happen, without touching the disk.
  Future<WriteResult> plan(GeneratedFile file) async {
    final target = File(p.join(root, file.path));
    final ownership = lock.ownershipOf(file.path);

    // Before anything else: a file that would not compile is not worth
    // planning, whoever owns it.
    final guarded = file.createOnly ? null : file.guard?.check(root);
    if (guarded != null) {
      return WriteResult(
        file: file,
        outcome: WriteOutcome.conflictContent,
        reason: guarded.reason,
        remedy: guarded.remedy,
      );
    }

    if (!target.existsSync()) {
      if (file.mode == WriteMode.block && file.anchor != null) {
        // A block belongs inside a structure that does not exist yet, so there
        // is nothing to anchor to.
        return WriteResult(
          file: file,
          outcome: WriteOutcome.failed,
          reason:
              '${file.path} does not exist, so shipway cannot insert into '
              'its `${file.anchor!.insideBlock}` block.',
          remedy:
              'Run `flutter create .` to generate the platform folders '
              'first.',
        );
      }
      return WriteResult(
        file: file,
        outcome: WriteOutcome.create,
        diff: TextDiff.unified('', _wholeFileFor(file, '')),
      );
    }

    final current = await target.readAsString();

    // Scaffolding exists to be edited. Once it is there, shipway is done with
    // it — even asking about a conflict would be wrong.
    if (file.createOnly) {
      return WriteResult(file: file, outcome: WriteOutcome.unchanged);
    }

    if (ownership == Ownership.unmanaged) {
      // The single most likely real-project collision. It must be an explicit,
      // actionable error rather than a duplicated block or a silent overwrite.
      return WriteResult(
        file: file,
        outcome: WriteOutcome.conflictUnmanaged,
        diff: TextDiff.unified(current, _wholeFileFor(file, current)),
        reason: '${file.path} was here before shipway and it does not own it.',
        remedy:
            'Run `shipway adopt ${file.path}` to review the difference and '
            'hand it over.',
      );
    }

    final blockers = _reconcile(file, current).blockers;
    if (blockers.isNotEmpty) {
      return WriteResult(
        file: file,
        outcome: WriteOutcome.conflictContent,
        reason: blockers.map((b) => b.reason).join('\n'),
        remedy: blockers.first.remedy,
      );
    }

    final proposed = _wholeFileFor(file, current);
    if (proposed == current) {
      return WriteResult(file: file, outcome: WriteOutcome.unchanged);
    }

    final edited = _userEditedOurContent(file, current);
    if (edited && !force) {
      return WriteResult(
        file: file,
        outcome: WriteOutcome.conflictEdited,
        diff: TextDiff.unified(current, proposed),
        reason: file.mode == WriteMode.full
            ? '${file.path} has been edited since shipway wrote it.'
            : 'the shipway block in ${file.path} has been edited since '
                  'shipway wrote it.',
        remedy:
            'Re-run with --force to discard those edits, or move them '
            'outside the managed block.',
      );
    }

    return WriteResult(
      file: file,
      outcome: WriteOutcome.update,
      diff: TextDiff.unified(current, proposed),
    );
  }

  /// Plans and then performs the write, recording ownership and hashes.
  Future<WriteResult> write(GeneratedFile file) async {
    final planned = await plan(file);
    if (!planned.outcome.changesFile) return planned;

    final target = File(p.join(root, file.path));
    final current = target.existsSync() ? await target.readAsString() : '';
    final contents = _wholeFileFor(file, current);

    await target.parent.create(recursive: true);
    await target.writeAsString(contents);

    lock.record(
      LockEntry(
        path: file.path,
        // A file shipway created is owned outright; one it was handed keeps the
        // ownership adoption granted.
        ownership: lock.ownershipOf(file.path) == Ownership.adopted
            ? Ownership.adopted
            : Ownership.generated,
        mode: file.mode,
        hash: ContentHash.of(contents),
        blockHash: file.mode == WriteMode.block
            ? ContentHash.of(file.contents)
            : null,
        adoptedAt: lock[file.path]?.adoptedAt,
      ),
    );

    return planned;
  }

  /// What the whole file should look like after writing [file].
  String _wholeFileFor(GeneratedFile file, String current) {
    if (file.mode == WriteMode.full) {
      return _ensureTrailingNewline(file.contents);
    }

    final base = _reconcile(file, current).text;
    final anchor = file.anchor;
    int? insertAt;
    var indent = '';
    if (anchor != null && !ManagedBlock.isPresent(base)) {
      final located = _locateAnchor(base, anchor);
      if (located == null) {
        // Fall through to appending; plan() has already reported the failure
        // for the case where this matters.
        insertAt = null;
      } else {
        insertAt = located.offset;
        indent = located.indent;
      }
    }

    return ManagedBlock.upsert(
      base,
      body: file.contents,
      style: file.commentStyle,
      insertAt: insertAt,
      indent: indent,
    );
  }

  /// One line of the mask that stands in for shipway's block while a
  /// reconciler reads the rest of the file.
  static const String _maskLine = '//~shipway-managed-block~\n';

  /// [current] as [file]'s reconciler would leave it, block untouched.
  ///
  /// The block is swapped for comment lines — as many as it has, so line
  /// numbers in a reconciler's messages still match the file — and put back
  /// afterwards. The reconciler therefore never sees, and cannot rewrite,
  /// what shipway itself wrote.
  ReconcileResult _reconcile(GeneratedFile file, String current) {
    final reconciler = file.reconciler;
    if (reconciler == null) return ReconcileResult(current);

    final block = ManagedBlock.find(current);
    if (block == null) return reconciler.reconcile(current);

    final region = current.substring(block.start, block.end);
    final lines = '\n'.allMatches(region).length;
    final mask = _maskLine * (lines < 1 ? 1 : lines);
    final result = reconciler.reconcile(
      current.replaceRange(block.start, block.end, mask),
    );
    final at = result.text.indexOf(mask);
    if (at == -1) return ReconcileResult(current, blockers: result.blockers);
    return ReconcileResult(
      result.text.replaceRange(at, at + mask.length, region),
      blockers: result.blockers,
    );
  }

  /// Finds where a new block goes inside a brace-matched structure.
  ({int offset, String indent})? _locateAnchor(
    String content,
    BlockAnchor anchor,
  ) {
    final block = GradleScanner.findBlock(content, anchor.insideBlock);
    if (block == null) return null;
    if (anchor.atEnd) {
      return (offset: block.bodyEnd, indent: '    ');
    }
    // Just after the opening brace's line, so the block reads as the first
    // thing inside the structure it configures.
    final newline = content.indexOf('\n', block.bodyStart);
    final offset = newline == -1 ? block.bodyStart : newline + 1;
    return (offset: offset, indent: '    ');
  }

  /// True when the user changed the part shipway owns.
  ///
  /// For a block-managed file this compares only the block body, so an edit
  /// *around* the block — the normal case, and entirely the user's right — is
  /// not treated as a conflict.
  bool _userEditedOurContent(GeneratedFile file, String current) {
    final entry = lock[file.path];
    if (entry == null) return false;

    if (file.mode == WriteMode.full) {
      final hash = entry.hash;
      if (hash == null) return false;
      return !ContentHash.matches(hash, current);
    }

    final recorded = entry.blockHash;
    if (recorded == null) return false;
    final block = ManagedBlock.find(current);
    if (block == null) {
      // The block was deleted outright. Re-adding it is not destroying an edit.
      return false;
    }
    return !ContentHash.matches(recorded, block.body);
  }

  static String _ensureTrailingNewline(String value) =>
      value.endsWith('\n') ? value : '$value\n';
}
