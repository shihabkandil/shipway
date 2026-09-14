import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/shipway_config.dart';
import '../../core/errors/classifier.dart';
import '../../core/fastlane/fastfile_lanes.dart';
import '../../core/fastlane/release_target.dart';
import '../../core/firebase/google_services.dart';
import '../../core/firebase/service_account.dart';
import '../../core/toolchain/bundled_fastlane.dart';
import '../../core/toolchain/fastlane_pins.dart';
import '../../generators/generated_file.dart';
import '../../generators/generator_registry.dart';
import '../../platform/android/firebase_access.dart';
import '../../secrets/secret_requirements.dart';
import '../../secrets/secret_resolver.dart';
import '../exit_codes.dart';
import '../notifications.dart';
import '../run_context.dart';

/// `shipway release ios|android --flavor <f> --target <t>`.
///
/// A front door, not a second implementation: it validates, prints the plan,
/// then runs the same generated lane a person could run by hand, from the
/// project's bundle. Nothing it does is unavailable to somebody who prefers
/// running fastlane themselves.
///
/// The order is the point. Everything cheap and local happens before anything
/// slow or remote, because the failures worth catching — a credential that is
/// not set, a target the config never configured, external distribution with
/// no group — are all knowable in under a second, and finding them after a
/// twenty-minute build is what makes releasing feel dangerous.
class ReleaseCommand extends Command<int> {
  ReleaseCommand(this._contextProvider) {
    argParser
      ..addOption('flavor', abbr: 'f', help: 'Which flavor to ship.')
      ..addOption(
        'target',
        abbr: 't',
        help: 'Where it is going.',
        allowed: ReleaseTarget.ids,
      )
      ..addOption('track', help: 'Play only: override the configured track.')
      ..addOption(
        'rollout',
        help:
            'Play only: user fraction for a staged rollout, e.g. 0.1. supply '
            'derives the release status from it.',
      )
      ..addOption(
        'build-number',
        help:
            'Use this build number instead of the one versioning.strategy '
            'would resolve.',
      )
      ..addOption(
        'version-name',
        help: 'Use this version name instead of the one in pubspec.yaml.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Validate and print the plan, upload nothing.',
      )
      ..addFlag(
        'access-check',
        defaultsTo: true,
        help:
            'Firebase only: ask App Distribution whether the service account '
            'can reach the app before building. Read-only.',
      )
      ..addFlag(
        'notify',
        defaultsTo: true,
        help: 'Post to Slack as notify in shipway.yaml says.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'release';

  @override
  String get description => 'Build a flavor and send it somewhere.';

  @override
  String get invocation =>
      'shipway release ios|android --flavor <flavor> --target <target>';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final platform = results.rest.isEmpty ? null : results.rest.first;
    if (platform != 'ios' && platform != 'android') {
      logger.err(
        platform == null
            ? 'Say which platform to release: `shipway release ios` or '
                  '`shipway release android`.'
            : 'Unknown platform "$platform". Expected ios or android.',
      );
      return ShipwayExit.userError;
    }

    final target = ReleaseTarget.parse(results['target'] as String?);
    if (target == null) {
      final forPlatform = ReleaseTarget.values
          .where((t) => t.platform == platform)
          .map((t) => t.id)
          .join(', ');
      logger.err(
        results['target'] == null
            ? 'Pass --target. For $platform: $forPlatform.'
            : 'Unknown target "${results['target']}". For $platform: '
                  '$forPlatform.',
      );
      return ShipwayExit.userError;
    }
    if (target.platform != platform) {
      logger
        ..err('--target ${target.id} is ${target.platformLabel} destination.')
        ..info(
          'Run `shipway release ${target.platform} --target ${target.id}`.',
        );
      return ShipwayExit.userError;
    }

    if (platform == 'ios' && !Platform.isMacOS) {
      logger.err('An iOS release needs macOS.');
      return ShipwayExit.environmentError;
    }

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final flavor = _resolveFlavor(app, results['flavor'] as String?);
    if (flavor == null) return ShipwayExit.userError;

    final problems = _validate(config, app, target, results);
    if (problems.isNotEmpty) {
      for (final problem in problems) {
        logger.err(problem.what);
        logger.info('  ${problem.fix}');
      }
      return ShipwayExit.userError;
    }

    // A lane that is not there makes every later answer irrelevant, and
    // fastlane's own "Could not find lane" arrives only after Ruby, bundler
    // and every gem have loaded.
    final missingLane = await FastfileLanes.check(context.projectRoot, target);
    if (missingLane != null) {
      logger
        ..err(missingLane.what)
        ..info('  ${missingLane.fix}');
      return ShipwayExit.userError;
    }

    GoogleServicesApp? firebaseApp;
    if (target == ReleaseTarget.firebase &&
        app.firebaseAndroidAppIdVariable(flavor) == null) {
      firebaseApp = _firebaseApp(flavor);
      if (firebaseApp == null) return ShipwayExit.userError;
    }

    final credentials = await _credentials(config, target, flavor);
    if (credentials.missing.isNotEmpty) {
      final missing = credentials.missing;
      logger.err(
        '${missing.length} required '
        '${missing.length == 1 ? 'credential is' : 'credentials are'} not '
        'set: ${missing.join(', ')}',
      );
      logger.info('  shipway secrets list   — where each one is looked for');
      return ShipwayExit.environmentError;
    }

    // Asked before the plan and before anything slow. The bundle a lane runs
    // in is where "works on my machine" lives: printing it makes a failure
    // afterwards legible, and a bundle that is not installed stops here.
    final probe = await BundledFastlane.probe(
      context.runner,
      directory: p.join(context.projectRoot, target.platform),
      platform: target.platform,
    );
    final toolchainFailure = probe.failure;
    if (toolchainFailure != null) {
      logger
        ..err(toolchainFailure.what)
        ..info('  ${toolchainFailure.fix}');
      return ShipwayExit.environmentError;
    }

    final upload = target == ReleaseTarget.firebase
        ? await _firebaseUpload(
            app,
            flavor,
            firebaseApp,
            credentials.environment,
            checkAccess: results['access-check'] as bool,
          )
        : null;

    _printPlan(
      app,
      flavor,
      target,
      results,
      firebaseApp: firebaseApp,
      upload: upload,
      toolchain: probe.toolchain!,
    );

    if (upload != null) {
      final refused = upload.problem;
      if (refused != null) {
        logger
          ..info('')
          ..err(refused.what)
          ..info('  ${refused.fix}');
        return ShipwayExit.environmentError;
      }
      final mismatch = upload.projectMismatch;
      if (mismatch != null) {
        logger
          ..info('')
          ..warn(mismatch);
      }
    }

    if (results['dry-run'] as bool) {
      logger
        ..info('')
        ..info('Nothing was uploaded.');
      return ShipwayExit.success;
    }

    final notifier = results['notify'] as bool
        ? await openNotifier(
            context,
            config,
            name: 'release ${flavor.name} → ${target.id}',
            flavor: flavor.name,
            target: target.id,
            platform: target.platform,
            versionName: results['version-name'] as String?,
          )
        : null;
    const step = 'lane';
    notifier
      ?..begin(<({String key, String label})>[
        (key: step, label: 'fastlane ${target.platform} ${target.lane}'),
      ])
      ..stepStarted(step);

    final started = DateTime.now();
    final code = await _runLane(
      target,
      flavor,
      results,
      firebaseApp: firebaseApp,
      environment: credentials.environment,
    );

    notifier?.stepFinished(
      step,
      succeeded: code == ShipwayExit.success,
      duration: DateTime.now().difference(started),
      exitCode: code,
    );
    await notifier?.finish(succeeded: code == ShipwayExit.success);
    return code;
  }

  ResolvedFlavor? _resolveFlavor(ResolvedApp app, String? requested) {
    final logger = _context.logger;
    if (!app.hasFlavors) {
      logger
        ..err('This config declares no flavors, so there is nothing to ship.')
        ..info('  Add one to shipway.yaml and run `shipway generate`.');
      return null;
    }
    final names = app.flavors.map((f) => f.name).join(', ');
    if (requested == null) {
      logger.err('Pass --flavor. This config declares: $names.');
      return null;
    }
    final match = app.flavor(requested);
    if (match == null) {
      logger.err('Unknown flavor "$requested". This config declares: $names.');
      return null;
    }
    return match;
  }

  /// Everything knowable without touching the network.
  ///
  /// Each entry names the config key or flag that fixes it, because "invalid
  /// configuration" sends somebody to read a file rather than change a line.
  List<({String what, String fix})> _validate(
    ShipwayConfig config,
    ResolvedApp app,
    ReleaseTarget target,
    ArgResults results,
  ) {
    final problems = <({String what, String fix})>[];

    final configured = switch (target) {
      ReleaseTarget.testflight => app.testflight != null,
      ReleaseTarget.appstore => app.appstore != null,
      ReleaseTarget.play => app.play != null,
      ReleaseTarget.firebase => app.firebase != null,
    };
    if (!configured) {
      problems.add((
        what: 'This config has no ${target.id} target.',
        fix:
            'Add targets.${target.id} to shipway.yaml, then run '
            '`shipway generate fastlane`.',
      ));
    }

    final rollout = results['rollout'] as String?;
    if (rollout != null) {
      if (target != ReleaseTarget.play) {
        problems.add((
          what: '--rollout applies to the play target only.',
          fix: 'Drop it, or release to --target play.',
        ));
      } else {
        final value = double.tryParse(rollout);
        if (value == null || value <= 0 || value > 1) {
          problems.add((
            what: '--rollout must be a fraction above 0 and at most 1.',
            fix: '0.1 means 10% of users. 1 completes the rollout.',
          ));
        }
      }
    }

    if (results['track'] != null && target != ReleaseTarget.play) {
      problems.add((
        what: '--track applies to the play target only.',
        fix: 'Drop it, or release to --target play.',
      ));
    }

    // pilot requires a group alongside external distribution. The config
    // loader refuses this too; a flag could not reintroduce it, but a config
    // written before that check existed can still be on disk.
    final testflight = app.testflight;
    if (target == ReleaseTarget.testflight &&
        testflight != null &&
        testflight.distributeExternal &&
        testflight.groups.isEmpty) {
      problems.add((
        what: 'distribute_external is set with no groups to distribute to.',
        fix: 'Add targets.testflight.groups, or turn distribute_external off.',
      ));
    }

    return problems;
  }

  /// The Firebase app [flavor] uploads to, read from its
  /// `google-services.json`, or null once the reason has been reported.
  ///
  /// Read here as well as in the lane because here is before the build. The
  /// id is then handed to the lane, so the one printed is the one used.
  GoogleServicesApp? _firebaseApp(ResolvedFlavor flavor) {
    final logger = _context.logger;
    final path = flavor.firebaseAndroid;
    final packageName = flavor.androidApplicationId;
    if (path == null || packageName == null) {
      logger
        ..err(
          'shipway cannot tell which Firebase app `${flavor.name}` uploads '
          'to.',
        )
        ..info(
          '  Set flavors.${flavor.name}.firebase.android to its '
          'google-services.json — `shipway setup firebase` finds it — or set '
          'targets.firebase.android_app_id_ref.',
        );
      return null;
    }

    final lookup = GoogleServices.lookup(
      _context.projectRoot,
      path,
      packageName,
    );
    final found = lookup.app;
    if (found != null) return found;
    logger
      ..err(lookup.problem!)
      ..info('  ${lookup.fix}');
    return null;
  }

  /// The credentials this release needs: which are missing, and the values of
  /// those that were found, for the lane.
  ///
  /// The values are what make the pre-flight honest. It used to find a
  /// variable in `.env` or the keychain and report it present, while the lane
  /// — a separate process that reads only its own environment — still failed
  /// on it. Paths are made absolute, because the lane runs from the platform
  /// directory and a path relative to the project root misses from there.
  Future<({List<String> missing, Map<String, String> environment})>
  _credentials(
    ShipwayConfig config,
    ReleaseTarget target,
    ResolvedFlavor flavor,
  ) async {
    final context = _context;
    final resolver = SecretResolver(
      environment: context.environment.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      processEnvironment: context.processEnvironment,
      flavor: flavor.name,
      host: context.host,
    );
    // Scoped to this destination and this flavor: demanding an App Store
    // Connect key before a Play upload, or the prod Firebase account for a dev
    // build, is noise, and noise in a pre-flight is how people learn to ignore
    // it.
    final requirements = SecretRequirements.of(
      config,
      environment: context.environment.environment,
      appId: context.appId,
      flavor: flavor.name,
    ).where((r) => r.appliesTo(target.id));
    final statuses = await resolver.statuses(requirements);

    final missing = <String>[
      for (final status in statuses)
        if (status.blocks) status.name,
    ];
    final environment = <String, String>{};
    if (missing.isEmpty) {
      for (final status in statuses) {
        if (!status.source.found) continue;
        final value = await resolver.read(status.name);
        if (value == null) continue;
        environment[status.name] =
            status.requirement.isPath && !p.isAbsolute(value)
            ? p.join(context.projectRoot, value)
            : value;
      }
    }
    return (missing: missing, environment: environment);
  }

  /// Who is about to upload to Firebase, to which project, and whether App
  /// Distribution will let them.
  ///
  /// A field report learned all three at the upload, after a full build: the
  /// default service account belonged to neither of the two Firebase projects
  /// its flavors lived in, and the only message was a 403.
  Future<_FirebaseUpload> _firebaseUpload(
    ResolvedApp app,
    ResolvedFlavor flavor,
    GoogleServicesApp? firebaseApp,
    Map<String, String> environment, {
    required bool checkAccess,
  }) async {
    final context = _context;
    final variable = flavor.firebaseServiceAccountVariable;
    final path = environment[variable];
    final identity = path == null ? null : ServiceAccountIdentity.read(path);
    final appIdVariable = app.firebaseAndroidAppIdVariable(flavor);
    final appId =
        firebaseApp?.appId ??
        (appIdVariable == null ? null : environment[appIdVariable]);

    // Both files say which project they belong to, so the likeliest cause of
    // a refusal is visible before the network is asked anything. A warning,
    // because an account can be granted access to another project.
    final accountProject = identity?.projectId;
    final appProject = firebaseApp?.projectId;
    final mismatch =
        accountProject != null &&
            appProject != null &&
            accountProject != appProject
        ? 'The service account belongs to project $accountProject, but '
              '${flavor.firebaseAndroid} is for $appProject. Unless it has '
              'been granted access there, App Distribution will refuse the '
              'upload.'
        : null;

    _FirebaseUpload notChecked(String why) => _FirebaseUpload(
      variable: variable,
      path: path,
      identity: identity,
      access: 'not checked ($why)',
      projectMismatch: mismatch,
    );

    if (!checkAccess) return notChecked('--no-access-check');
    if (path == null || appId == null) return notChecked('no app id');
    final script = FirebaseAccessCheck.locateScript();
    if (script == null) {
      return notChecked('shipway could not find its access check');
    }

    final access =
        await FirebaseAccessCheck(
          runner: context.runner,
          scriptPath: script,
        ).check(
          directory: p.join(context.projectRoot, 'android'),
          serviceAccountPath: path,
          appId: appId,
          environment: environment,
        );

    final who = identity?.email ?? 'The service account in $path';
    final project = appProject != null
        ? 'project $appProject'
        : 'Firebase project ${appId.split(':').elementAtOrNull(1) ?? appId}';

    return _FirebaseUpload(
      variable: variable,
      path: path,
      identity: identity,
      projectMismatch: mismatch,
      access: switch (access.outcome) {
        FirebaseAccessOutcome.ok => 'ok',
        FirebaseAccessOutcome.denied => 'refused',
        FirebaseAccessOutcome.appNotFound => 'app not found',
        FirebaseAccessOutcome.badCredentials => 'credentials rejected',
        FirebaseAccessOutcome.unknown =>
          'unknown — ${access.message ?? 'no answer'}; continuing',
      },
      problem: switch (access.outcome) {
        FirebaseAccessOutcome.ok || FirebaseAccessOutcome.unknown => null,
        FirebaseAccessOutcome.denied => (
          what: '$who cannot reach $appId (HTTP ${access.status}).',
          fix:
              'Grant it the Firebase App Distribution Admin role '
              '(roles/firebaseappdistro.admin) in $project, under IAM in the '
              'Google Cloud console — or point $variable at a service account '
              'from that project.',
        ),
        FirebaseAccessOutcome.appNotFound => (
          what: 'App Distribution has no app $appId.',
          fix:
              'Open App Distribution for $project in the Firebase console and '
              'press "Get started", then check the app id above.',
        ),
        FirebaseAccessOutcome.badCredentials => (
          what:
              'The service account in $path could not authenticate: '
              '${access.message}',
          fix:
              'Create a new key for ${identity?.email ?? 'that account'} in '
              'the Google Cloud console and point $variable at it.',
        ),
      },
    );
  }

  /// What is about to happen, printed whether or not it is a dry run.
  ///
  /// Printed on a real run too, so a failure afterwards is legible: the first
  /// question about a broken release is always "which build went where".
  void _printPlan(
    ResolvedApp app,
    ResolvedFlavor flavor,
    ReleaseTarget target,
    ArgResults results, {
    GoogleServicesApp? firebaseApp,
    _FirebaseUpload? upload,
    required FastlaneToolchain toolchain,
  }) {
    final logger = _context.logger;
    String dim(String? value) => darkGray.wrap(value ?? 'unknown') ?? '';
    final identifier = target.platform == 'ios'
        ? flavor.iosBundleId
        : flavor.androidApplicationId;

    logger
      ..info('')
      ..info('  flavor      ${flavor.name}')
      ..info('  identifier  ${identifier ?? dim('not in config')}')
      ..info('  target      ${target.id}');

    if (target == ReleaseTarget.play) {
      final track =
          (results['track'] as String?) ??
          (app.play?.track ?? PlayTrack.internal).name;
      logger.info('  track       $track');

      final rollout =
          results['rollout'] as String? ?? app.play?.rollout?.toString();
      if (rollout != null) {
        // Shown because it is derived rather than configured: supply sets the
        // status from the fraction, and shipway used to demand the pair match.
        final effective = (double.tryParse(rollout) ?? 0) < 1
            ? 'inProgress'
            : 'completed';
        logger.info('  rollout     $rollout → status $effective');
      }
    }

    if (target == ReleaseTarget.firebase) {
      // Which app, which project, and whose account. Uploading with the wrong
      // project's credentials is otherwise invisible until it is refused.
      final ref = app.firebaseAndroidAppIdVariable(flavor);
      logger.info(
        firebaseApp != null
            ? '  app id      ${firebaseApp.appId}  '
                  '${dim('from ${flavor.firebaseAndroid}')}'
            : '  app id      ${dim('from \$$ref')}',
      );
      final project = firebaseApp?.projectId;
      if (project != null) logger.info('  project     $project');
      if (upload != null) {
        logger
          ..info(
            '  account     ${upload.identity?.email ?? 'unreadable'}  '
            '${dim('from \$${upload.variable} (${upload.path})')}',
          )
          ..info('  access      ${upload.access}');
      }
      final groups = app.firebase?.groups ?? const <String>[];
      logger.info(
        '  groups      '
        '${groups.isEmpty ? dim('none — uploaded, not distributed') : groups.join(', ')}',
      );
    }

    final version = results['version-name'] as String?;
    final build = results['build-number'] as String?;
    logger.info(
      '  version     ${version ?? 'pubspec'}'
      '+${build ?? 'versioning.strategy: ${app.versioning.strategy.name}'}',
    );

    // Which Ruby and which fastlane is the first question about a lane that
    // failed, and `bundle exec` makes it easy to be wrong about.
    final pinned = toolchain.fastlane == FastlanePins.fastlane
        ? ''
        : '  ${dim('shipway pins ${FastlanePins.fastlane}')}';
    logger
      ..info('  ruby        ${toolchain.rubyVersion}  ${dim(toolchain.ruby)}')
      ..info('  bundler     ${toolchain.bundler ?? 'unknown'}')
      ..info('  fastlane    ${toolchain.fastlane}$pinned')
      ..info('  gems        ${dim(toolchain.gemHome)}');
  }

  /// Runs the generated lane, then classifies whatever came back.
  Future<int> _runLane(
    ReleaseTarget target,
    ResolvedFlavor flavor,
    ArgResults results, {
    GoogleServicesApp? firebaseApp,
    required Map<String, String> environment,
  }) async {
    final context = _context;
    final logger = context.logger;

    final directory = p.join(context.projectRoot, target.platform);
    final arguments = BundledFastlane.arguments(<String>[
      target.platform,
      target.lane,
      'flavor:${flavor.name}',
      if (results['track'] != null) 'track:${results['track']}',
      if (results['rollout'] != null) 'rollout:${results['rollout']}',
      if (results['build-number'] != null)
        'build_number:${results['build-number']}',
      if (results['version-name'] != null)
        'version_name:${results['version-name']}',
      if (firebaseApp != null) 'app_id:${firebaseApp.appId}',
    ]);

    logger
      ..info('')
      ..detail('Running: bundle ${arguments.join(' ')}');

    final result = await context.runner.run(
      'bundle',
      arguments,
      workingDirectory: directory,
      environment: environment.isEmpty ? null : environment,
    );

    if (result.ok) {
      logger.info(green.wrap('Released ${flavor.name} to ${target.id}.') ?? '');
      // A store upload can succeed and still be rejected in processing, so the
      // output of a success is worth reading too.
      _reportDiagnoses(result.output, asWarning: true);
      return ShipwayExit.success;
    }

    if (result.notFound) {
      logger
        ..err('bundler is not available.')
        ..info(
          '  Install it, then run `bundle install` in ${target.platform}/.',
        );
      return ShipwayExit.environmentError;
    }

    logger.info(result.output);
    _reportDiagnoses(result.output);
    return ShipwayExit.environmentError;
  }

  void _reportDiagnoses(String output, {bool asWarning = false}) {
    final logger = _context.logger;
    for (final diagnosis in ErrorClassifier.classifyAll(output)) {
      logger.info('');
      if (asWarning) {
        logger.warn(diagnosis.summary);
      } else {
        logger.err(diagnosis.summary);
      }
      logger.info('  ${diagnosis.fix}');
    }
  }
}

/// What the plan says about a Firebase upload, and whether it may go ahead.
class _FirebaseUpload {
  const _FirebaseUpload({
    required this.variable,
    required this.access,
    this.path,
    this.identity,
    this.problem,
    this.projectMismatch,
  });

  /// The variable the service-account path came from.
  final String variable;
  final String? path;
  final ServiceAccountIdentity? identity;

  /// One line for the plan.
  final String access;

  /// Why the upload would be refused, when the check says so.
  final ({String what, String fix})? problem;

  final String? projectMismatch;
}
