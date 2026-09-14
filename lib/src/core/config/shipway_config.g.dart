// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shipway_config.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ShipwayConfig _$ShipwayConfigFromJson(
  Map json,
) => $checkedCreate('ShipwayConfig', json, ($checkedConvert) {
  $checkKeys(
    json,
    allowedKeys: const [
      'version',
      'project',
      'apps',
      'secrets',
      'notify',
      'ci',
      'pipelines',
    ],
  );
  final val = ShipwayConfig(
    version: $checkedConvert('version', (v) => (v as num).toInt()),
    project: $checkedConvert(
      'project',
      (v) => ProjectConfig.fromJson(v as Map),
    ),
    apps: $checkedConvert('apps', (v) => _appsFromJson(v as Map)),
    secrets: $checkedConvert(
      'secrets',
      (v) =>
          v == null ? const SecretsConfig() : SecretsConfig.fromJson(v as Map),
    ),
    notify: $checkedConvert(
      'notify',
      (v) => v == null ? const NotifyConfig() : NotifyConfig.fromJson(v as Map),
    ),
    ci: $checkedConvert(
      'ci',
      (v) => v == null ? const CiConfig() : CiConfig.fromJson(v as Map),
    ),
    pipelines: $checkedConvert(
      'pipelines',
      (v) => v == null ? const <String, dynamic>{} : _rawMap(v as Map?),
    ),
  );
  return val;
});

Map<String, dynamic> _$ShipwayConfigToJson(ShipwayConfig instance) =>
    <String, dynamic>{
      'version': instance.version,
      'project': instance.project.toJson(),
      'apps': instance.apps.map((k, e) => MapEntry(k, e.toJson())),
      'secrets': instance.secrets.toJson(),
      'notify': instance.notify.toJson(),
      'ci': instance.ci.toJson(),
      'pipelines': instance.pipelines,
    };

ProjectConfig _$ProjectConfigFromJson(Map json) =>
    $checkedCreate('ProjectConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['name', 'pubspec', 'flutter_min']);
      final val = ProjectConfig(
        name: $checkedConvert('name', (v) => v as String),
        pubspec: $checkedConvert(
          'pubspec',
          (v) => v as String? ?? 'pubspec.yaml',
        ),
        flutterMin: $checkedConvert('flutter_min', (v) => v as String?),
      );
      return val;
    }, fieldKeyMap: const {'flutterMin': 'flutter_min'});

Map<String, dynamic> _$ProjectConfigToJson(ProjectConfig instance) =>
    <String, dynamic>{
      'name': instance.name,
      'pubspec': instance.pubspec,
      'flutter_min': ?instance.flutterMin,
    };

AppConfig _$AppConfigFromJson(Map json) => $checkedCreate('AppConfig', json, (
  $checkedConvert,
) {
  $checkKeys(
    json,
    allowedKeys: const [
      'path',
      'android',
      'ios',
      'flavors',
      'signing',
      'targets',
      'versioning',
    ],
  );
  final val = AppConfig(
    path: $checkedConvert('path', (v) => v as String? ?? '.'),
    android: $checkedConvert(
      'android',
      (v) => v == null ? null : AndroidAppConfig.fromJson(v as Map),
    ),
    ios: $checkedConvert(
      'ios',
      (v) => v == null ? null : IosAppConfig.fromJson(v as Map),
    ),
    flavors: $checkedConvert(
      'flavors',
      (v) => v == null
          ? const <String, FlavorConfig>{}
          : _flavorsFromJson(v as Map),
    ),
    signing: $checkedConvert(
      'signing',
      (v) =>
          v == null ? const SigningConfig() : SigningConfig.fromJson(v as Map),
    ),
    targets: $checkedConvert(
      'targets',
      (v) =>
          v == null ? const TargetsConfig() : TargetsConfig.fromJson(v as Map),
    ),
    versioning: $checkedConvert(
      'versioning',
      (v) => v == null
          ? const VersioningConfig()
          : VersioningConfig.fromJson(v as Map),
    ),
  );
  return val;
});

