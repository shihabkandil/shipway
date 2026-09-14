import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../core/config/pipeline_references.dart';
import '../../pipeline/pipeline.dart';
import '../../pipeline/pipeline_parser.dart';
import '../../pipeline/pipeline_runner.dart';
import '../../notify/run_notifier.dart';
import '../../pipeline/run_manifest.dart';
import '../exit_codes.dart';
import '../notifications.dart';
import '../run_context.dart';

/// Invokes one of shipway's own commands, in process.
typedef CommandInvoker = Future<int> Function(List<String> arguments);

/// `shipway run <pipeline>`.
///
/// Runs a named sequence from `shipway.yaml`. It adds no shipping ability —
/// every step can be run by hand — but it owns the seams between them:
/// ordering, running iOS and Android at once, and knowing what not to repeat
/// after a failure.
class RunCommand extends Command<int> {
  RunCommand(this._contextProvider, this._invoke) {
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the plan and run nothing.',
      )
      ..addFlag(
        'resume',
        negatable: false,
        help: 'Skip the steps the last run of this pipeline finished.',
      )
      ..addFlag(
        'notify',
        defaultsTo: true,
        help: 'Post to Slack as notify in shipway.yaml says.',
      );
  }

  final ContextProvider _contextProvider;

  /// Supplied by the runner, so this command can invoke `build` and `release`
  /// without the pipeline layer ever reaching the CLI.
  final CommandInvoker _invoke;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'run';

  @override
  String get description => 'Run a named pipeline from shipway.yaml.';

  @override
  String get invocation => 'shipway run <pipeline>';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final config = await context.requireConfig();
    if (config.pipelines.isEmpty) {
      logger
        ..err('This config declares no pipelines.')
        ..info('Add one to shipway.yaml:')
        ..info('')
        ..info('  pipelines:')
        ..info('    beta:')
        ..info('      - analyze')
        ..info('      - test')
        ..info('      - release: { flavor: prod, target: testflight }');
      return ShipwayExit.userError;
    }

    final requested = results.rest.isEmpty ? null : results.rest.first;
    if (requested == null || !config.pipelines.containsKey(requested)) {
      final names = config.pipelines.keys.join(', ');
      logger.err(
        requested == null
            ? 'Say which pipeline to run. This config declares: $names.'
            : 'No pipeline named "$requested". This config declares: $names.',
      );
      return ShipwayExit.userError;
    }

    final Pipeline pipeline;
    try {
      pipeline = PipelineParser.parse(requested, config.pipelines[requested]);
    } on PipelineException catch (e) {
      logger.err(e.message);
      final hint = e.hint;
      if (hint != null) logger.info(hint);
      return ShipwayExit.userError;
    }

    // Every flavor and target a step names, before any step runs. Found at
    // the release step instead, a typo costs everything before it.
    final references = PipelineReferences.check(
      config,
      pipeline: requested,
      appId: context.appId,
    );
    if (references.isNotEmpty) {
      for (final problem in references) {
        logger
          ..err(problem.what)
          ..info('  ${problem.hint}');
      }
      return ShipwayExit.userError;
    }

    final resume = results['resume'] as bool;
    final completed = resume ? await _resumeFrom(pipeline) : <String>{};
    if (completed == null) return ShipwayExit.userError;

    _printPlan(pipeline, completed);

    if (results['dry-run'] as bool) {
      logger
        ..info('')
        ..info('Nothing was run.');
      return ShipwayExit.success;
    }

    final notifier = results['notify'] as bool
        ? await openNotifier(context, config, name: pipeline.name)
        : null;
    notifier?.begin(<({String key, String label})>[
      for (final step in pipeline.steps) (key: step.key, label: step.label),
    ], done: completed);

    final outcome = await PipelineRunner(
      invoke: _invokeStep,
      reporter: _Reporter(logger, notifier),
      completed: completed,
    ).run(pipeline);

    await outcome.manifest.save(context.projectRoot);
    _printSummary(outcome);
    await notifier?.finish(succeeded: outcome.succeeded);
    return outcome.exitCode;
  }

  /// Which steps a resume may skip, or null when the user declined.
  ///
  /// The awkward case is the whole point: the step that failed may be one
  /// whose effect already landed — an upload that succeeded before the process
  /// died. shipway cannot tell, so it says so rather than choosing silently.
  /// Re-running risks a duplicate; skipping risks a release everybody believes
  /// shipped and did not.
  Future<Set<String>?> _resumeFrom(Pipeline pipeline) async {
    final context = _context;
    final logger = context.logger;

    final manifest = await RunManifest.load(context.projectRoot, pipeline.name);
    if (manifest == null) {
      logger.info(
        'No record of a previous run of `${pipeline.name}`, so this is a '
        'normal run.',
      );
      return <String>{};
    }

    final completed = manifest.completed;
    final failure = manifest.firstFailure;
    if (failure == null) return completed;

    final matching = pipeline.steps.where((s) => s.key == failure.key);
    final step = matching.isEmpty ? null : matching.first;

    if (step != null && step.repeatable != true) {
      final unknown = step.repeatable == null;
      logger
        ..info('')
        ..warn(
          '`${failure.label}` failed last time, and re-running it '
          '${unknown ? 'may not be safe' : 'is not safe'}.',
        )
        ..info(
          unknown
              ? '  shipway does not know what that command does, so it cannot '
                    'tell whether it already took effect.'
              : '  An upload can land and then the run can fail afterwards. '
                    'If it did land, uploading again is rejected as a '
                    'duplicate build number.',
        )
        ..info(
          unknown
              ? '  Check whether it did, then re-run with --yes to go ahead.'
              : '  Check the store, then re-run with --yes to go ahead.',
        );

      if (!context.assumeYes) return null;
    }

    return completed;
  }

  Future<int> _invokeStep(PipelineStep step) => switch (step) {
    // Flutter's own, not shipway's: there is no `shipway analyze`, and adding
    // one to wrap a command that already works would be a worse answer than
    // calling it.
    PipelineAnalyze() => _flutter(<String>['analyze']),
    PipelineTest(coverage: final coverage) => _flutter(<String>[
      'test',
      if (coverage) '--coverage',
    ]),
    PipelineBuild(
      platform: final platform,
      flavor: final flavor,
      artifact: final artifact,
    ) =>
      _invoke(<String>[
        'build',
        platform,
        '--flavor',
        flavor,
        if (artifact != null) ...<String>['--artifact', artifact],
      ]),
    PipelineRelease(
      platform: final platform,
      flavor: final flavor,
      target: final target,
      track: final track,
      rollout: final rollout,
    ) =>
      _invoke(<String>[
        'release',
        platform,
        '--flavor',
        flavor,
        '--target',
        target,
        if (track != null) ...<String>['--track', track],
        if (rollout != null) ...<String>['--rollout', rollout],
        // The pipeline reports the run as a whole; a message per release
        // step on top of that would say everything twice.
        '--no-notify',
      ]),
    PipelineRun(command: final command) => _shell(command),
  };

  Future<int> _flutter(List<String> arguments) async {
    final context = _context;
    final result = await context.runner.run(
      'flutter',
      arguments,
      workingDirectory: context.projectRoot,
    );
    if (!result.ok) context.logger.info(result.output);
    return result.exitCode;
  }

  /// The escape hatch, run through the same process runner as everything else
  /// so its output is redacted like everything else.
  Future<int> _shell(String command) async {
    final context = _context;
    final result = await context.runner.run('sh', <String>[
      '-c',
      command,
    ], workingDirectory: context.projectRoot);
    if (!result.ok) context.logger.info(result.output);
    return result.exitCode;
  }

  void _printPlan(Pipeline pipeline, Set<String> completed) {
    final logger = _context.logger;
    logger
      ..info('')
      ..info('Pipeline ${pipeline.name}:');

    for (final stage in pipeline.stages) {
      final parallel = stage.isParallel;
      for (var i = 0; i < stage.steps.length; i++) {
        final step = stage.steps[i];
        final marker = parallel
            ? (i == 0 ? '┌' : (i == stage.steps.length - 1 ? '└' : '│'))
            : ' ';
        final skipped = completed.contains(step.key);
        final label = skipped
            ? darkGray.wrap('${step.label}  (done last run)') ?? step.label
            : step.label;
        logger.info('  $marker ${skipped ? '·' : '•'} $label');
      }
    }
  }

  void _printSummary(PipelineOutcome outcome) {
    final logger = _context.logger;
    logger.info('');

    for (final step in outcome.manifest.steps) {
      final duration = step.duration;
      final took = duration == null
          ? ''
          : ' ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
      final mark = switch (step.status) {
        StepStatus.succeeded => green.wrap('  ok  ') ?? 'ok',
        StepStatus.failed => red.wrap('failed') ?? 'failed',
        StepStatus.skipped => darkGray.wrap('skipped') ?? 'skipped',
        StepStatus.notRun => darkGray.wrap('not run') ?? 'not run',
      };
      logger.info('  $mark ${step.label}${darkGray.wrap(took) ?? took}');
    }

    logger.info('');
    if (outcome.succeeded) {
      logger.info(
        green.wrap('${outcome.manifest.pipeline} finished.') ?? 'finished',
      );
      return;
    }

    final failure = outcome.manifest.firstFailure;
    logger
      ..err('${outcome.manifest.pipeline} stopped at `${failure?.label}`.')
      ..info(
        '  shipway run ${outcome.manifest.pipeline} --resume   '
        '— skips what already finished',
      );
  }
}

class _Reporter implements PipelineReporter {
  _Reporter(this.logger, this.notifier);

  final Logger logger;
  final RunNotifier? notifier;

  @override
  void stageStarting(PipelineStage stage, int index, int total) {
    if (!stage.isParallel) return;
    logger.info('');
    logger.info(
      darkGray.wrap('  running ${stage.steps.length} steps together') ?? '',
    );
  }

  @override
  void stepStarting(PipelineStep step) {
    logger
      ..info('')
      ..info('▸ ${step.label}');
    notifier?.stepStarted(step.key);
  }

  @override
  void stepFinished(StepRecord record) {
    notifier?.stepFinished(
      record.key,
      succeeded: record.status.isSuccess,
      duration: record.duration,
      exitCode: record.exitCode,
    );
  }

  @override
  void stepSkipped(PipelineStep step, String why) {
    logger.info(darkGray.wrap('· ${step.label} — $why') ?? step.label);
    notifier?.stepSkipped(step.key);
  }
}
