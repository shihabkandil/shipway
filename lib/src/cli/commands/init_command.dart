import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/config_loader.dart';
import '../../core/config/shipway_config.dart';
import '../../inspect/config_from_project.dart';
import '../../inspect/config_writer.dart';
import '../../inspect/project_inspector.dart';
import '../../version.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway init` — a thin front door.
///
/// Almost every project that needs shipway already has flavors, schemes and
/// often fastlane. Asking such a user to answer greenfield prompts would
/// produce a config that contradicts their working build, so `init` looks first
/// and hands off to `import` whenever there is anything to read.
class InitCommand extends Command<int> {
  InitCommand(this._contextProvider) {
    argParser
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing shipway.yaml.',
      )
      ..addOption(
        'runner',
        help:
            'Where CI will run, recorded as ci.runner. Asked when omitted and '
            'shipway may prompt.',
        allowed: CiRunner.ids,
        allowedHelp: const <String, String>{
          'hosted': 'GitHub-hosted runners: a clean machine per job.',
          'self-hosted': 'A machine you keep, such as a Mac mini.',
        },
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'init';

  @override
  String get description => 'Set up shipway in this project.';

  @override
  Future<int> run() async {
    final context = _context;
    final logger = context.logger;
    final force = argResults!['force'] as bool;

    if (!File(p.join(context.projectRoot, 'pubspec.yaml')).existsSync()) {
      logger.err(
        'No pubspec.yaml in ${context.projectRoot}.\n'
        'Run shipway from the root of a Flutter project.',
      );
      return ShipwayExit.userError;
    }

    final existing = ConfigLoader.locate(context.projectRoot);
    if (existing != null && !force) {
      logger
        ..info('${p.basename(existing.path)} already exists.')
        ..info('')
        ..info('  shipway status   see how it differs from this project')
        ..info('  shipway import --force   derive it again from scratch');
      return ShipwayExit.success;
    }

    final progress = logger.progress('Looking at this project');
    final model = await ProjectInspector(
      runner: context.runner,
    ).readFromDisk(context.projectRoot);
    progress.complete('Looked at this project');

    final flavors = model.allFlavors;
    final hasSomethingToRead =
        flavors.isNotEmpty ||
        model.hasFastlane ||
        model.android.applicationId != null ||
        model.ios.applicationTarget != null;

    if (!hasSomethingToRead) {
      logger
        ..info('')
        ..info(
          'This project has no flavors, no fastlane setup, and no readable '
          'application id yet.',
        )
        ..info(
          'There is nothing for shipway to describe, so there is nothing to '
          'write.',
        )
        ..info('')
        ..info(
          'Run `flutter create .` to generate the platform folders, then '
          '`shipway init` again.',
        );
      return ShipwayExit.success;
    }

    // There is a real project here, so describing it beats interrogating the
    // user about it.
    logger.info('');
    if (flavors.isEmpty) {
      logger.info(
        'Found a Flutter project with no flavors. shipway can describe it as a '
        'single-flavor config.',
      );
    } else {
      logger.info(
        'Found ${flavors.length} flavor${flavors.length == 1 ? '' : 's'}: '
        '${(flavors.toList()..sort()).join(', ')}'
        '${model.hasFastlane ? ', plus an existing fastlane setup' : ''}.',
      );
    }

    final proceed =
        context.assumeYes ||
        logger.confirm(
          'Write a shipway.yaml describing it? (nothing else is modified)',
          defaultValue: true,
        );
    if (!proceed) {
      logger
        ..info('')
        ..info(
          'Nothing was written. Run `shipway import --dry-run` to see '
          'what it would produce.',
        );
      return ShipwayExit.success;
    }

    final derived = ConfigFromProject.build(model);
    final runner = _runner(argResults!['runner'] as String?);
    final config = runner == null
        ? derived
        : derived.withCi(CiConfig(runner: runner));
    final outPath = p.join(context.projectRoot, ConfigLoader.defaultFileName);
    await File(outPath).writeAsString(
      ConfigWriter.render(
        config,
        generatedBy: packageVersion,
        generatedAt: context.now,
      ),
    );

    logger
      ..info('')
      ..info('${green.wrap('Wrote')} ${ConfigLoader.defaultFileName}')
      ..info('No project files were modified.')
      ..info('')
      ..info('Next:')
      ..info('  shipway status   check it matches your project')
      ..info('  shipway doctor   check this machine can ship it');
    if (runner != null) {
      logger.info(
        '  shipway generate ci   write the release workflow for '
        '${runner == CiRunner.selfHosted ? 'a self-hosted runner' : 'GitHub-hosted runners'}',
      );
    }

    if (model.uncertainties.isNotEmpty) {
      logger.info(
        '  shipway import   see the ${model.uncertainties.length} '
        'finding${model.uncertainties.length == 1 ? '' : 's'} from reading '
        'this project',
      );
    }
    return ShipwayExit.success;
  }

  static const String _hostedChoice = 'GitHub-hosted runners';
  static const String _selfHostedChoice =
      'A self-hosted runner (a machine you keep, like a Mac mini)';
  static const String _undecidedChoice = 'Not decided yet';

  /// Whose machines CI will run on, or null when nobody has said.
  ///
  /// The one thing `init` asks rather than reads: nothing in a project says
  /// where it will be built, and the two answers want different workflows — a
  /// hosted one installs and caches a toolchain, which on a machine that keeps
  /// running is ten things to undo by hand.
  ///
  /// Asked only where a question can be answered. Left unset otherwise, which
  /// generates for hosted runners and can be changed in one line.
  CiRunner? _runner(String? flag) {
    final fromFlag = CiRunner.parse(flag);
    if (fromFlag != null) return fromFlag;

    final context = _context;
    if (context.assumeYes || !context.environment.environment.mayPrompt) {
      return null;
    }

    final answer = context.logger.chooseOne<String>(
      'Where will CI run?',
      choices: const <String>[
        _hostedChoice,
        _selfHostedChoice,
        _undecidedChoice,
      ],
      defaultValue: _hostedChoice,
    );
    return switch (answer) {
      _hostedChoice => CiRunner.hosted,
      _selfHostedChoice => CiRunner.selfHosted,
      _ => null,
    };
  }
}
