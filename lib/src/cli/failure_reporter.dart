import 'package:mason_logger/mason_logger.dart';

import '../core/errors/classifier.dart';
import '../core/io/process_runner.dart';

/// Says what a failed run meant, in the order a person needs it: the step that
/// failed, the error it gave, what to do — and only then anything else shipway
/// noticed.
///
/// Shared by `shipway build` and `shipway release`, so the two cannot drift
/// into explaining the same failure differently.
abstract final class FailureReporter {
  /// Reports [report] for a run that failed.
  static void failure(Logger logger, FailureReport report) {
    final attribution = report.attribution;
    final step = attribution.failedStep;
    final recognised = report.recognised;

    if (step != null) logger.info('  Failed step: $step');
    // Quoted even though it has scrolled past: on a CI log it is a hundred
    // lines up, and it is the one line somebody will search for.
    for (final line in attribution.errorLines) {
      logger.info('  ${line.trim()}');
    }

    for (final cause in report.causes) {
      logger
        ..info('')
        ..err(cause.summary)
        ..info('  ${cause.fix}');
      final url = cause.docsUrl;
      if (url != null) logger.info('  $url');
    }

    if (!recognised) {
      // A wrong explanation costs more than none: a field report rotated
      // three working secrets on the strength of one.
      logger
        ..info('')
        ..info(
          'shipway does not recognise this failure, so it is not going to '
          'guess at a cause.',
        );
      final context = attribution.context;
      if (context.isNotEmpty) {
        logger.info(
          step == null
              ? '  The output leading up to the error:'
              : '  The last output of the step that failed:',
        );
        for (final line in context) {
          logger.info('    $line');
        }
      } else {
        logger.info('  The output above is everything it has.');
      }
    }

    warnings(
      logger,
      report.warnings,
      heading: 'Warnings — not why this failed:',
    );
  }

  /// Reports [diagnoses] as things worth knowing, under [heading].
  ///
  /// Never in red. A warning printed like an error is read as the cause.
  static void warnings(
    Logger logger,
    List<Diagnosis> diagnoses, {
    String heading = 'Warnings:',
  }) {
    if (diagnoses.isEmpty) return;
    logger
      ..info('')
      ..info(heading);
    for (final diagnosis in diagnoses) {
      logger
        ..warn(diagnosis.summary)
        ..info('  ${diagnosis.fix}');
      final url = diagnosis.docsUrl;
      if (url != null) logger.info('  $url');
    }
  }
}

/// Runs a command, showing each line behind [prefix] as it arrives, and
/// returns what it printed and how it exited.
///
/// A lane and the `pod install` that repairs one are shown the same way, so a
/// retry reads as part of the same run.
Future<({int exitCode, String output})> streamShowing(
  ProcessRunner runner,
  Logger logger,
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required String prefix,
  Map<String, String>? environment,
}) async {
  final output = StringBuffer();
  var exitCode = 0;
  try {
    await for (final line in runner.stream(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    )) {
      output.writeln(line);
      logger.info('$prefix$line');
    }
  } on ProcessExitException catch (failure) {
    exitCode = failure.exitCode;
  }
  return (exitCode: exitCode, output: output.toString());
}