Map<String, dynamic> _$AppConfigToJson(AppConfig instance) => <String, dynamic>{
  'path': instance.path,
  'android': ?instance.android?.toJson(),
  'ios': ?instance.ios?.toJson(),
  'flavors': instance.flavors.map((k, e) => MapEntry(k, e.toJson())),
  'signing': instance.signing.toJson(),
  'targets': instance.targets.toJson(),
  'versioning': instance.versioning.toJson(),
};

AndroidAppConfig _$AndroidAppConfigFromJson(Map json) =>
    $checkedCreate('AndroidAppConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['application_id']);
      final val = AndroidAppConfig(
        applicationId: $checkedConvert('application_id', (v) => v as String?),
      );
      return val;
    }, fieldKeyMap: const {'applicationId': 'application_id'});

Map<String, dynamic> _$AndroidAppConfigToJson(AndroidAppConfig instance) =>
    <String, dynamic>{'application_id': ?instance.applicationId};

IosAppConfig _$IosAppConfigFromJson(Map json) =>
    $checkedCreate('IosAppConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['bundle_id', 'export']);
      final val = IosAppConfig(
        bundleId: $checkedConvert('bundle_id', (v) => v as String?),
        export: $checkedConvert(
          'export',
          (v) => $enumDecodeNullable(_$IosExportEnumMap, v) ?? IosExport.gym,
        ),
      );
      return val;
    }, fieldKeyMap: const {'bundleId': 'bundle_id'});

Map<String, dynamic> _$IosAppConfigToJson(IosAppConfig instance) =>
    <String, dynamic>{
      'bundle_id': ?instance.bundleId,
      'export': _$IosExportEnumMap[instance.export]!,
    };

const _$IosExportEnumMap = {IosExport.gym: 'gym', IosExport.flutter: 'flutter'};

FlavorConfig _$FlavorConfigFromJson(Map json) => $checkedCreate(
  'FlavorConfig',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'suffix',
        'version_name_suffix',
        'dimension',
        'display_name',
        'entrypoint',
        'dart_defines',
        'icon',
        'firebase',
      ],
    );
    final val = FlavorConfig(
      suffix: $checkedConvert('suffix', (v) => v as String? ?? ''),
      versionNameSuffix: $checkedConvert(
        'version_name_suffix',
        (v) => v as String?,
      ),
      dimension: $checkedConvert('dimension', (v) => v as String?),
      displayName: $checkedConvert('display_name', (v) => v as String?),
      entrypoint: $checkedConvert('entrypoint', (v) => v as String?),
      dartDefines: $checkedConvert(
        'dart_defines',
        (v) =>
            (v as Map?)?.map((k, e) => MapEntry(k as String, e as String)) ??
            const <String, String>{},
      ),
      icon: $checkedConvert('icon', (v) => v as String?),
      firebase: $checkedConvert(
        'firebase',
        (v) => v == null ? null : FirebaseFlavorConfig.fromJson(v as Map),
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'versionNameSuffix': 'version_name_suffix',
    'displayName': 'display_name',
    'dartDefines': 'dart_defines',
  },
);

Map<String, dynamic> _$FlavorConfigToJson(FlavorConfig instance) =>
    <String, dynamic>{
      'suffix': instance.suffix,
      'version_name_suffix': ?instance.versionNameSuffix,
      'dimension': ?instance.dimension,
      'display_name': ?instance.displayName,
      'entrypoint': ?instance.entrypoint,
      'dart_defines': instance.dartDefines,
      'icon': ?instance.icon,
      'firebase': ?instance.firebase?.toJson(),
    };

