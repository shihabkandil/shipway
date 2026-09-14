import '../core/config/shipway_config.dart';
import '../core/env/run_environment.dart';
import '../core/secrets/secret_names.dart';

/// How badly a secret is needed.
enum Need {
  /// A lane cannot run without it.
  required,

  /// Used when set, harmless when not — an override, or an alternative to a
  /// value the config already carries.
  optional,
}

/// One secret the project needs, and what needs it.
class SecretRequirement {
  const SecretRequirement({
    required this.name,
    required this.need,
    required this.wantedBy,
    this.isPath = false,
    this.targets = const <String>{},
  });

  /// The environment-variable name.
  final String name;

  final Need need;

  /// What asks for it, phrased so the answer to "why do I need this?" is in
  /// the report rather than in someone's head — a config path where the name
  /// came from a `*_ref`, or the lane that reads it.
  final String wantedBy;

  /// True when the value is a path to a file, so presence means the file
  /// exists rather than merely that the variable is set. A service-account
  /// variable pointing at a file that is not there is the same failure as an
  /// unset one, discovered later.
  final bool isPath;

  /// Which release targets need this, by id — `testflight`, `appstore`,
  /// `play`, `firebase`.
  ///
  /// Empty means "not tied to one destination", which is the honest answer for
  /// things like a keychain password. Scoping matters because demanding an App
  /// Store Connect key before a Play upload is noise, and noise in a
  /// pre-flight is how people learn to ignore it.
  final Set<String> targets;

  bool get isRequired => need == Need.required;

  /// Whether this is worth checking before shipping to [target].
  bool appliesTo(String? target) =>
      target == null || targets.isEmpty || targets.contains(target);
}

