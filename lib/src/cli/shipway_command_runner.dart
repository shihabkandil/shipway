import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/env/host_platform.dart';
import '../core/config/config_exception.dart';
import '../core/config/config_loader.dart';
import '../core/io/http_poster.dart';
import '../core/io/process_runner.dart';
import '../core/env/run_environment.dart';
import '../core/io/redactor.dart';
import '../core/managed/managed_block.dart';
import '../version.dart';
import 'commands/adopt_command.dart';
import 'commands/build_command.dart';
import 'commands/disown_command.dart';
import 'commands/release_command.dart';
import 'commands/run_command.dart';
import 'commands/secrets_command.dart';
import 'commands/setup_command.dart';
import 'commands/doctor_command.dart';
import 'commands/generate_command.dart';
import 'commands/import_command.dart';
import 'commands/init_command.dart';
import 'commands/notify_command.dart';
import 'commands/status_command.dart';
import 'exit_codes.dart';
import 'run_context.dart';

/// The root command runner.
///
/// Owns global flags, builds the one [RunContext] every command shares, and
/// turns thrown failures into stable exit codes so no individual command has to
/// think about process semantics.
class ShipwayCommandRunner extends CommandRunner<int> {
  ShipwayCommandRunner({
    Logger? logger,
    ProcessRunner? runner,
    Redactor? redactor,
    String? workingDirectory,
    HostPlatform? host,
    HttpPoster? http,
    Map<String, String>? environment,
  }) : _logger = logger ?? Logger(),
       _redactor = redactor ?? Redactor(),
       _injectedRunner = runner,
       _http = http ?? SystemHttpPoster(),
       _environment = environment ?? Platform.environment,
       _workingDirectory = workingDirectory ?? Directory.current.path,
       _host = host ?? HostPlatform.current,
       super('shipway', 'Local-first CI/CD for Flutter apps.') {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the shipway version and exit.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show the commands shipway runs and their full output.',
      )
      ..addFlag('no-color', negatable: false, help: 'Disable coloured output.')
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Assume yes for every prompt. Implies non-interactive.',
      )
      ..addOption('config', help: 'Path to shipway.yaml.', valueHelp: 'path')
      ..addOption(
        'app',
        help: 'Which app in a monorepo to act on.',
        valueHelp: 'id',
      )
      ..addOption(
        'env',
        help:
            'Where this is running. Decides which sources secrets may come '
            'from, and whether shipway may prompt. Detected when omitted.',
        allowed: RunEnvironment.flagNames,
        valueHelp: 'name',
      );

    addCommand(DoctorCommand(() => context));
    addCommand(InitCommand(() => context));
    addCommand(ImportCommand(() => context));
    addCommand(StatusCommand(() => context));
    addCommand(GenerateCommand(() => context));
    addCommand(AdoptCommand(() => context));
    addCommand(DisownCommand(() => context));
    addCommand(BuildCommand(() => context));
    addCommand(ReleaseCommand(() => context));
    addCommand(SecretsCommand(() => context));
    // The invoker is this runner itself, so a pipeline step runs the same
    // command a person would, with the same validation and error handling.
    addCommand(RunCommand(() => context, run));
    addCommand(SetupCommand(() => context));
    addCommand(NotifyCommand(() => context));
  }

  final Logger _logger;
  final Redactor _redactor;
  final ProcessRunner? _injectedRunner;
  final HttpPoster _http;
  final Map<String, String> _environment;
  final String _workingDirectory;

  /// Injected so the Linux refusals can be exercised from a Mac.
  final HostPlatform _host;

  /// The context before global flags are parsed. Commands never capture this
  /// directly; they resolve through [context] at run time.
  late final RunContext _initialContext = RunContext(
    logger: _logger,
    redactor: _redactor,
    runner: _injectedRunner ?? SystemProcessRunner(redactor: _redactor),
    projectRoot: _workingDirectory,
    configPath: null,
    appId: null,
    verbose: false,
    assumeYes: false,
    host: _host,
    http: _http,
    processEnvironment: _environment,
  );

  /// The context commands act on. Replaced once globals are parsed.
  RunContext get context => _resolved ?? _initialContext;
  RunContext? _resolved;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevel = parse(args);
      if (topLevel['version'] as bool) {
        _logger.info(packageVersion);
        return ShipwayExit.success;
      }
      _applyGlobals(topLevel);
      // `overrideAnsiOutput` sets a zone value, which propagates across awaits,
      // so this covers every colour decision the command makes.
      return await overrideAnsiOutput(
        !(topLevel['no-color'] as bool),
        () async => await runCommand(topLevel) ?? ShipwayExit.success,
      );
    } on UsageException catch (e) {
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ShipwayExit.userError;
    } on ConfigException catch (e) {
      // A config problem is the user's to fix and already carries a location
      // and a next step, so print it as-is rather than as a crash.
      _logger.err(e.toString());
      return ShipwayExit.userError;
    } on ManagedBlockException catch (e) {
      _logger.err(e.message);
      return ShipwayExit.userError;
    } on ProcessExitException catch (e) {
      _logger.err(e.toString());
      return ShipwayExit.environmentError;
    } catch (error, stackTrace) {
      _logger
        ..err('$error')
        ..detail('$stackTrace');
      return ShipwayExit.internalError;
    }
  }

  /// The nearest directory at or above [start] holding `shipway.yaml`, or
  /// [start] itself when there is none.
  ///
  /// So a command run from `android/` or `ios/` acts on the project, instead of
  /// resolving every relative path from the wrong place — which a field report
  /// ran into from a platform directory. The walk stops at a repository root,
  /// so a stray config higher up the disk is never picked up.
  static String projectRootFrom(String start) {
    final absolute = p.normalize(p.absolute(start));
    var directory = absolute;
    while (true) {
      if (ConfigLoader.locate(directory) != null) {
        return directory == absolute ? start : directory;
      }
      final git = p.join(directory, '.git');
      if (FileSystemEntity.typeSync(git) != FileSystemEntityType.notFound) {
        return start;
      }
      final parent = p.dirname(directory);
      if (parent == directory) return start;
      directory = parent;
    }
  }

  void _applyGlobals(ArgResults results) {
    final verbose = results['verbose'] as bool;
    if (verbose) _logger.level = Level.verbose;
    final configPath = results['config'] as String?;
    final projectRoot = configPath == null
        ? projectRootFrom(_workingDirectory)
        : _workingDirectory;
    if (projectRoot != _workingDirectory) {
      _logger.detail(
        'Using the project at $projectRoot, where shipway.yaml is.',
      );
    }
    _resolved = RunContext(
      logger: _logger,
      redactor: _redactor,
      runner: _initialContext.runner,
      projectRoot: projectRoot,
      configPath: configPath,
      appId: results['app'] as String?,
      verbose: verbose,
      assumeYes: results['yes'] as bool,
      environmentFlag: results['env'] as String?,
      host: _host,
      http: _http,
      processEnvironment: _environment,
    );
  }
}