FirebaseFlavorConfig _$FirebaseFlavorConfigFromJson(Map json) =>
    $checkedCreate('FirebaseFlavorConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['android', 'ios']);
      final val = FirebaseFlavorConfig(
        android: $checkedConvert('android', (v) => v as String?),
        ios: $checkedConvert('ios', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$FirebaseFlavorConfigToJson(
  FirebaseFlavorConfig instance,
) => <String, dynamic>{'android': ?instance.android, 'ios': ?instance.ios};

SigningConfig _$SigningConfigFromJson(Map json) =>
    $checkedCreate('SigningConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['ios', 'android']);
      final val = SigningConfig(
        ios: $checkedConvert(
          'ios',
          (v) => v == null ? null : IosSigningConfig.fromJson(v as Map),
        ),
        android: $checkedConvert(
          'android',
          (v) => v == null ? null : AndroidSigningConfig.fromJson(v as Map),
        ),
      );
      return val;
    });

Map<String, dynamic> _$SigningConfigToJson(SigningConfig instance) =>
    <String, dynamic>{
      'ios': ?instance.ios?.toJson(),
      'android': ?instance.android?.toJson(),
    };

IosSigningConfig _$IosSigningConfigFromJson(Map json) => $checkedCreate(
  'IosSigningConfig',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'match_git_url',
        'match_storage',
        'team_id',
        'api_key',
      ],
    );
    final val = IosSigningConfig(
      matchGitUrl: $checkedConvert('match_git_url', (v) => v as String?),
      matchStorage: $checkedConvert(
        'match_storage',
        (v) =>
            $enumDecodeNullable(_$MatchStorageEnumMap, v) ?? MatchStorage.git,
      ),
      teamId: $checkedConvert('team_id', (v) => v as String?),
      apiKey: $checkedConvert(
        'api_key',
        (v) => v == null ? null : AscApiKeyConfig.fromJson(v as Map),
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'matchGitUrl': 'match_git_url',
    'matchStorage': 'match_storage',
    'teamId': 'team_id',
    'apiKey': 'api_key',
  },
);

Map<String, dynamic> _$IosSigningConfigToJson(IosSigningConfig instance) =>
    <String, dynamic>{
      'match_git_url': ?instance.matchGitUrl,
      'match_storage': _$MatchStorageEnumMap[instance.matchStorage]!,
      'team_id': ?instance.teamId,
      'api_key': ?instance.apiKey?.toJson(),
    };

const _$MatchStorageEnumMap = {
  MatchStorage.git: 'git',
  MatchStorage.googlecloud: 'googlecloud',
  MatchStorage.s3: 's3',
};

AscApiKeyConfig _$AscApiKeyConfigFromJson(Map json) => $checkedCreate(
  'AscApiKeyConfig',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const ['key_id_ref', 'issuer_id_ref', 'p8_ref'],
    );
    final val = AscApiKeyConfig(
      keyIdRef: $checkedConvert('key_id_ref', (v) => v as String?),
      issuerIdRef: $checkedConvert('issuer_id_ref', (v) => v as String?),
      p8Ref: $checkedConvert('p8_ref', (v) => v as String?),
    );
    return val;
  },
  fieldKeyMap: const {
    'keyIdRef': 'key_id_ref',
    'issuerIdRef': 'issuer_id_ref',
    'p8Ref': 'p8_ref',
  },
);

Map<String, dynamic> _$AscApiKeyConfigToJson(AscApiKeyConfig instance) =>
    <String, dynamic>{
      'key_id_ref': ?instance.keyIdRef,
      'issuer_id_ref': ?instance.issuerIdRef,
      'p8_ref': ?instance.p8Ref,
    };

AndroidSigningConfig _$AndroidSigningConfigFromJson(Map json) => $checkedCreate(
  'AndroidSigningConfig',
  json,
  ($checkedConvert) {
    $checkKeys(json, allowedKeys: const ['keystore_ref', 'key_properties']);
    final val = AndroidSigningConfig(
      keystoreRef: $checkedConvert('keystore_ref', (v) => v as String?),
      keyProperties: $checkedConvert(
        'key_properties',
        (v) => v == null ? null : KeyPropertiesConfig.fromJson(v as Map),
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'keystoreRef': 'keystore_ref',
    'keyProperties': 'key_properties',
  },
);

Map<String, dynamic> _$AndroidSigningConfigToJson(
  AndroidSigningConfig instance,
) => <String, dynamic>{
  'keystore_ref': ?instance.keystoreRef,
  'key_properties': ?instance.keyProperties?.toJson(),
};

KeyPropertiesConfig _$KeyPropertiesConfigFromJson(Map json) => $checkedCreate(
  'KeyPropertiesConfig',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'store_password_ref',
        'key_password_ref',
        'key_alias',
      ],
    );
    final val = KeyPropertiesConfig(
      storePasswordRef: $checkedConvert(
        'store_password_ref',
        (v) => v as String?,
      ),
      keyPasswordRef: $checkedConvert('key_password_ref', (v) => v as String?),
      keyAlias: $checkedConvert('key_alias', (v) => v as String? ?? 'upload'),
    );
    return val;
  },
  fieldKeyMap: const {
    'storePasswordRef': 'store_password_ref',
    'keyPasswordRef': 'key_password_ref',
    'keyAlias': 'key_alias',
  },
);