/// Works out which secrets a config implies.
///
/// This is the payoff of the `*_ref` convention: because `shipway.yaml` names
/// every credential rather than holding one, the complete list of what a
/// project needs can be derived from it. One derivation then drives the
/// pre-flight check, the listing, and — later — the generated CI `env:` block.
abstract final class SecretRequirements {
  /// Everything [config] implies, for [environment].
  ///
  /// The environment matters because some entries are only meaningful in one:
  /// a keychain password is needed exactly where shipway creates a keychain,
  /// and an Apple ID is an interactive-login fallback a runner must never take.
  static List<SecretRequirement> of(
    ShipwayConfig config, {
    required RunEnvironment environment,
    String? appId,
    String? flavor,
  }) {
    final app = config.appOrNull(appId ?? config.defaultAppId);
    if (app == null) return const <SecretRequirement>[];

    final requirements = <SecretRequirement>[];
    void add(
      String name,
      Need need,
      String wantedBy, {
      bool isPath = false,
      Set<String> targets = const <String>{},
    }) => requirements.add(
      SecretRequirement(
        name: name,
        need: need,
        wantedBy: wantedBy,
        isPath: isPath,
        targets: targets,
      ),
    );

    /// Every Apple destination, since signing is shared between them.
    const apple = <String>{'testflight', 'appstore'};

    /// Every Android destination: both need a signed artifact.
    const androidTargets = <String>{'play', 'firebase'};

    final iosSigning = app.signing.ios;
    final shipsIos = app.shipsIos;
    if (iosSigning?.matchGitUrl != null) {
      add(
        SecretNames.matchPassword,
        Need.required,
        'the certificates lane, to decrypt the match repository',
        targets: apple,
      );
      add(
        SecretNames.matchGitUrl,
        Need.optional,
        'overrides signing.ios.match_git_url',
        targets: apple,
      );
      add(
        SecretNames.matchGitBranch,
        Need.optional,
        'the match repository',
        targets: apple,
      );

      // A runner has neither a credential helper nor an SSH agent, so the
      // clone needs an explicit credential. Which one depends on the URL,
      // and they are mutually exclusive in match.
      if (!environment.mayPrompt) {
        final url = iosSigning!.matchGitUrl!;
        final overSsh = url.startsWith('git@') || url.startsWith('ssh://');
        add(
          overSsh
              ? SecretNames.matchGitPrivateKey
              : SecretNames.matchGitBasicAuthorization,
          Need.required,
          overSsh
              ? 'cloning the match repository over SSH'
              : 'cloning the match repository over HTTPS',
          targets: apple,
        );
      }
    }

    // Named in the config, so the variable is only a fallback for it.
    add(
      SecretNames.developerPortalTeamId,
      iosSigning?.teamId == null && shipsIos ? Need.required : Need.optional,
      iosSigning?.teamId == null
          ? 'the iOS export, which has no signing.ios.team_id to fall back on'
          : 'overrides signing.ios.team_id',
      targets: apple,
    );

    final apiKey = iosSigning?.apiKey;
    for (final entry in <String, String?>{
      'signing.ios.api_key.key_id_ref': apiKey?.keyIdRef,
      'signing.ios.api_key.issuer_id_ref': apiKey?.issuerIdRef,
      'signing.ios.api_key.p8_ref': apiKey?.p8Ref,
    }.entries) {
      final name = entry.value;
      if (name != null) {
        add(name, Need.required, entry.key, targets: apple);
      }
    }

    // Only useful for the interactive login path, which is exactly the path a
    // runner must not take.
    if (environment.mayPrompt) {
      add(
        SecretNames.appleId,
        Need.optional,
        'interactive App Store Connect login',
        targets: apple,
      );
      add(
        SecretNames.appStoreConnectTeamId,
        Need.optional,
        'interactive App Store Connect login',
        targets: apple,
      );
    }

    final android = app.signing.android;
    if (android?.keystoreRef != null) {
      add(
        android!.keystoreRef!,
        Need.required,
        'signing.android.keystore_ref',
        targets: androidTargets,
      );
    }
    final keyProperties = android?.keyProperties;
    for (final entry in <String, String?>{
      'signing.android.key_properties.store_password_ref':
          keyProperties?.storePasswordRef,
      'signing.android.key_properties.key_password_ref':
          keyProperties?.keyPasswordRef,
    }.entries) {
      final name = entry.value;
      if (name != null) {
        add(name, Need.required, entry.key, targets: androidTargets);
      }
    }

    if (app.targets.play != null) {
      add(
        app.targets.play!.serviceAccountRef ??
            SecretNames.playServiceAccountPath,
        Need.required,
        'the play lane',
        isPath: app.targets.play!.serviceAccountRef == null,
        targets: const <String>{'play'},
      );
    }

    final firebase = app.targets.firebase;
    if (firebase != null) {
      // Per flavor, because flavors in separate Firebase projects carry
      // separate accounts. Scoped to [flavor] when one is being shipped;
      // otherwise every flavor's, which is what a CI repository needs.
      final names = flavor != null
          ? <String>[flavor]
          : (app.flavors.isEmpty ? const <String>[''] : app.flavors.keys);
      for (final name in names) {
        final account = app.firebaseServiceAccountVariable(name);
        add(
          account,
          Need.required,
          account == SecretNames.firebaseServiceAccountPath
              ? 'the firebase lane'
              : 'flavors.$name.firebase.distribution.service_account_ref',
          isPath: true,
          targets: const <String>{'firebase'},
        );
        final appId = app.firebaseAndroidAppIdVariable(name);
        if (appId != null) {
          add(
            appId,
            Need.required,
            appId == firebase.androidAppIdRef
                ? 'targets.firebase.android_app_id_ref'
                : 'flavors.$name.firebase.distribution.android_app_id_ref',
            targets: const <String>{'firebase'},
          );
        }
      }

      // Optional until something reads it. There is no iOS App Distribution
      // lane yet, so requiring it would fail a build for a variable nothing
      // asks for — the same shape of wrong as checking a name no lane reads.
      final iosAppId = firebase.iosAppIdRef;
      if (iosAppId != null) {
        add(
          iosAppId,
          Need.optional,
          'targets.firebase.ios_app_id_ref; no iOS lane reads it yet',
          targets: const <String>{'firebase'},
        );
      }
    }

    // Optional both: a notification that cannot be sent is a warning, never a
    // reason to refuse a release.
    final slack = config.notify.slackWebhookRef;
    if (slack != null) add(slack, Need.optional, 'notify.slack_webhook_ref');
    final bot = config.notify.slackBotTokenRef;
    if (bot != null) {
      add(bot, Need.optional, 'notify.slack_bot_token_ref, for live updates');
    }

    // shipway creates a keychain exactly where it may not use the login one.
    if (!environment.mayUseLoginKeychain && shipsIos) {
      add(
        SecretNames.keychainPassword,
        Need.optional,
        'the keychain shipway creates off-workstation; generated when unset',
      );
    }

    return _deduplicate(requirements);
  }

  /// Keeps the strongest need and the first reason when a name is asked for
  /// twice, so a variable that is optional in one place and required in
  /// another is reported as required.
  static List<SecretRequirement> _deduplicate(
    List<SecretRequirement> requirements,
  ) {
    final byName = <String, SecretRequirement>{};
    for (final requirement in requirements) {
      final existing = byName[requirement.name];
      if (existing == null) {
        byName[requirement.name] = requirement;
        continue;
      }
      if (!existing.isRequired && requirement.isRequired) {
        byName[requirement.name] = requirement;
      }
    }
    return byName.values.toList()..sort((a, b) {
      if (a.isRequired != b.isRequired) return a.isRequired ? -1 : 1;
      return a.name.compareTo(b.name);
    });
  }
}
