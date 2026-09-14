import '../core/gradle/gradle_scanner.dart';
import 'write_guards.dart';

/// Takes over the flavor declarations a Gradle file already has once shipway's
/// managed block declares the same flavors.
///
/// The block *creates* each flavor. A project that creates them too — every
/// flavored project did, before shipway arrived — then declares each one
/// twice, and Gradle fails because the flavor already exists. A field report
/// hit exactly that after `adopt`, and fixed it by hand: `create` became
/// `getByName`, and the properties the block now sets were deleted from the
/// project's own section.
///
/// This makes the same change, so the diff `adopt` shows before asking is the
/// fix. What the project adds of its own — `manifestPlaceholders`,
/// `buildConfigField`, signing — stays where it was. What cannot be rewritten
/// with confidence is refused instead, naming the line.
class GradleFlavorReconciler extends ContentReconciler {
  const GradleFlavorReconciler({
    required this.path,
    required this.flavors,
    required this.dimensions,
    required this.kotlin,
  });

  /// For messages.
  final String path;

  /// The flavors the managed block creates.
  final List<String> flavors;

  /// The dimensions the managed block declares.
  final List<String> dimensions;

  final bool kotlin;

  /// Single-line properties the managed block sets on every flavor.
  static final RegExp _managedProperty = RegExp(
    r'^(dimension|applicationIdSuffix|versionNameSuffix)\b',
  );

  @override
  ReconcileResult reconcile(String content) {
    final android = GradleScanner.findBlock(content, 'android');
    if (android == null) return ReconcileResult(content);

    final edits = <_Edit>[];
    final blockers = <WriteBlocker>[];
    final children = GradleScanner.blocksIn(
      content,
      start: android.bodyStart,
      end: android.bodyEnd,
    );

    for (final child in children) {
      if (child.declaredName != 'productFlavors') continue;
      _reconcileFlavors(content, child, edits, blockers);
    }
    _removeDimensions(content, android, children, edits);
    _refuseStrayCreates(content, blockers);

    return ReconcileResult(_apply(content, edits), blockers: blockers);
  }

  void _reconcileFlavors(
    String content,
    GradleBlock productFlavors,
    List<_Edit> edits,
    List<WriteBlocker> blockers,
  ) {
    final blocks = GradleScanner.blocksIn(
      content,
      start: productFlavors.bodyStart,
      end: productFlavors.bodyEnd,
    );
    final pending = <_Edit>[];
    var everyBlockRemoved = true;

    for (final block in blocks) {
      final name = block.declaredName;
      final header = _headerOffset(content, block);

      if (name == null) {
        everyBlockRemoved = false;
        // Kotlin's container refuses a second `create`; Groovy's
        // configure-or-create does not, so only Kotlin is at risk here.
        if (kotlin) {
          blockers.add((
            reason:
                '$path:${_lineOf(content, header)} creates product flavors in '
                'code shipway cannot read (`${block.header}`). If it creates '
                '${flavors.join(', ')}, the build fails once shipway\'s block '
                'creates them too.',
            remedy:
                'Configure those flavors with `getByName("<flavor>")` rather '
                'than creating them, or remove them from shipway.yaml.',
          ));
        }
        continue;
      }
      if (!flavors.contains(name)) {
        everyBlockRemoved = false;
        continue;
      }

      final removals = <_Edit>[];
      var keepsSomething = false;
      for (final line in _lines(content, block.bodyStart, block.bodyEnd)) {
        if (line.text.trim().isEmpty) continue;
        if (line.whole && _isManaged(line.text)) {
          removals.add(_Edit(line.start, line.end, ''));
        } else {
          keepsSomething = true;
        }
      }

      if (!keepsSomething) {
        pending.add(
          _Edit(
            _lineStart(content, header),
            _lineEnd(content, block.bodyEnd),
            '',
          ),
        );
        continue;
      }

      everyBlockRemoved = false;
      pending.addAll(removals);
      final creates = RegExp(
        r'^(create|register)\s*\(',
      ).firstMatch(block.header);
      if (creates != null) {
        pending.add(
          _Edit(header, header + creates.group(1)!.length, 'getByName'),
        );
      }
    }

    // Everything inside was shipway's, so the container goes too, rather than
    // leaving an empty `productFlavors { }` to puzzle over.
    final leftover = _outside(content, productFlavors, blocks).trim();
    if (everyBlockRemoved && leftover.isEmpty) {
      edits.add(
        _Edit(
          _lineStart(content, _headerOffset(content, productFlavors)),
          _lineEnd(content, productFlavors.bodyEnd),
          '',
        ),
      );
    } else {
      edits.addAll(pending);
    }
  }

