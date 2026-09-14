import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/generators/version_resolver.dart';
import 'package:test/test.dart';

String render(
  VersioningStrategy strategy, {
  String platform = 'ios',
  bool sync = true,
}) => VersionResolver.render(
  strategy: strategy,
  syncIosAndroid: sync,
  platform: platform,
);

void main() {
  test('the marketing version always comes from pubspec', () {
    // A version name is a decision somebody makes, not something to derive.
    for (final strategy in VersioningStrategy.values) {
      final ruby = render(strategy);
      expect(ruby, contains('def version_name'), reason: strategy.name);
      expect(ruby, contains('pubspec_version[:name]'), reason: strategy.name);
    }
  });

  test('an unreadable pubspec version fails with what to fix', () {
    // Every release needs a version to claim, and the regex failing silently
    // would produce a build numbered nil.
    expect(render(VersioningStrategy.increment), contains('user_error!'));
    expect(render(VersioningStrategy.increment), contains('version: x.y.z+n'));
  });

  test('an explicit build number always wins', () {
    // Whatever the strategy, passing one is how a re-run reuses a number
    // rather than minting a fresh one the store has never heard of.
    for (final strategy in VersioningStrategy.values) {
      for (final platform in const <String>['ios', 'android']) {
        final ruby = render(strategy, platform: platform);
        expect(
          ruby,
          contains('def build_number(requested'),
          reason: '${strategy.name}/$platform',
        );
        expect(
          ruby,
          contains('value = requested.to_s.strip'),
          reason: '${strategy.name}/$platform takes no requested value',
        );
      }
    }
  });

  group('increment', () {
    test('takes pubspec at its word', () {
      final ruby = render(VersioningStrategy.increment);
      expect(ruby, contains('pubspec_version[:code]'));
      // Nothing remote: this is the strategy that works offline.
      expect(ruby, isNot(contains('latest_testflight_build_number')));
      expect(ruby, isNot(contains('google_play_track_version_codes')));
    });
  });

  group('timestamp', () {
    test('is monotonic without asking anything', () {
      final ruby = render(VersioningStrategy.timestamp);
      expect(ruby, contains('%y%m%d%H%M'));
      // UTC, or a build made either side of a timezone change goes backwards.
      expect(ruby, contains('Time.now.utc'));
    });
  });

  group('remote', () {
    test('iOS asks App Store Connect', () {
      final ruby = render(VersioningStrategy.remote);
      expect(ruby, contains('latest_testflight_build_number'));
      // A brand new app has no builds; without this the first upload fails.
      expect(ruby, contains('initial_build_number: 0'));
      expect(ruby, contains('latest.to_i + 1'));
    });

    test('Android asks Play, and takes the highest code', () {
      // `.first` is what the plan said. The API does not promise an order, and
      // the wrong element produces a code Play rejects as non-increasing.
      final ruby = render(VersioningStrategy.remote, platform: 'android');
      expect(ruby, contains('google_play_track_version_codes'));
      expect(ruby, contains('.max.to_i + 1'));
      // The expression, not the prose: the comment above it names `.first`
      // precisely because that is the trap.
      expect(ruby, isNot(contains('codes[0]')));
      expect(ruby, isNot(contains('codes.first')));
    });

    test('Android reads the service account by the shared name', () {
      expect(
        render(VersioningStrategy.remote, platform: 'android'),
        contains('ENV.fetch("PLAY_SERVICE_ACCOUNT_JSON_PATH")'),
      );
    });

    test('Android asks every standard track, not just the target one', () {
      // Play refuses a code not higher than every code the app has used, and
      // the highest is usually on production.
      final ruby = render(VersioningStrategy.remote, platform: 'android');
      expect(ruby, contains('%w[internal alpha beta production] + tracks'));
    });

    test('Android stops when no track answers, rather than guessing 1', () {
      final ruby = render(VersioningStrategy.remote, platform: 'android');
      expect(ruby, contains('failures.length == names.length'));
      expect(ruby, contains('Could not read version codes from Play'));
    });

    test('Android asks Play with the credential the upload uses', () {
      final ruby = VersionResolver.render(
        strategy: VersioningStrategy.remote,
        syncIosAndroid: true,
        platform: 'android',
        playKey: (name: 'PLAY_JSON', parameter: 'json_key_data'),
      );
      expect(ruby, contains('json_key_data: ENV.fetch("PLAY_JSON")'));
    });

    test('each platform gets only its own lookup', () {
      // Rendering both would put an action in a Fastfile that cannot run it.
      expect(
        render(VersioningStrategy.remote, platform: 'ios'),
        isNot(contains('google_play_track_version_codes')),
      );
      expect(
        render(VersioningStrategy.remote, platform: 'android'),
        isNot(contains('latest_testflight_build_number')),
      );
    });
  });

  test('sync_ios_android is stated either way', () {
    expect(render(VersioningStrategy.increment, sync: true), contains('once'));
    expect(
      render(VersioningStrategy.increment, sync: false),
      contains('numbers itself'),
    );
  });

  group('Firebase', () {
    String firebase(VersioningStrategy strategy) => VersionResolver.render(
      strategy: strategy,
      syncIosAndroid: true,
      platform: 'android',
      firebase: true,
    );

    test('remote asks App Distribution for the app\'s latest release', () {
      final ruby = firebase(VersioningStrategy.remote);
      expect(ruby, contains('def firebase_build_number(requested'));
      expect(ruby, contains('firebase_app_distribution_get_latest_release'));
      // An app with no releases yet starts at 1.
      expect(ruby, contains('[:buildVersion]).to_i + 1'));
    });

    test('the other strategies number it like any release', () {
      for (final strategy in <VersioningStrategy>[
        VersioningStrategy.increment,
        VersioningStrategy.timestamp,
      ]) {
        final ruby = firebase(strategy);
        expect(
          ruby,
          contains('build_number(requested)'),
          reason: strategy.name,
        );
        expect(
          ruby,
          isNot(contains('firebase_app_distribution_get_latest_release')),
        );
      }
    });

    test('is only there when the Fastfile has a Firebase lane', () {
      expect(
        render(VersioningStrategy.remote, platform: 'android'),
        isNot(contains('firebase_build_number')),
      );
    });
  });
}
