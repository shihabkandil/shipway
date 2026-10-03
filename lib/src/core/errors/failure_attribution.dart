/// Where in a lane's output the failure is: which step, which error line, and
/// the output that belongs to it.
///
/// A fastlane log is mostly things that went right. A field report had a
/// release fail in `pod install`, a hundred lines above the summary, in a run
/// whose App Store Connect steps had all succeeded — and shipway, reading the
/// whole log, blamed the API key. Three secrets were rotated for nothing.
/// Everything a diagnosis is drawn from is therefore cut down to the step that
/// failed before anything is matched against it.
///
/// Pure: a string in, facts out. Output with no step markers at all — a plain
/// `flutter build` — is returned whole, because there is nothing to cut by.
class FailureAttribution {
  const FailureAttribution({
    required this.region,
    required this.context,
    required this.hasStepMarkers,
    this.failedStep,
    this.errorLines = const <String>[],
  });

  /// Reads [output] as fastlane wrote it.
  factory FailureAttribution.parse(String output) {
    final lines = <String>[for (final line in output.split('\n')) _clean(line)];

    final markers = <({int index, String name})>[];
    int? summaryStart;
    String? crashed;
    var lastError = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final marker = _stepMarker.firstMatch(line);
      if (marker != null) {
        markers.add((index: i, name: marker.group(1)!.trim()));
        continue;
      }
      if (summaryStart == null && line.contains('fastlane summary')) {
        // The table's top border is the line above its title.
        summaryStart = i > 0 && lines[i - 1].trimLeft().startsWith('+')
            ? i - 1
            : i;
      }
      final row = _crashedRow.firstMatch(line);
      if (row != null) crashed = row.group(1)!.trim();
      if (_errorLine.hasMatch(line)) lastError = i;
    }

    // fastlane's own error is printed bare. CocoaPods and Flutter use `[!]`
    // too, but inside a step their lines arrive behind a timestamp and `▸`,
    // which [_errorLine] does not match once markers are present.
    final errorLines = <String>[];
    if (lastError >= 0) {
      for (
        var i = lastError;
        i < lines.length && errorLines.length < _errorLineLimit;
        i++
      ) {
        if (lines[i].trim().isEmpty) break;
        errorLines.add(lines[i].trimRight());
      }
    }

    if (markers.isEmpty) {
      return FailureAttribution(
        region: output,
        context: lastError < 0
            ? const <String>[]
            : _tail(lines, 0, lastError, _contextLines),
        hasStepMarkers: false,
        errorLines: errorLines,
      );
    }

    // The summary table marks the step that failed. It is preferred over
    // "the last step before the error" because an `error do` block runs
    // steps of its own — a Slack post, usually — after the one that failed.
    final limit = lastError >= 0 ? lastError : lines.length;
    final before = <({int index, String name})>[
      for (final marker in markers)
        if (marker.index < limit) marker,
    ];
    final candidates = before.isEmpty ? markers : before;
    var failed = candidates.last;
    if (crashed != null) {
      final name = crashed;
      for (final marker in candidates.reversed) {
        if (_sameStep(marker.name, name)) {
          failed = marker;
          break;
        }
      }
    }

    // The step's own output: up to the next step, the summary table, or the
    // error line, whichever comes first.
    var stepEnd = limit;
    for (final marker in markers) {
      if (marker.index > failed.index && marker.index < stepEnd) {
        stepEnd = marker.index;
        break;
      }
    }
    final summary = summaryStart;
    if (summary != null && summary > failed.index && summary < stepEnd) {
      stepEnd = summary;
    }

    final region = <String>[
      ...lines.sublist(failed.index, stepEnd),
      ...errorLines,
    ].join('\n');

    return FailureAttribution(
      failedStep: failed.name,
      errorLines: errorLines,
      region: region,
      // The lines above fastlane's `[!]` are its summary table, which says
      // nothing. What a person needs is the end of the failing step.
      context: _tail(lines, failed.index + 1, stepEnd, _contextLines),
      hasStepMarkers: true,
    );
  }

  /// How many lines of context are kept for a failure nothing recognised.
  static const int _contextLines = 20;

  /// A fastlane error is one line, sometimes a few. More than this and it is
  /// swallowing whatever was printed after it.
  static const int _errorLineLimit = 5;

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
  static final RegExp _stepMarker = RegExp(r'-{2,} Step: (.+?) -{2,}\s*$');
  static final RegExp _errorLine = RegExp(r'^\s*\[!\]\s*\S');
  static final RegExp _crashedRow = RegExp(r'^\s*\|\s*💥\s*\|\s*(.+?)\s*\|');
  static final RegExp _marker = RegExp(r'^[\s\-=+|]*$');

  static String _clean(String line) =>
      line.replaceAll(_ansi, '').replaceAll('\r', '');

  /// The table shortens a long step name, so a row is matched by its start.
  static bool _sameStep(String marker, String row) {
    final shown = row.replaceFirst(RegExp(r'(\.{3}|…)$'), '').trim();
    return shown.isNotEmpty && (marker == shown || marker.startsWith(shown));
  }

  /// The last [count] lines of `lines[from..to)` that say anything.
  static List<String> _tail(List<String> lines, int from, int to, int count) {
    final kept = <String>[];
    for (var i = to - 1; i >= from && kept.length < count; i--) {
      final line = lines[i];
      // Blank lines and the rules fastlane draws around a step marker.
      if (_marker.hasMatch(_withoutTimestamp(line))) continue;
      kept.add(line.trimRight());
    }
    return kept.reversed.toList();
  }

  static String _withoutTimestamp(String line) =>
      line.replaceFirst(RegExp(r'^\s*\[\d{2}:\d{2}:\d{2}\]:\s?'), '');

  /// The step that failed, as fastlane named it, or null when the output has
  /// no step markers.
  ///
  /// For a shell step this is the command itself, e.g.
  /// `cd /app && flutter build ipa --release`.
  final String? failedStep;

  /// fastlane's own `[!]` message: the line and any that continue it. Empty
  /// when the output has none.
  final List<String> errorLines;

  /// The first of [errorLines], which is the one worth quoting.
  String? get errorLine => errorLines.isEmpty ? null : errorLines.first;

  /// What signatures are matched against: the failing step's output and the
  /// error line. The whole output when there are no step markers.
  final String region;

  /// Up to twenty lines leading to the failure, for when nothing recognised
  /// it: the end of the failing step's output, or the lines above the error
  /// line when the output has no steps.
  final List<String> context;

  /// False for output fastlane did not write, such as `flutter build`'s.
  final bool hasStepMarkers;
}