  /// `flavorDimensions` lines naming only dimensions the block declares.
  void _removeDimensions(
    String content,
    GradleBlock android,
    List<GradleBlock> children,
    List<_Edit> edits,
  ) {
    final nested = <({int start, int end})>[
      for (final child in children)
        (
          start: _lineStart(content, _headerOffset(content, child)),
          end: child.bodyEnd,
        ),
    ];
    for (final line in _lines(content, android.bodyStart, android.bodyEnd)) {
      if (!line.whole) continue;
      if (nested.any((r) => line.start >= r.start && line.start <= r.end)) {
        continue;
      }
      final text = line.text.trim();
      if (!text.startsWith('flavorDimensions') || !_balanced(text)) continue;
      final names = <String>[
        for (final match in RegExp(r'''["']([^"']+)["']''').allMatches(text))
          match.group(1)!,
      ];
      if (names.isEmpty || !names.every(dimensions.contains)) continue;
      edits.add(_Edit(line.start, line.end, ''));
    }
  }

  /// `productFlavors.create("dev")` outside a `productFlavors { }` block:
  /// legal, rare, and not something to rewrite by pattern.
  void _refuseStrayCreates(String content, List<WriteBlocker> blockers) {
    for (final flavor in flavors) {
      final pattern = RegExp(
        'productFlavors\\s*\\.\\s*(create|register)\\s*\\(\\s*["\']'
        '${RegExp.escape(flavor)}["\']',
      );
      for (final match in pattern.allMatches(content)) {
        final lineStart = _lineStart(content, match.start);
        if (content.substring(lineStart, match.start).trim().startsWith('//')) {
          continue;
        }
        blockers.add((
          reason:
              '$path:${_lineOf(content, match.start)} creates flavor '
              '`$flavor`, which shipway\'s managed block also creates. Gradle '
              'fails when a flavor is created twice.',
          remedy:
              'Change it to `productFlavors.getByName("$flavor")` and keep only '
              'what shipway does not set, or delete it.',
        ));
      }
    }
  }

  static bool _isManaged(String line) {
    final text = _stripComment(line.trim());
    if (!_balanced(text)) return false;
    if (_managedProperty.hasMatch(text)) return true;
    return text.startsWith('resValue') &&
        RegExp(r'''["']app_name["']''').hasMatch(text);
  }

  static bool _balanced(String text) =>
      '('.allMatches(text).length == ')'.allMatches(text).length;

  static String _stripComment(String text) {
    final index = text.indexOf(' //');
    return index == -1 ? text : text.substring(0, index).trim();
  }

  /// Where a block's header text actually starts.
  static int _headerOffset(String content, GradleBlock block) {
    final at = content.indexOf(block.header, block.headerStart);
    return at == -1 ? block.headerStart : at;
  }

  /// [block]'s body with its child blocks cut out.
  static String _outside(
    String content,
    GradleBlock block,
    List<GradleBlock> children,
  ) {
    final buffer = StringBuffer();
    var cursor = block.bodyStart;
    for (final child in children) {
      final start = _lineStart(content, _headerOffset(content, child));
      if (start > cursor) buffer.write(content.substring(cursor, start));
      cursor = _lineEnd(content, child.bodyEnd);
    }
    if (cursor < block.bodyEnd) {
      buffer.write(content.substring(cursor, block.bodyEnd));
    }
    return buffer.toString();
  }

