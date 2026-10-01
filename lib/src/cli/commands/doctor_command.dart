import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../core/config/shipway_config.dart';
import '../../doctor/check.dart';
import '../../doctor/doctor.dart';
import '../../doctor/platform_deadlines.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway doctor` — can this machine ship an app?
///
/// A product in its own right, not a warm-up: it is the first thing a user runs
/// and the thing they come back to when a build breaks for reasons that have
/// nothing to do with their code.
class DoctorCommand extends Command<int> {
  DoctorCommand(this._contextProvider) {
    argParser
      ..addFlag('json', negatable: false, help: 'Emit the report as JSON.')
      ..addMultiOption(
        'only',
        help: 'Run only the named checks.',
        valueHelp: 'id',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check whether this machine can build and ship this app.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final asJson = results['json'] as bool;
    final only = results['only'] as List<String>;

    var checks = Doctor.defaultChecks();
    if (only.isNotEmpty) {
      checks = checks.where((c) => only.contains(c.id)).toList();
      if (checks.isEmpty) {
        _context.logger.err(
          'No checks match ${only.join(', ')}. Available: '
          '${Doctor.defaultChecks().map((c) => c.id).join(', ')}',
        );
        return ShipwayExit.userError;
      }
    }

    final report = await Doctor(checks: checks).run(
      DoctorContext(
        runner: _context.runner,
        projectRoot: _context.projectRoot,
        config: await _configOrNull(),
        now: _context.now,
        host: _context.host,
        environment: _context.processEnvironment,
      ),
    );

    if (asJson) {
      _context.logger.write(
        '${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n',
      );
    } else {
      _render(report);
    }

    // A failing check means this machine cannot ship, which is an environment
    // problem rather than a mistake the user made in their arguments.
    return report.passed ? ShipwayExit.success : ShipwayExit.environmentError;
  }

  /// A broken config must not stop `doctor` from reporting on the environment —
  /// that is exactly when a user needs it most.
  Future<ShipwayConfig?> _configOrNull() async {
    try {
      return await _context.configOrNull();
    } catch (error) {
      _context.logger.warn('Could not read shipway.yaml: $error');
      return null;
    }
  }

  void _render(DoctorReport report) {
    final logger = _context.logger;
    logger.info('');
    for (final entry in report.entries) {
      final result = entry.result;
      logger.info(
        '${_glyph(result.status)} ${entry.check.title.padRight(24)} '
        '${_detail(result)}',
      );
      final fix = result.fixHint;
      if (fix != null && result.status != CheckStatus.ok) {
        for (final line in _wrap(fix, 72)) {
          logger.info('    ${darkGray.wrap(line)}');
        }
      }
      final docs = result.docsUrl;
      if (docs != null && result.status != CheckStatus.ok) {
        logger.info('    ${darkGray.wrap(docs)}');
      }
    }

    logger.info('');
    final summary = <String>[
      '${report.count(CheckStatus.ok)} ok',
      if (report.count(CheckStatus.warn) > 0)
        '${report.count(CheckStatus.warn)} warning'
            '${report.count(CheckStatus.warn) == 1 ? '' : 's'}',
      if (report.count(CheckStatus.fail) > 0)
        '${report.count(CheckStatus.fail)} failure'
            '${report.count(CheckStatus.fail) == 1 ? '' : 's'}',
      if (report.count(CheckStatus.skip) > 0)
        '${report.count(CheckStatus.skip)} skipped',
    ].join(', ');

    // Named rather than implied: "Ready to ship" on a machine that cannot
    // build iOS is true of half an app, and the half it is not true of is the
    // one that takes a week to discover.
    final scope = report.host.canBuildIos ? '' : ' Android';
    if (report.passed) {
      logger.info('${green.wrap('Ready to ship$scope.')} $summary.');
    } else {
      logger.info('${red.wrap('Not ready to ship$scope.')} $summary.');
    }
    if (!report.host.canBuildIos) {
      const note =
          'iOS checks were skipped: they need macOS. Android is unaffected.';
      logger.info(darkGray.wrap(note) ?? note);
    }

    // State the age of the store-deadline data rather than presenting it as
    // timeless truth; it goes stale on its own and silence would hide that.
    final verified = PlatformDeadlines.lastVerified;
    final age = PlatformDeadlines.ageInDaysOn(report.generatedAt);
    final line =
        'Store deadline data last verified '
        '${verified.year}-${_two(verified.month)}-${_two(verified.day)} '
        '($age day${age == 1 ? '' : 's'} ago).';
    if (PlatformDeadlines.isStaleOn(report.generatedAt)) {
      logger.warn('$line Re-check it against the linked sources.');
    } else {
      logger.info(darkGray.wrap(line) ?? line);
    }
  }

  String _detail(CheckResult result) {
    final text = result.detail;
    return switch (result.status) {
      CheckStatus.ok => green.wrap(text) ?? text,
      CheckStatus.warn => yellow.wrap(text) ?? text,
      CheckStatus.fail => red.wrap(text) ?? text,
      CheckStatus.skip => darkGray.wrap(text) ?? text,
    };
  }

  static String _glyph(CheckStatus status) => switch (status) {
    CheckStatus.ok => green.wrap('  ok  ') ?? '  ok  ',
    CheckStatus.warn => yellow.wrap(' warn ') ?? ' warn ',
    CheckStatus.fail => red.wrap(' fail ') ?? ' fail ',
    CheckStatus.skip => darkGray.wrap(' skip ') ?? ' skip ',
  };

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// Wraps a hint to [width] so long advice stays readable in a terminal.
  static List<String> _wrap(String text, int width) {
    final words = text.split(' ');
    final lines = <String>[];
    var current = StringBuffer();
    for (final word in words) {
      if (current.isNotEmpty && current.length + 1 + word.length > width) {
        lines.add(current.toString());
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(word);
    }
    if (current.isNotEmpty) lines.add(current.toString());
    return lines;
  }
}
