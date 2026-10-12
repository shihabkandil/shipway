import 'dart:io';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../notify/message_template.dart';
import 'config_exception.dart';
import 'secret_ref_validator.dart';
import 'shipway_config.dart';

/// Loads and validates `shipway.yaml`.
///
/// Three passes, in order of how cheaply they fail: YAML syntax, schema shape
/// (via `checked_yaml`, which carries line/column), then semantic rules that a
/// schema cannot express.
abstract final class ConfigLoader {
  static const String defaultFileName = 'shipway.yaml';

  /// The highest schema version this build understands.
  static const int supportedVersion = 1;

  /// Finds `shipway.yaml` at [root], or null.
  static File? locate(String root) {
    for (final name in const [defaultFileName, 'shipway.yml']) {
      final file = File(p.join(root, name));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Parses [content] as a config originating from [path].
  static ShipwayConfig parse(String content, {String path = defaultFileName}) {
    final ShipwayConfig config;
    try {
      config = checkedYamlDecode<ShipwayConfig>(
        content,
        (m) {
          if (m == null) {
            throw ConfigException(
              'is empty. Run `shipway init` or `shipway import` to create one.',
              path: path,
            );
          }
          return ShipwayConfig.fromJson(m);
        },
        sourceUrl: Uri.file(path),
        allowNull: true,
      );
    } on ParsedYamlException catch (e) {
      throw _fromParsedYaml(e, path);
    } on YamlException catch (e) {
      throw ConfigException(
        e.message,
        path: path,
        line: e.span?.start.line == null ? null : e.span!.start.line + 1,
        column: e.span?.start.column == null ? null : e.span!.start.column + 1,
      );
    }

    _validate(config, path);
    return config;
  }

  /// Reads and parses the config at [file].
  static Future<ShipwayConfig> load(File file) async {
    if (!file.existsSync()) {
      throw ConfigException(
        'No config found.',
        path: file.path,
        hint:
            'Run `shipway import` in an existing project, or `shipway init` '
            'to start one.',
      );
    }
    return parse(await file.readAsString(), path: file.path);
  }

  /// Semantic rules the schema cannot express.
  static void _validate(ShipwayConfig config, String path) {
    if (config.version != supportedVersion) {
      throw ConfigException(
        'Unsupported config version ${config.version}.',
        path: path,
        hint:
            'This shipway understands version $supportedVersion. '
            'Upgrade shipway, or set `version: $supportedVersion`.',
      );
    }
    if (config.apps.isEmpty) {
      throw ConfigException(
        '`apps` is empty; declare at least one app.',
        path: path,
        hint:
            'A single-app repo conventionally uses `apps:\n  main:\n    path: .`',
      );
    }
    if (config.defaultAppId == null) {
      throw ConfigException(
        'Several apps are declared and none is named `main`, so shipway cannot '
        'tell which to act on by default.',
        path: path,
        hint: 'Name one of them `main`, or pass `--app <id>` on every command.',
      );
    }

    for (final entry in config.apps.entries) {
      final app = entry.value;
      final flavors = app.flavors;
      // Distinct suffixes matter more than distinct names: two flavors sharing
      // a suffix produce two builds with one application id, and the second
      // silently replaces the first on a device.
      final bySuffix = <String, String>{};
      for (final flavor in flavors.entries) {
        if (!_flavorNameShape.hasMatch(flavor.key)) {
          throw ConfigException(
            'Flavor `${flavor.key}` in app `${entry.key}` is not a valid name.',
            path: path,
            hint:
                'Flavor names must start with a letter and contain only '
                'letters and digits. Both Gradle and Xcode build configuration '
                'names are derived from them, and Flutter matches them '
                'case-sensitively.',
          );
        }
        final existing = bySuffix[flavor.value.suffix];
        if (existing != null) {
          throw ConfigException(
            'Flavors `$existing` and `${flavor.key}` in app `${entry.key}` '
            'both use suffix "${flavor.value.suffix}".',
            path: path,
            hint:
                'Each flavor needs a distinct application id, or installing '
                'one will replace the other on a device.',
          );
        }
        bySuffix[flavor.value.suffix] = flavor.key;
      }

      final play = app.targets.play;
      if (play != null) {
        final rollout = play.rollout;
        if (rollout != null && (rollout <= 0 || rollout > 1)) {
          throw ConfigException(
            '`rollout` must be between 0 (exclusive) and 1, got $rollout.',
            path: path,
            hint: 'It is a user fraction: 0.1 means 10% of users.',
          );
        }
        // A rollout used to be rejected here unless `release_status` was
        // `inProgress`. That was wrong: `supply` sets the status itself, on
        // both the upload and the promote path, so the pair shipway refused is
        // one that works. Refusing a working config is a worse failure than an
        // unclear one; the effective status is shown by `release --dry-run`
        // instead. See doc/deploy-targets.md.
      }

      if (app.crashlytics.obfuscate && !app.crashlytics.uploadSymbols) {
        throw ConfigException(
          'app `${entry.key}` sets `crashlytics.obfuscate: true` without '
          '`upload_symbols`.',
          path: path,
          hint:
              'An obfuscated crash cannot be read without its symbols. Set '
              'crashlytics.upload_symbols to true as well.',
        );
      }

      // Uploads fine and then fails at distribution, which is after the
      // slowest part of the job — so it is caught here instead.
      final testflight = app.targets.testflight;
      if (testflight != null &&
          testflight.distributeExternal &&
          testflight.groups.isEmpty) {
        throw ConfigException(
          'app `${entry.key}` sets `distribute_external: true` with no '
          '`groups`.',
          path: path,
          hint:
              'TestFlight needs a group to distribute to. Add one under '
              'targets.testflight.groups, or set distribute_external to false.',
        );
      }
    }

    final violations = SecretRefValidator.validate(config);
    if (violations.isNotEmpty) {
      final detail = violations
          .map((v) => '  ${v.path} ${v.reason}')
          .join('\n');
      throw ConfigException(
        'A `*_ref` field holds a secret instead of naming one:\n$detail',
        path: path,
        hint:
            'Every `*_ref` names an environment variable or keychain key. '
            'Move the value out of this file — it is committed to your repo.',
      );
    }

    _validateNotify(config.notify, path);
  }

  /// Every rule here is about a notification that would otherwise fail at the
  /// worst moment — after the release it was meant to report.
  static void _validateNotify(NotifyConfig notify, String path) {
    if (notify.slackBotTokenRef != null && notify.slackChannel == null) {
      throw ConfigException(
        '`notify.slack_bot_token_ref` is set with no `slack_channel`.',
        path: path,
        hint:
            'A bot can post anywhere it is invited, so it has to be told '
            'where. Add `slack_channel: C0123ABCD` (or `#releases` for a '
            'public channel).',
      );
    }
    if (notify.slackChannel != null && notify.slackBotTokenRef == null) {
      throw ConfigException(
        '`notify.slack_channel` is set with no `slack_bot_token_ref`.',
        path: path,
        hint:
            'An incoming webhook always posts to the channel it was created '
            'for, so this would be ignored. Remove it, or add '
            '`slack_bot_token_ref` to post as a bot.',
      );
    }
    if (notify.on.isEmpty) {
      throw ConfigException(
        '`notify.on` is an empty list, so nothing would ever be sent.',
        path: path,
        hint: 'Remove the `notify` block, or list at least one event.',
      );
    }
    if (!notify.hasSlack && !notify.messages.isEmpty) {
      throw ConfigException(
        '`notify.messages` is set, but there is nowhere to send them.',
        path: path,
        hint: 'Add `slack_webhook_ref` or `slack_bot_token_ref`.',
      );
    }

    for (final event in NotifyEvent.values) {
      final template = notify.messages.of(event);
      if (template == null) continue;
      final unknown = MessageTemplate.unknownIn(template);
      if (unknown.isEmpty) continue;
      throw ConfigException(
        '`notify.messages.${event.name}` uses '
        '${unknown.map((u) => '{$u}').join(', ')}, which '
        '${unknown.length == 1 ? 'is not a placeholder' : 'are not '
                  'placeholders'}.',
        path: path,
        hint:
            'Available: '
            '${MessageTemplate.placeholders.keys.map((k) => '{$k}').join(' ')}',
      );
    }
  }

  static final RegExp _flavorNameShape = RegExp(r'^[A-Za-z][A-Za-z0-9]*$');

  static ConfigException _fromParsedYaml(ParsedYamlException e, String path) {
    // A syntax-level failure is wrapped and carries no node, so fall back to
    // the inner YamlException's span rather than dropping the location.
    final span =
        e.yamlNode?.span ??
        (e.innerError is YamlException
            ? (e.innerError! as YamlException).span
            : null);
    return ConfigException(
      _humanise(e),
      path: path,
      line: span == null ? null : span.start.line + 1,
      column: span == null ? null : span.start.column + 1,
    );
  }

  /// Turns generator-speak into something a user can act on.
  static String _humanise(ParsedYamlException e) {
    final inner = e.innerError;
    if (inner is UnrecognizedKeysException) {
      return 'Unrecognised ${inner.unrecognizedKeys.length == 1 ? 'key' : 'keys'} '
          '${inner.unrecognizedKeys.map((k) => '`$k`').join(', ')}. '
          'Allowed here: ${inner.allowedKeys.map((k) => '`$k`').join(', ')}.';
    }
    if (inner is MissingRequiredKeysException) {
      return 'Missing required '
          '${inner.missingKeys.length == 1 ? 'key' : 'keys'} '
          '${inner.missingKeys.map((k) => '`$k`').join(', ')}.';
    }
    if (inner is CheckedFromJsonException) {
      final key = inner.key;
      final message = inner.message;
      if (message != null) return '`$key`: $message';
      return '`$key` has the wrong type or an unexpected value.';
    }
    return e.message;
  }
}