Map<String, dynamic> _$KeyPropertiesConfigToJson(
  KeyPropertiesConfig instance,
) => <String, dynamic>{
  'store_password_ref': ?instance.storePasswordRef,
  'key_password_ref': ?instance.keyPasswordRef,
  'key_alias': instance.keyAlias,
};

TargetsConfig _$TargetsConfigFromJson(Map json) =>
    $checkedCreate('TargetsConfig', json, ($checkedConvert) {
      $checkKeys(
        json,
        allowedKeys: const ['testflight', 'appstore', 'play', 'firebase'],
      );
      final val = TargetsConfig(
        testflight: $checkedConvert(
          'testflight',
          (v) => v == null ? null : TestflightTarget.fromJson(v as Map),
        ),
        appstore: $checkedConvert(
          'appstore',
          (v) => v == null ? null : AppstoreTarget.fromJson(v as Map),
        ),
        play: $checkedConvert(
          'play',
          (v) => v == null ? null : PlayTarget.fromJson(v as Map),
        ),
        firebase: $checkedConvert(
          'firebase',
          (v) => v == null ? null : FirebaseTarget.fromJson(v as Map),
        ),
      );
      return val;
    });

Map<String, dynamic> _$TargetsConfigToJson(TargetsConfig instance) =>
    <String, dynamic>{
      'testflight': ?instance.testflight?.toJson(),
      'appstore': ?instance.appstore?.toJson(),
      'play': ?instance.play?.toJson(),
      'firebase': ?instance.firebase?.toJson(),
    };

TestflightTarget _$TestflightTargetFromJson(Map json) => $checkedCreate(
  'TestflightTarget',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const ['groups', 'distribute_external', 'changelog_from'],
    );
    final val = TestflightTarget(
      groups: $checkedConvert(
        'groups',
        (v) =>
            (v as List<dynamic>?)?.map((e) => e as String).toList() ??
            const <String>[],
      ),
      distributeExternal: $checkedConvert(
        'distribute_external',
        (v) => v as bool? ?? false,
      ),
      changelogFrom: $checkedConvert(
        'changelog_from',
        (v) =>
            $enumDecodeNullable(_$ChangelogSourceEnumMap, v) ??
            ChangelogSource.git,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'distributeExternal': 'distribute_external',
    'changelogFrom': 'changelog_from',
  },
);

Map<String, dynamic> _$TestflightTargetToJson(TestflightTarget instance) =>
    <String, dynamic>{
      'groups': instance.groups,
      'distribute_external': instance.distributeExternal,
      'changelog_from': _$ChangelogSourceEnumMap[instance.changelogFrom]!,
    };

const _$ChangelogSourceEnumMap = {
  ChangelogSource.git: 'git',
  ChangelogSource.file: 'file',
  ChangelogSource.prompt: 'prompt',
};

AppstoreTarget _$AppstoreTargetFromJson(Map json) => $checkedCreate(
  'AppstoreTarget',
  json,
  ($checkedConvert) {
    $checkKeys(json, allowedKeys: const ['submit_for_review', 'metadata_path']);
    final val = AppstoreTarget(
      submitForReview: $checkedConvert(
        'submit_for_review',
        (v) => v as bool? ?? false,
      ),
      metadataPath: $checkedConvert('metadata_path', (v) => v as String?),
    );
    return val;
  },
  fieldKeyMap: const {
    'submitForReview': 'submit_for_review',
    'metadataPath': 'metadata_path',
  },
);

