import '../fastlane/release_target.dart';
import 'shipway_config.dart';

/// A pipeline step naming a flavor or target the config does not have.
class PipelineReferenceProblem {
  const PipelineReferenceProblem({
    required this.pipeline,
    required this.what,
    required this.hint,
  });

  final String pipeline;
  final String what;
  final String hint;
}

/// Checks the names pipeline steps refer to, without running anything.
///
/// A field report's `beta` pipeline released `prod` to a config whose flavors
/// are `development` and `production`. Found at the release step, a typo like
/// that costs every step before it — analyze, test, a build.
///
/// Read from the raw `pipelines:` section rather than through
/// `PipelineParser`, so `doctor`, which may import only `core`, asks exactly
/// the question `shipway run` asks. A step whose *shape* is wrong is still the
/// parser's to report; this only looks at names.
abstract final class PipelineReferences {
  /// Every problem in [config]'s pipelines, or only in [pipeline].
  static List<PipelineReferenceProblem> check(
    ShipwayConfig config, {
    String? pipeline,
    String? appId,
  }) {
    final app = config.appOrNull(appId);
    if (app == null) return const <PipelineReferenceProblem>[];

    final problems = <PipelineReferenceProblem>[];
    for (final entry in config.pipelines.entries) {
      if (pipeline != null && entry.key != pipeline) continue;
      _visit(
        entry.value,
        (step, options) => _check(entry.key, step, options, app, problems),
      );
    }
    return problems;
  }

  /// The closest of [candidates] to [input], or null when none is close.
  ///
  /// A prefix counts as close — `prod` for `production` is the usual slip, and
  /// it is six edits away — and so does anything within two edits.
  static String? didYouMean(String input, Iterable<String> candidates) {
    final lower = input.toLowerCase();
    String? best;
    var bestDistance = 3;
    for (final candidate in candidates) {
      final other = candidate.toLowerCase();
      if (other.startsWith(lower) || lower.startsWith(other)) return candidate;
      final distance = _distance(lower, other);
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }

  static void _visit(
    Object? steps,
    void Function(String step, Map<dynamic, dynamic> options) visit,
  ) {
    if (steps is! List) return;
    for (final raw in steps) {
      if (raw is! Map || raw.length != 1) continue;
      final key = raw.keys.first.toString();
      final options = raw.values.first;
      if (key == 'parallel') {
        _visit(options, visit);
      } else if ((key == 'build' || key == 'release') && options is Map) {
        visit(key, options);
      }
    }
  }

  static void _check(
    String pipeline,
    String step,
    Map<dynamic, dynamic> options,
    AppConfig app,
    List<PipelineReferenceProblem> problems,
  ) {
    final verb = step == 'release' ? 'releases' : 'builds';

    final flavor = options['flavor']?.toString();
    final flavors = app.flavors.keys.toList();
    if (flavor != null && flavors.isNotEmpty && !flavors.contains(flavor)) {
      final guess = didYouMean(flavor, flavors);
      problems.add(
        PipelineReferenceProblem(
          pipeline: pipeline,
          what:
              'Pipeline `$pipeline` $verb flavor `$flavor`, which this config '
              'does not declare.${guess == null ? '' : ' Did you mean `$guess`?'}',
          hint: 'Flavors: ${flavors.join(', ')}.',
        ),
      );
    }

    if (step != 'release') return;
    final name = options['target']?.toString();
    if (name == null) return;
    final target = ReleaseTarget.parse(name);
    if (target == null) {
      final guess = didYouMean(name, ReleaseTarget.ids);
      problems.add(
        PipelineReferenceProblem(
          pipeline: pipeline,
          what:
              'Pipeline `$pipeline` releases to `$name`, which is not a '
              'release target.${guess == null ? '' : ' Did you mean `$guess`?'}',
          hint: 'Targets: ${ReleaseTarget.ids.join(', ')}.',
        ),
      );
    } else if (!target.isConfiguredIn(app)) {
      problems.add(
        PipelineReferenceProblem(
          pipeline: pipeline,
          what:
              'Pipeline `$pipeline` releases to `${target.id}`, but '
              'targets.${target.id} is not configured.',
          hint: 'Add targets.${target.id} to shipway.yaml, or remove the step.',
        ),
      );
    }
  }

  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = <int>[
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      previous = current;
    }
    return previous[b.length];
  }
}