  static int _lineStart(String content, int offset) =>
      offset <= 0 ? 0 : content.lastIndexOf('\n', offset - 1) + 1;

  /// Just past the newline ending the line holding [offset].
  static int _lineEnd(String content, int offset) {
    final newline = content.indexOf('\n', offset);
    return newline == -1 ? content.length : newline + 1;
  }

  static int _lineOf(String content, int offset) =>
      '\n'.allMatches(content.substring(0, offset)).length + 1;

  /// The lines between [start] and [end]. A line is `whole` when it begins
  /// after a newline and ends with one, so removing it cannot join two lines.
  static Iterable<_Line> _lines(String content, int start, int end) sync* {
    var cursor = start;
    while (cursor < end) {
      final newline = content.indexOf('\n', cursor);
      final stop = newline == -1 || newline >= end ? end : newline + 1;
      final whole =
          cursor > 0 &&
          content[cursor - 1] == '\n' &&
          content[stop - 1] == '\n';
      yield _Line(cursor, stop, content.substring(cursor, stop), whole);
      cursor = stop;
    }
  }

  /// Applies non-overlapping edits from the end, so offsets stay valid.
  ///
  /// A removed line takes its surroundings into account: the blank line that
  /// separated it from its neighbours is not left behind to double up with
  /// another, or to sit against a brace.
  static String _apply(String content, List<_Edit> edits) {
    final sorted = edits.toList()..sort((a, b) => b.start.compareTo(a.start));
    var result = content;
    var limit = content.length + 1;
    for (final edit in sorted) {
      if (edit.end > limit) continue;
      result = result.replaceRange(edit.start, edit.end, edit.replacement);
      limit = edit.start;
      final removedLines =
          edit.replacement.isEmpty &&
          (edit.start == 0 || result[edit.start - 1] == '\n');
      if (removedLines) {
        final tidied = _tidyJoin(result, edit.start);
        // Tidying only ever removes text before the join, so every edit still
        // to apply — all of them earlier in the file — moves by that much.
        limit -= result.length - tidied.text.length - tidied.removedAfter;
        result = tidied.text;
      }
    }
    return result;
  }

  /// Removes a blank line left doubled, or against a brace, where two lines
  /// were joined at [join].
  ///
  /// Only at the join: blank lines elsewhere are the project's own layout.
  static ({String text, int removedAfter}) _tidyJoin(String text, int join) {
    var removedAfter = 0;
    var result = text;

    // A blank line after the join, under a blank line or an opening brace.
    while (true) {
      final next = _lineAt(result, join);
      final previous = _lineBefore(result, join);
      final nextBlank = next.text.trim().isEmpty && next.end > join;
      if (!nextBlank || previous == null) break;
      final previousText = previous.text.trim();
      if (previousText.isNotEmpty && !previousText.endsWith('{')) break;
      result = result.replaceRange(next.start, next.end, '');
      removedAfter += next.end - next.start;
    }

    // A blank line before the join, above a closing brace.
    final previous = _lineBefore(result, join);
    final next = _lineAt(result, join);
    if (previous != null &&
        previous.text.trim().isEmpty &&
        next.text.trim().startsWith('}')) {
      result = result.replaceRange(previous.start, previous.end, '');
    }
    return (text: result, removedAfter: removedAfter);
  }

  /// The line starting at [offset], newline included.
  static _Line _lineAt(String text, int offset) {
    final end = _lineEnd(text, offset);
    return _Line(offset, end, text.substring(offset, end), true);
  }

  /// The line ending just before [offset], or null at the start of the text.
  static _Line? _lineBefore(String text, int offset) {
    if (offset == 0) return null;
    final start = _lineStart(text, offset - 1);
    return _Line(start, offset, text.substring(start, offset), true);
  }
}

class _Edit {
  const _Edit(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}

class _Line {
  const _Line(this.start, this.end, this.text, this.whole);

  final int start;
  final int end;
  final String text;
  final bool whole;
}