Map<String, dynamic> _$AppstoreTargetToJson(AppstoreTarget instance) =>
    <String, dynamic>{
      'submit_for_review': instance.submitForReview,
      'metadata_path': ?instance.metadataPath,
    };

PlayTarget _$PlayTargetFromJson(Map json) => $checkedCreate(
  'PlayTarget',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'track',
        'release_status',
        'rollout',
        'artifact',
        'service_account_ref',
      ],
    );
    final val = PlayTarget(
      track: $checkedConvert(
        'track',
        (v) => $enumDecodeNullable(_$PlayTrackEnumMap, v) ?? PlayTrack.internal,
      ),
      releaseStatus: $checkedConvert(
        'release_status',
        (v) =>
            $enumDecodeNullable(_$PlayReleaseStatusEnumMap, v) ??
            PlayReleaseStatus.draft,
      ),
      rollout: $checkedConvert('rollout', (v) => (v as num?)?.toDouble()),
      artifact: $checkedConvert(
        'artifact',
        (v) =>
            $enumDecodeNullable(_$PlayArtifactEnumMap, v) ?? PlayArtifact.aab,
      ),
      serviceAccountRef: $checkedConvert(
        'service_account_ref',
        (v) => v as String?,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'releaseStatus': 'release_status',
    'serviceAccountRef': 'service_account_ref',
  },
);

Map<String, dynamic> _$PlayTargetToJson(PlayTarget instance) =>
    <String, dynamic>{
      'track': _$PlayTrackEnumMap[instance.track]!,
      'release_status': _$PlayReleaseStatusEnumMap[instance.releaseStatus]!,
      'rollout': ?instance.rollout,
      'artifact': _$PlayArtifactEnumMap[instance.artifact]!,
      'service_account_ref': ?instance.serviceAccountRef,
    };

const _$PlayTrackEnumMap = {
  PlayTrack.internal: 'internal',
  PlayTrack.alpha: 'alpha',
  PlayTrack.beta: 'beta',
  PlayTrack.production: 'production',
};

const _$PlayReleaseStatusEnumMap = {
  PlayReleaseStatus.draft: 'draft',
  PlayReleaseStatus.completed: 'completed',
  PlayReleaseStatus.inProgress: 'inProgress',
  PlayReleaseStatus.halted: 'halted',
};

const _$PlayArtifactEnumMap = {
  PlayArtifact.aab: 'aab',
  PlayArtifact.apk: 'apk',
};

FirebaseTarget _$FirebaseTargetFromJson(Map json) => $checkedCreate(
  'FirebaseTarget',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'android_app_id_ref',
        'ios_app_id_ref',
        'groups',
        'changelog_from',
      ],
    );
    final val = FirebaseTarget(
      androidAppIdRef: $checkedConvert(
        'android_app_id_ref',
        (v) => v as String?,
      ),
      iosAppIdRef: $checkedConvert('ios_app_id_ref', (v) => v as String?),
      groups: $checkedConvert(
        'groups',
        (v) =>
            (v as List<dynamic>?)?.map((e) => e as String).toList() ??
            const <String>[],
      ),
      changelogFrom: $checkedConvert(
        'changelog_from',
        (v) =>
            $enumDecodeNullable(_$ChangelogSourceEnumMap, v) ??
            ChangelogSource.git,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'androidAppIdRef': 'android_app_id_ref',
    'iosAppIdRef': 'ios_app_id_ref',
    'changelogFrom': 'changelog_from',
  },
);

Map<String, dynamic> _$FirebaseTargetToJson(FirebaseTarget instance) =>
    <String, dynamic>{
      'android_app_id_ref': ?instance.androidAppIdRef,
      'ios_app_id_ref': ?instance.iosAppIdRef,
      'groups': instance.groups,
      'changelog_from': _$ChangelogSourceEnumMap[instance.changelogFrom]!,
    };

