import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/config_patch.dart';
import '../../core/config/shipway_config.dart';
import '../../core/firebase/google_services.dart';
import '../../generators/generator_registry.dart';
import '../../platform/android/keystore_creator.dart';
import '../../core/model/firebase_model.dart';
import '../../core/secrets/secret_names.dart';
import '../../inspect/firebase_inspector.dart';
import '../../platform/ios/match_repository.dart';
import '../../secrets/secret_store.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway setup android-signing` — the parts of getting a project shippable
/// that are not files shipway can simply write.
///
/// Distinct from `generate` on purpose. `generate` is idempotent and
/// derivable: run it twice and nothing changes, throw the output away and it
/// comes back. Setup is neither. It creates things that cannot be recreated —
/// an upload key is the only proof that an update comes from the same
/// publisher — so it refuses to overwrite, states what it did, and stops.
class SetupCommand extends Command<int> {
  SetupCommand(this._contextProvider) {
    argParser
      ..addOption(
        'alias',
        help: 'android-signing: the key alias.',
        defaultsTo: 'upload',
      )
      ..addOption(
        'keystore',
        help: 'android-signing: where to write the keystore.',
        valueHelp: 'path',
        defaultsTo: defaultKeystorePath,
      )
      ..addFlag(
        'password-stdin',
        negatable: false,
        help:
            'android-signing: use the password on standard input rather than '
            'generating one.',
      )
      ..addOption(
        'match-url',
        help:
            'ios-signing: the certificates repository. Defaults to the one '
            'shipway.yaml already names.',
        valueHelp: 'url',
      )
      ..addOption(
        'branch',
        help: 'ios-signing: the branch to read.',
        defaultsTo: 'master',
      )
      ..addFlag(
        'create',
        negatable: false,
        help:
            'ios-signing: allow creating what is missing. Without it, setup '
            'only reads and reports.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  /// Beside `android/app`, so `storeFile` resolves to `../` from Gradle's
  /// point of view and the same file works on every checkout.
  static const String defaultKeystorePath = 'android/upload-keystore.jks';

  static const List<String> actions = <String>[
    'android-signing',
    'ios-signing',
    'firebase',
  ];

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Create the credentials a project needs, once, and record their names.';

  @override
  String get invocation => 'shipway setup ${actions.join('|')}';

  @override
  Future<int> run() async {
    final results = argResults!;
    final logger = _context.logger;

    final action = results.rest.isEmpty ? null : results.rest.first;
    if (action == null || !actions.contains(action)) {
      logger.err(
        action == null
            ? 'Say what to set up: ${actions.join(', ')}.'
            : 'Unknown action "$action". Expected: ${actions.join(', ')}.',
      );
      return ShipwayExit.userError;
    }

    final config = await _context.requireConfig();
    return switch (action) {
      'ios-signing' => _iosSigning(results, config),
      'firebase' => _firebase(config),
      _ => _androidSigning(results, config),
    };
  }

  /// `shipway setup firebase` — correlate the config files with flavors and
  /// record what they say.
  ///
  /// The tedious part of Firebase is not downloading the files, it is knowing
  /// which flavor each belongs to and finding the app id inside one to paste
  /// somewhere else. Both are already in the files, so shipway reads them
  /// rather than asking.
  ///
  /// It never downloads anything. A `google-services.json` comes from the
  /// Firebase console for a specific app, and a tool that fetched one would
  /// have to pick which — silently choosing the wrong project is a mistake that
  /// surfaces as an app reporting to somebody else's analytics.
  Future<int> _firebase(ShipwayConfig config) async {
    final context = _context;
    final logger = context.logger;

    final appId = context.appId ?? config.defaultAppId;
    final app = config.appOrNull(appId);
    if (app == null) {
      logger.err('No app to set up. Check `apps:` in shipway.yaml.');
      return ShipwayExit.userError;
    }

    final result = await const FirebaseInspector().inspect(
      context.projectRoot,
      flavors: app.flavors.keys.toSet(),
    );
    final files = result.firebase.configFiles;

    if (files.isEmpty) {
      logger
        ..err('No Firebase configuration files in this project.')
        ..info(
          'Download google-services.json and GoogleService-Info.plist from '
          'the Firebase console for each flavor, then put them where the '
          'build looks:',
        )
        ..info('  android/app/src/<flavor>/google-services.json')
        ..info('  ios/config/<flavor>/GoogleService-Info.plist')
        ..info('')
        ..info('Re-run this and shipway will wire them up.');
      return ShipwayExit.environmentError;
    }

    final byFlavor = _firebaseByFlavor(config, app, files);

    logger.info('');
    for (final file in files) {
      final flavor = _flavorFor(file, app);
      final label = flavor ?? darkGray.wrap('unflavored') ?? 'unflavored';
      logger
        ..info('  ${file.platform.padRight(8)} $label')
        ..info('           ${darkGray.wrap(file.path) ?? file.path}');
      for (final line in _appIdLines(file, flavor, byFlavor)) {
        logger.info('           ${darkGray.wrap(line) ?? line}');
      }
    }

    // The inspector already knows which flavor has a config file on one
    // platform and not the other — a project that builds fine and fails at
    // runtime.
    for (final uncertainty in result.uncertainties) {
      logger
        ..info('')
        ..warn(uncertainty.reason)
        ..info('  ${uncertainty.remedy}');
    }

    _recordFirebaseInConfig(appId: appId!, app: app, files: files);
    logger
      ..info('')
      ..info('Recorded the paths in shipway.yaml.');

    // The app ids are not secret — they are compiled into the app — but the
    // lanes read them by name, so putting them where the resolver looks is
    // what makes `secrets check` answerable without a trip to the console.
    final stored = await _storeFirebaseAppIds(app, byFlavor);
    if (stored.isNotEmpty) {
      logger.info('Stored ${stored.join(' and ')} in the login keychain.');
    }

    logger
      ..info('')
      ..info('Next:')
      ..info('  shipway generate          — the run script that copies these')
      ..info(
        '  shipway secrets check     — the service account is still needed',
      )
      ..info('')
      ..info(
        'Firebase App Distribution needs a service-account JSON, not the '
        'deprecated CI token. Create one in the Google Cloud console and '
        'point ${SecretNames.firebaseServiceAccountPath} at it.',
      );
    return ShipwayExit.success;
  }

  /// Which flavor a config file belongs to, by the directory it sits in.
  static String? _flavorFor(FirebaseConfigFile file, AppConfig app) {
    final sourceSet = file.sourceSet;
    if (sourceSet == null) return null;
    return app.flavors.keys
            .firstWhere((flavor) => flavor == sourceSet, orElse: () => '')
            .isEmpty
        ? null
        : sourceSet;
  }

  void _recordFirebaseInConfig({
    required String appId,
    required AppConfig app,
    required List<FirebaseConfigFile> files,
  }) {
    final values = <List<String>, Object?>{};
    for (final flavor in app.flavors.keys) {
      for (final platform in const <String>['android', 'ios']) {
        // Only what the config does not already say: a team that placed these
        // somewhere unusual and wrote it down keeps their answer.
        final existing = platform == 'android'
            ? app.flavors[flavor]?.firebase?.android
            : app.flavors[flavor]?.firebase?.ios;
        if (existing != null) continue;

        final match = files.where(
          (f) => f.platform == platform && f.sourceSet == flavor,
        );
        if (match.isEmpty) continue;
        values[<String>[
              'apps',
              appId,
              'flavors',
              flavor,
              'firebase',
              platform,
            ]] =
            match.first.path;
      }
    }
    if (values.isEmpty) return;

    final file = _context.configFile;
    if (file == null) return;
    file.writeAsStringSync(ConfigPatch.setAll(file.readAsStringSync(), values));
  }

  /// Each flavor's Firebase config file and the app it names, per platform.
  ///
  /// Android apps are found by the flavor's package name, never by position:
  /// Firebase writes every Android app in a project into the same
  /// `google-services.json`, so a file two flavors share holds both, and its
  /// first entry is the right answer for one of them at most.
  Map<String, _FlavorFirebase> _firebaseByFlavor(
    ShipwayConfig config,
    AppConfig app,
    List<FirebaseConfigFile> files,
  ) {
    final context = _context;
    final resolved = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    String? pathFor(String flavor, String platform) {
      final firebase = app.flavors[flavor]?.firebase;
      final configured = platform == 'android'
          ? firebase?.android
          : firebase?.ios;
      if (configured != null) return p.normalize(configured);
      final own = files.where(
        (f) => f.platform == platform && f.sourceSet == flavor,
      );
      if (own.isNotEmpty) return own.first.path;
      // One unflavored google-services.json can serve every flavor. There is
      // no iOS equivalent a flavor could be matched to.
      if (platform != 'android') return null;
      return files
          .where((f) => f.platform == 'android' && f.sourceSet == null)
          .firstOrNull
          ?.path;
    }

    return <String, _FlavorFirebase>{
      for (final flavor in resolved.flavors)
        flavor.name: _flavorFirebase(
          androidPath: pathFor(flavor.name, 'android'),
          packageName: flavor.androidApplicationId,
          iosPath: pathFor(flavor.name, 'ios'),
          files: files,
        ),
    };
  }

  _FlavorFirebase _flavorFirebase({
    required String? androidPath,
    required String? packageName,
    required String? iosPath,
    required List<FirebaseConfigFile> files,
  }) => _FlavorFirebase(
    androidPath: androidPath,
    androidAppId: androidPath == null || packageName == null
        ? null
        : GoogleServices.lookup(
            _context.projectRoot,
            androidPath,
            packageName,
          ).app?.appId,
    // A GoogleService-Info.plist names exactly one app.
    iosPath: iosPath,
    iosAppId: files
        .where((f) => f.platform == 'ios' && f.path == iosPath)
        .firstOrNull
        ?.appId,
  );

  /// What to say about the app ids in [file]: the app each flavor using it
  /// uploads to, so a shared file shows every flavor's rather than its first.
  static List<String> _appIdLines(
    FirebaseConfigFile file,
    String? flavor,
    Map<String, _FlavorFirebase> byFlavor,
  ) {
    final users = <String>[
      for (final entry in byFlavor.entries)
        if (entry.value.pathFor(file.platform) == file.path) entry.key,
    ];
    if (users.isEmpty) {
      final id = file.appId;
      return id == null ? const <String>[] : <String>['app id $id'];
    }
    return <String>[
      for (final user in users)
        switch (byFlavor[user]!.appIdFor(file.platform)) {
          null => 'no app for `$user` in this file',
          final id =>
            users.length == 1 && user == flavor
                ? 'app id $id'
                : 'app id $id for `$user`',
        },
    ];
  }

  /// Puts the app ids where the resolver looks, under the names the config
  /// already uses.
  ///
  /// A flavor's own variable gets that flavor's app. The target's single
  /// variable serves every flavor without one, so it is stored only when they
  /// all name the same app: storing any one of several would send the other
  /// flavors' builds to it, and saying so is the useful answer.
  Future<List<String>> _storeFirebaseAppIds(
    AppConfig app,
    Map<String, _FlavorFirebase> byFlavor,
  ) async {
    final target = app.targets.firebase;
    if (target == null || !_context.host.hasSecurityKeychain) {
      return const <String>[];
    }

    final store = SecretStore(
      runner: _context.runner,
      redactor: _context.redactor,
      host: _context.host,
    );

    final stored = <String>[];
    Future<void> put(String ref, String id) async {
      try {
        await store.set(ref, id);
        stored.add(ref);
      } on SecretStoreFailure {
        // Not fatal: the paths are recorded and the id is in the file. A
        // keychain that refuses is a worse reason to fail than to mention.
      }
    }

    final sharingAndroid = <String, String>{};
    for (final entry in byFlavor.entries) {
      final id = entry.value.androidAppId;
      if (id == null) continue;
      final own =
          app.flavors[entry.key]?.firebase?.distribution?.androidAppIdRef;
      if (own != null) {
        await put(own, id);
      } else {
        sharingAndroid[entry.key] = id;
      }
    }
    await _putShared(
      ref: target.androidAppIdRef,
      key: 'targets.firebase.android_app_id_ref',
      ids: sharingAndroid,
      put: put,
      remedy:
          'A release reads each flavor\'s app id from its google-services.json. '
          'Remove targets.firebase.android_app_id_ref, or name one per flavor '
          'with flavors.<name>.firebase.distribution.android_app_id_ref.',
    );

    await _putShared(
      ref: target.iosAppIdRef,
      key: 'targets.firebase.ios_app_id_ref',
      ids: <String, String>{
        for (final entry in byFlavor.entries)
          if (entry.value.iosAppId case final id?) entry.key: id,
      },
      put: put,
      remedy: 'Nothing reads it yet, so it can be removed.',
    );
    return stored;
  }

  /// Stores [ids] under one shared [ref] when they agree, and explains when
  /// they do not.
  Future<void> _putShared({
    required String? ref,
    required String key,
    required Map<String, String> ids,
    required Future<void> Function(String ref, String id) put,
    required String remedy,
  }) async {
    if (ref == null || ids.isEmpty) return;
    final distinct = ids.values.toSet();
    if (distinct.length == 1) {
      await put(ref, distinct.single);
      return;
    }
    _context.logger
      ..info('')
      ..warn(
        '$key names one variable, $ref, but '
        '${ids.keys.map((f) => '`$f`').join(' and ')} are different Firebase '
        'apps (${ids.entries.map((e) => '${e.key}: ${e.value}').join(', ')}). '
        'It was not stored.',
      )
      ..info('  $remedy');
  }

  /// `shipway setup ios-signing` — adopt a certificates repository.
  ///
  /// Read-only by default, and the read is deliberately shallow: match
  /// encrypts each file in place and leaves its *name* alone, so which bundle
  /// ids are covered is answerable from the layout without a passphrase,
  /// without decrypting anything and without talking to Apple. shipway
  /// therefore never handles a certificate — only the question of whether one
  /// exists.
  ///
  /// It adopts rather than initialises. A certificates repository is shared:
  /// reshaping one breaks signing for everyone else using it, and creating a
  /// certificate spends one of a team's limited allowance. Gaps are reported;
  /// filling them needs `--create`.
  Future<int> _iosSigning(ArgResults results, ShipwayConfig config) async {
    final context = _context;
    final logger = context.logger;

    final appId = context.appId ?? config.defaultAppId;
    final app = config.appOrNull(appId);
    if (app == null) {
      logger.err('No app to set up. Check `apps:` in shipway.yaml.');
      return ShipwayExit.userError;
    }

    final url =
        (results['match-url'] as String?) ?? app.signing.ios?.matchGitUrl;
    if (url == null) {
      logger
        ..err('No certificates repository to read.')
        ..info(
          'Pass --match-url, or set signing.ios.match_git_url in '
          'shipway.yaml. It is the git repository match keeps your '
          'certificates and profiles in.',
        );
      return ShipwayExit.userError;
    }

    final branch = results['branch'] as String;
    final progress = logger.progress('Reading $url');

    final MatchRepositoryContents contents;
    try {
      contents = await MatchRepository.read(
        gitUrl: url,
        runner: context.runner,
        branch: branch,
      );
    } on MatchRepositoryFailure catch (failure) {
      progress.fail('Could not read the certificates repository');
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return ShipwayExit.environmentError;
    }
    progress.complete('Read $url');

    return _reportCoverage(
      results,
      app: app,
      appId: appId!,
      url: url,
      contents: contents,
    );
  }

  /// Compares what the repository holds against what the config asks for.
  int _reportCoverage(
    ArgResults results, {
    required AppConfig app,
    required String appId,
    required String url,
    required MatchRepositoryContents contents,
  }) {
    final logger = _context.logger;

    // The type shipway's generated Matchfile syncs. A repository full of
    // development profiles does not make an App Store build signable.
    const type = 'appstore';

    final wanted = <String>[
      for (final flavor in app.flavors.entries)
        if (_bundleIdFor(app, flavor.value) != null)
          _bundleIdFor(app, flavor.value)!,
    ];
    if (wanted.isEmpty && app.ios?.bundleId != null) {
      wanted.add(app.ios!.bundleId!);
    }

    if (contents.isEmpty) {
      logger
        ..info('')
        ..warn('That repository is empty — no certificates, no profiles.')
        ..info(
          results['create'] as bool
              ? 'Run `bundle exec fastlane match appstore` from ios/ to '
                    'populate it. shipway does not create Apple certificates '
                    'itself: match already does it well, and doing it twice '
                    'is how a team runs out of them.'
              : 'Re-run with --create for what to do about it.',
        );
      return ShipwayExit.environmentError;
    }

    logger.info('');
    for (final profile in contents.profiles) {
      logger.info(
        '  ${darkGray.wrap(profile.type.padRight(12)) ?? profile.type} '
        '${profile.bundleId}',
      );
    }

    final missing = contents.missingFrom(wanted, type);
    logger.info('');
    if (wanted.isEmpty) {
      logger.info(
        'This config names no iOS bundle ids yet, so there is nothing to '
        'check the repository against.',
      );
    } else if (missing.isEmpty) {
      logger.info(
        green.wrap('Every bundle id this config ships has an $type profile.') ??
            '',
      );
    } else {
      logger
        ..err(
          '${missing.length} bundle '
          '${missing.length == 1 ? 'id has' : 'ids have'} no $type profile: '
          '${missing.join(', ')}',
        )
        ..info(
          results['create'] as bool
              ? 'Run `bundle exec fastlane match appstore` from ios/ — it '
                    'registers the bundle id and creates the profile. That '
                    'needs an App Store Connect key with write access.'
              : 'Re-run with --create to be told how to fill them, or add '
                    'them with match yourself.',
        );
    }

    _recordMatchInConfig(appId: appId, url: url, existing: app.signing.ios);
    logger.info('Recorded the repository in shipway.yaml. No value is in it.');

    logger
      ..info('')
      ..info('Next:')
      ..info('  shipway secrets check     — MATCH_PASSWORD and the rest')
      ..info('  shipway build ios --flavor <f>');

    return missing.isEmpty ? ShipwayExit.success : ShipwayExit.environmentError;
  }

  /// A flavor's full bundle id, or null when the config does not say.
  static String? _bundleIdFor(AppConfig app, FlavorConfig flavor) {
    final base = app.ios?.bundleId;
    return base == null ? null : '$base${flavor.suffix}';
  }

  void _recordMatchInConfig({
    required String appId,
    required String url,
    required IosSigningConfig? existing,
  }) {
    // Only what was missing: a team that already named its storage or team id
    // keeps them.
    final values = <List<String>, Object?>{
      if (existing?.matchGitUrl == null)
        <String>['apps', appId, 'signing', 'ios', 'match_git_url']: url,
    };
    if (values.isEmpty) return;

    final file = _context.configFile;
    if (file == null) return;
    file.writeAsStringSync(ConfigPatch.setAll(file.readAsStringSync(), values));
  }

  Future<int> _androidSigning(ArgResults results, ShipwayConfig config) async {
    final context = _context;
    final logger = context.logger;

    if (!context.host.hasSecurityKeychain) {
      logger.err(
        'The passwords have nowhere to go: there is no login keychain on '
        '${context.host.label}.',
      );
      logger.info(
        'Generate the keystore with keytool and put the passwords in .env, '
        'which shipway reads everywhere.',
      );
      return ShipwayExit.environmentError;
    }

    final appId = context.appId ?? config.defaultAppId;
    final app = config.appOrNull(appId);
    if (app == null) {
      logger.err('No app to set up. Check `apps:` in shipway.yaml.');
      return ShipwayExit.userError;
    }

    final relative = results['keystore'] as String;
    final path = p.join(context.projectRoot, relative);
    final alias = results['alias'] as String;

    // Existing refs win: a team that already named its variables keeps them,
    // and the wizard fills the gap rather than renaming what works.
    final existing = app.signing.android;
    final keystoreRef = existing?.keystoreRef ?? 'ANDROID_KEYSTORE_BASE64';
    final storePasswordRef =
        existing?.keyProperties?.storePasswordRef ?? 'ANDROID_STORE_PASSWORD';
    final keyPasswordRef =
        existing?.keyProperties?.keyPasswordRef ?? 'ANDROID_KEY_PASSWORD';

    final password = await _password(results);
    if (password == null) return ShipwayExit.userError;

    final creator = KeystoreCreator(
      runner: context.runner,
      redactor: context.redactor,
    );
    try {
      await creator.create(
        path: path,
        alias: alias,
        password: password,
        commonName: config.project.name,
      );
    } on KeystoreFailure catch (failure) {
      logger.err(failure.message);
      final hint = failure.fixHint;
      if (hint != null) logger.info(hint);
      return ShipwayExit.userError;
    }
    logger.info('Created $relative (alias $alias).');

    // PKCS12, which modern keytool writes, shares one password between the
    // store and the key. Storing it under both names is not duplication — it
    // is what `key.properties` and the CI workflow each read.
    final store = SecretStore(
      runner: context.runner,
      redactor: context.redactor,
      host: context.host,
    );
    try {
      await store.set(storePasswordRef, password);
      await store.set(keyPasswordRef, password);
      // So `secrets check --env ci` is answerable locally, and so the value
      // to paste into GitHub exists somewhere other than a shell history.
      await store.set(keystoreRef, base64.encode(File(path).readAsBytesSync()));
    } on SecretStoreFailure catch (failure) {
      logger.err(failure.message);
      return ShipwayExit.environmentError;
    }
    logger.info(
      'Stored $storePasswordRef, $keyPasswordRef and $keystoreRef in the '
      'login keychain.',
    );

    _writeKeyProperties(
      relative: relative,
      alias: alias,
      password: password,
      storePasswordRef: storePasswordRef,
      keyPasswordRef: keyPasswordRef,
    );
    logger.info('Wrote android/key.properties (git-ignored).');

    _recordInConfig(
      appId: appId!,
      keystoreRef: keystoreRef,
      storePasswordRef: storePasswordRef,
      keyPasswordRef: keyPasswordRef,
      alias: alias,
    );
    logger.info('Recorded the names in shipway.yaml. No value is in it.');

    _reportGradleWiring(logger);

    logger
      ..info('')
      ..info('Next:')
      ..info('  shipway secrets check     — everything should resolve now')
      ..info('  shipway secrets export    — what to set on the CI repository')
      ..info('')
      ..warn(
        'Back up $relative somewhere that is not this repository. An app on '
        'Play cannot be updated without it.',
      );
    return ShipwayExit.success;
  }

  /// The keystore password: generated unless one is piped in.
  ///
  /// Generated by default because a keystore password is typed once and read
  /// by a machine forever after, so a memorable one buys nothing and costs
  /// entropy.
  Future<String?> _password(ArgResults results) async {
    if (!(results['password-stdin'] as bool)) {
      return KeystoreCreator.generatePassword();
    }
    final piped = (await stdin.transform(utf8.decoder).join()).trim();
    if (piped.isEmpty) {
      _context.logger.err('--password-stdin was given but nothing arrived.');
      return null;
    }
    return piped;
  }

  /// `android/key.properties`, which Gradle reads to sign a release build.
  ///
  /// `storeFile` is relative to `android/app`, which is where Gradle resolves
  /// it from — an absolute path would work on this machine and nowhere else,
  /// and a path relative to the repository root fails silently by resolving to
  /// a file that is not there.
  void _writeKeyProperties({
    required String relative,
    required String alias,
    required String password,
    required String storePasswordRef,
    required String keyPasswordRef,
  }) {
    final fromAppModule = p.relative(
      p.join(_context.projectRoot, relative),
      from: p.join(_context.projectRoot, 'android', 'app'),
    );
    final file = File(p.join(_context.projectRoot, 'android', 'key.properties'))
      ..parent.createSync(recursive: true);
    file.writeAsStringSync('''
# Written by `shipway setup android-signing`. Git-ignored, and it holds
# passwords: it must stay that way.
#
# The same values live in the login keychain as $storePasswordRef and
# $keyPasswordRef. On CI this file is rebuilt from repository secrets, so it
# is never committed and never uploaded.
storeFile=$fromAppModule
storePassword=$password
keyPassword=$password
keyAlias=$alias
''');
  }

  void _recordInConfig({
    required String appId,
    required String keystoreRef,
    required String storePasswordRef,
    required String keyPasswordRef,
    required String alias,
  }) {
    final file = File(
      _context.configPath ?? p.join(_context.projectRoot, 'shipway.yaml'),
    );
    final base = <String>['apps', appId, 'signing', 'android'];
    file.writeAsStringSync(
      ConfigPatch.setAll(file.readAsStringSync(), <List<String>, Object?>{
        <String>[...base, 'keystore_ref']: keystoreRef,
        <String>[...base, 'key_properties', 'store_password_ref']:
            storePasswordRef,
        <String>[...base, 'key_properties', 'key_password_ref']: keyPasswordRef,
        <String>[...base, 'key_properties', 'key_alias']: alias,
      }),
    );
  }

  /// Says the one thing this command cannot do for you.
  ///
  /// Writing `key.properties` signs nothing on its own: Gradle has to be told
  /// to read it. A project generated by recent Flutter already is, and one
  /// that is not would build a release with the debug key — which uploads,
  /// installs, and is rejected by Play.
  void _reportGradleWiring(Logger logger) {
    final module = p.join(_context.projectRoot, 'android', 'app');
    final candidates = <File>[
      File(p.join(module, 'build.gradle.kts')),
      File(p.join(module, 'build.gradle')),
    ].where((f) => f.existsSync());

    if (candidates.isEmpty) {
      logger.warn('No android/app build file found, so nothing reads it yet.');
      return;
    }
    final wired = candidates.any(
      (f) => f.readAsStringSync().contains('key.properties'),
    );
    if (wired) return;

    logger
      ..info('')
      ..warn(
        'Your Gradle build does not read key.properties, so a release build '
        'would still be signed with the debug key — which installs, uploads, '
        'and is rejected by Play.',
      )
      ..info(
        'Add a signingConfig that loads it, then point buildTypes.release at '
        'that config. shipway does not edit this file for you: it is the one '
        'that decides how your app is signed.',
      );
  }
}

/// Where one flavor's Firebase config comes from, and the app it names.
class _FlavorFirebase {
  const _FlavorFirebase({
    this.androidPath,
    this.androidAppId,
    this.iosPath,
    this.iosAppId,
  });

  final String? androidPath;
  final String? androidAppId;
  final String? iosPath;
  final String? iosAppId;

  String? pathFor(String platform) =>
      platform == 'android' ? androidPath : iosPath;

  String? appIdFor(String platform) =>
      platform == 'android' ? androidAppId : iosAppId;
}