VersioningConfig _$VersioningConfigFromJson(Map json) =>
    $checkedCreate('VersioningConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['strategy', 'sync_ios_android']);
      final val = VersioningConfig(
        strategy: $checkedConvert(
          'strategy',
          (v) =>
              $enumDecodeNullable(_$VersioningStrategyEnumMap, v) ??
              VersioningStrategy.increment,
        ),
        syncIosAndroid: $checkedConvert(
          'sync_ios_android',
          (v) => v as bool? ?? true,
        ),
      );
      return val;
    }, fieldKeyMap: const {'syncIosAndroid': 'sync_ios_android'});

Map<String, dynamic> _$VersioningConfigToJson(VersioningConfig instance) =>
    <String, dynamic>{
      'strategy': _$VersioningStrategyEnumMap[instance.strategy]!,
      'sync_ios_android': instance.syncIosAndroid,
    };

const _$VersioningStrategyEnumMap = {
  VersioningStrategy.timestamp: 'timestamp',
  VersioningStrategy.increment: 'increment',
  VersioningStrategy.remote: 'remote',
};

SecretsConfig _$SecretsConfigFromJson(Map json) => $checkedCreate(
  'SecretsConfig',
  json,
  ($checkedConvert) {
    $checkKeys(json, allowedKeys: const ['dotenv', 'keychain']);
    final val = SecretsConfig(
      dotenv: $checkedConvert('dotenv', (v) => v as String? ?? '.env.{flavor}'),
      keychain: $checkedConvert('keychain', (v) => v as bool? ?? true),
    );
    return val;
  },
);

Map<String, dynamic> _$SecretsConfigToJson(SecretsConfig instance) =>
    <String, dynamic>{'dotenv': instance.dotenv, 'keychain': instance.keychain};

CiConfig _$CiConfigFromJson(Map json) =>
    $checkedCreate('CiConfig', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['environment']);
      final val = CiConfig(
        environment: $checkedConvert('environment', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$CiConfigToJson(CiConfig instance) => <String, dynamic>{
  'environment': ?instance.environment,
};

NotifyConfig _$NotifyConfigFromJson(Map json) => $checkedCreate(
  'NotifyConfig',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'slack_webhook_ref',
        'slack_bot_token_ref',
        'slack_channel',
        'on',
        'messages',
      ],
    );
    final val = NotifyConfig(
      slackWebhookRef: $checkedConvert(
        'slack_webhook_ref',
        (v) => v as String?,
      ),
      slackBotTokenRef: $checkedConvert(
        'slack_bot_token_ref',
        (v) => v as String?,
      ),
      slackChannel: $checkedConvert('slack_channel', (v) => v as String?),
      on: $checkedConvert(
        'on',
        (v) => v == null
            ? const <NotifyEvent>{NotifyEvent.failure}
            : _notifyEventsFromJson(v),
      ),
      messages: $checkedConvert(
        'messages',
        (v) => v == null
            ? const NotifyMessages()
            : NotifyMessages.fromJson(v as Map),
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'slackWebhookRef': 'slack_webhook_ref',
    'slackBotTokenRef': 'slack_bot_token_ref',
    'slackChannel': 'slack_channel',
  },
);

Map<String, dynamic> _$NotifyConfigToJson(NotifyConfig instance) =>
    <String, dynamic>{
      'slack_webhook_ref': ?instance.slackWebhookRef,
      'slack_bot_token_ref': ?instance.slackBotTokenRef,
      'slack_channel': ?instance.slackChannel,
      'on': _notifyEventsToJson(instance.on),
      'messages': instance.messages.toJson(),
    };

NotifyMessages _$NotifyMessagesFromJson(Map json) =>
    $checkedCreate('NotifyMessages', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['started', 'success', 'failure']);
      final val = NotifyMessages(
        started: $checkedConvert('started', (v) => v as String?),
        success: $checkedConvert('success', (v) => v as String?),
        failure: $checkedConvert('failure', (v) => v as String?),
      );
      return val;
    });

Map<String, dynamic> _$NotifyMessagesToJson(NotifyMessages instance) =>
    <String, dynamic>{
      'started': ?instance.started,
      'success': ?instance.success,
      'failure': ?instance.failure,
    };
