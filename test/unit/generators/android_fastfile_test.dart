import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/generators/android_fastfile_generator.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:test/test.dart';

ResolvedApp app({
  String? androidApplicationId = 'com.acme.app',
  PlayTarget? play,
  FirebaseTarget? firebase,
  AndroidSigningConfig? signing,
  bool flavors = true,
}) => ResolvedApp(
  appId: 'main',
  projectName: 'acme_app',
  androidApplicationId: androidApplicationId,
  iosBundleId: 'com.acme.app',
  gradleDsl: GradleDsl.kotlin,
  play: play,
  firebase: firebase,
  androidSigning: signing,
  flavors: !flavors
      ? const <ResolvedFlavor>[]
      : <ResolvedFlavor>[
          ResolvedFlavor(
            name: 'dev',
            suffix: '.dev',
            entrypoint: 'lib/main_dev.dart',
            dimension: 'environment',
            androidApplicationId: androidApplicationId == null
                ? null
                : '$androidApplicationId.dev',
            firebaseAndroid: 'android/app/src/dev/google-services.json',
          ),
        ],
);

String render(ResolvedApp resolved) =>
    const AndroidFastfileGenerator().render(resolved).single.contents;

void main() {
  group('when it produces nothing', () {
    test('a project with no flavors', () {
      expect(
        const AndroidFastfileGenerator().render(app(flavors: false)),
        isEmpty,
      );
    });

    test('a project whose package name is unknown', () {
      // Lanes with nothing to upload against are worse than no lanes: they
      // look configured.
      expect(
        const AndroidFastfileGenerator().render(
          app(androidApplicationId: null),
        ),
        isEmpty,
      );
    });
  });

  group('the build lane', () {
    test('always passes the flavor entrypoint', () {
      // Same silent failure as iOS: without --target, Flutter builds
      // lib/main.dart under this flavor's package name and succeeds.
      final fastfile = render(app());
      expect(fastfile, contains('entrypoint: "lib/main_dev.dart"'));
      expect(fastfile, contains('--target #{entrypoint.shellescape}'));
    });

    test('passes dart-defines only when the file is there', () {
      expect(render(app()), contains('File.exist?(defines)'));
    });

    test('checks the artifact actually appeared', () {
      // A Flutter build that reports success and produces nothing means the
      // Gradle flavor is named differently than the config thinks.
      expect(
        render(app()),
        contains('The build reported success but produced no artifact.'),
      );
    });

    test('guards key.properties only when signing is configured', () {
      expect(
        render(
          app(
            signing: const AndroidSigningConfig(
              keystoreRef: 'ANDROID_KEYSTORE_BASE64',
            ),
          ),
        ),
        contains('android/key.properties'),
      );
      expect(render(app()), isNot(contains('key.properties')));
    });

    test('uses the variant paths Gradle actually writes', () {
      final fastfile = render(app());
      expect(
        fastfile,
        contains(
          'build/app/outputs/bundle/#{flavor}Release/app-#{flavor}-release.aab',
        ),
      );
      expect(
        fastfile,
        contains('build/app/outputs/flutter-apk/app-#{flavor}-release.apk'),
      );
    });
  });

  group('the play lane', () {
    test('defaults to the internal track as a draft', () {
      final fastfile = render(app());
      expect(fastfile, contains('track: options.fetch(:track, "internal")'));
      expect(fastfile, contains('release_status: "draft"'));
    });

    test('carries the configured track, status and rollout', () {
      final fastfile = render(
        app(
          play: const PlayTarget(
            track: PlayTrack.beta,
            releaseStatus: PlayReleaseStatus.inProgress,
            rollout: 0.1,
          ),
        ),
      );
      expect(fastfile, contains('"beta"'));
      // supply spells this one in camelCase, unlike every other option.
      expect(fastfile, contains('release_status: "inProgress"'));
      expect(fastfile, contains('rollout: "0.1"'));
    });

    test('uploads the configured artifact and skips the other', () {
      final aab = render(app());
      expect(aab, contains('aab: artifact'));
      expect(aab, contains('skip_upload_apk: true'));

      final apk = render(
        app(play: const PlayTarget(artifact: PlayArtifact.apk)),
      );
      expect(apk, contains('apk: artifact'));
      expect(apk, contains('skip_upload_aab: true'));
    });

    test('never touches the store listing', () {
      // Metadata belongs to whoever writes it, not to a build.
      final fastfile = render(app());
      for (final skip in const <String>[
        'skip_upload_metadata: true',
        // Separate from metadata — supply's own description says "changelogs
        // not included" — and `metadata_path` defaults to any
        // fastlane/metadata/android directory it finds. Without this an upload
        // silently overwrites the release notes somebody wrote.
        'skip_upload_changelogs: true',
        'skip_upload_images: true',
        'skip_upload_screenshots: true',
      ]) {
        expect(fastfile, contains(skip));
      }
    });
  });

  group('the promote lane', () {
    test('uploads nothing', () {
      // Promotion is the cheap, common operation. Making it a flag on the
      // upload lane would mean rebuilding an artifact Play already has.
      final fastfile = render(app());
      expect(fastfile, contains('track_promote_to: to'));
      expect(fastfile, contains('skip_upload_apk: true'));
      expect(fastfile, contains('skip_upload_aab: true'));
    });

    test('refuses without a destination track', () {
      expect(render(app()), contains('Pass to:'));
    });

    test('checks arguments before credentials', () {
      // Being told to configure a service account when the real problem is a
      // missing `to:` sends people the wrong way.
      final fastfile = render(app());
      final lane = fastfile.substring(fastfile.indexOf('lane :promote'));
      expect(lane.indexOf('Pass to:'), lessThan(lane.indexOf('require_env')));
    });

    test('validates the rollout range itself', () {
      expect(render(app()), contains('rollout must be between 0 and 1'));
    });

    test('leaves the store listing alone', () {
      final fastfile = render(app());
      final lane = fastfile.substring(fastfile.indexOf('lane :promote'));
      expect(lane, contains('skip_upload_changelogs: true'));
      expect(lane, contains('skip_upload_metadata: true'));
    });

    test('never passes a release status alongside a rollout', () {
      // supply derives the status from the fraction. Passing one as well
      // would only let the two disagree.
      final fastfile = render(app());
      final lane = fastfile.substring(fastfile.indexOf('lane :promote'));
      expect(lane, isNot(contains('release_status')));
    });
  });

  group('the firebase lane', () {
    String firebase(FirebaseTarget target) => render(app(firebase: target));

    /// Just the lane, so an assertion about it cannot be satisfied by a
    /// helper defined elsewhere in the file.
    String lane(String fastfile) {
      final start = fastfile.indexOf('lane :firebase');
      return fastfile.substring(start, fastfile.indexOf('\n  end\n', start));
    }

    test('is absent unless targets.firebase is configured', () {
      expect(render(app()), isNot(contains('lane :firebase')));
      expect(render(app()), isNot(contains('google_services:')));
    });

    test('needs no app id variable', () {
      // It used to be left out, silently, unless android_app_id_ref was set:
      // a config asked for Firebase and the Fastfile had no way to get there.
      final fastfile = firebase(const FirebaseTarget());
      expect(fastfile, contains('lane :firebase'));
      expect(
        fastfile,
        contains('google_services: "android/app/src/dev/google-services.json"'),
      );
      expect(fastfile, contains('mobilesdk_app_id'));
      // Matched on the package: one file lists every app in the project.
      expect(fastfile, contains('== config[:package_name]'));
    });

    test('a configured app id variable is authoritative', () {
      final fastfile = firebase(
        const FirebaseTarget(androidAppIdRef: 'FB_ANDROID_APP_ID'),
      );
      expect(fastfile, contains('require_env("FB_ANDROID_APP_ID")'));
      expect(fastfile, isNot(contains('mobilesdk_app_id')));
    });

    test('an app id handed to the lane wins', () {
      // How `shipway release` makes the id it printed the id it uses.
      expect(firebase(const FirebaseTarget()), contains('options[:app_id]'));
    });

    test('uses a service account, never the deprecated token', () {
      final fastfile = firebase(const FirebaseTarget());
      expect(fastfile, contains('service_credentials_file:'));
      expect(fastfile, isNot(contains('firebase_cli_token')));
    });

    test('distributes to the configured groups and invents none', () {
      expect(
        firebase(const FirebaseTarget(groups: <String>['testers', 'qa'])),
        contains('groups: "testers,qa"'),
      );
      // A made-up default group fails in any project that has no group by
      // that name, and only after the build.
      expect(
        lane(firebase(const FirebaseTarget())),
        isNot(contains('groups:')),
      );
    });

    test('spells the artifact type the way the plugin does', () {
      final fastfile = lane(firebase(const FirebaseTarget()));
      expect(fastfile, contains('type == "appbundle" ? "AAB" : "APK"'));
      expect(fastfile, isNot(contains('.upcase')));
    });

    test('resolves the app and the notes before building', () {
      final fastfile = lane(firebase(const FirebaseTarget()));
      final build = fastfile.indexOf('artifact = build(');
      expect(fastfile.indexOf('firebase_app_id('), lessThan(build));
      expect(fastfile.indexOf('firebase_release_notes('), lessThan(build));
    });

    test('takes its notes from changelog_from', () {
      expect(
        firebase(const FirebaseTarget(changelogFrom: ChangelogSource.file)),
        contains('# targets.firebase.changelog_from: file'),
      );
      expect(
        lane(firebase(const FirebaseTarget())),
        contains('release_notes: notes ||'),
      );
    });

    test('passes a requested version through to the build', () {
      final fastfile = lane(firebase(const FirebaseTarget()));
      expect(fastfile, contains('version_name: options[:version_name]'));
      expect(fastfile, contains('build_number: options[:build_number]'));
    });
  });

  test('no credential is ever written into the file', () {
    final fastfile = render(
      app(
        play: const PlayTarget(serviceAccountRef: 'PLAY_JSON'),
        firebase: const FirebaseTarget(androidAppIdRef: 'FB_ANDROID_APP_ID'),
        signing: const AndroidSigningConfig(
          keystoreRef: 'ANDROID_KEYSTORE_BASE64',
        ),
      ),
    );
    for (final pattern in const <Pattern>[
      '-----BEGIN',
      'AIza',
      'AKIA',
      '"private_key"',
    ]) {
      expect(fastfile, isNot(contains(pattern)));
    }
    // Everything sensitive arrives through the environment.
    expect(fastfile, contains('ENV.fetch("PLAY_JSON")'));
  });

  group('which variable the play lane reads', () {
    /// The pre-flight derives this name from the config, so a lane that reads
    /// a different one is the exact failure `secret_names.dart` exists to
    /// prevent: `secrets check` reports green and `supply` fails at the upload
    /// with an authentication error naming nothing.
    test('the configured ref, passed as content', () {
      final fastfile = render(
        app(play: const PlayTarget(serviceAccountRef: 'PLAY_JSON')),
      );

      expect(fastfile, contains('require_env("PLAY_JSON")'));
      // The variable holds the JSON, so there is no file to point at.
      expect(fastfile, contains('json_key_data: ENV.fetch("PLAY_JSON")'));
      expect(fastfile, isNot(contains('json_key: ')));
    });

    test('the path convention when the config names nothing', () {
      final fastfile = render(app(play: const PlayTarget()));

      expect(
        fastfile,
        contains(
          'json_key: ENV.fetch("${AndroidFastfileGenerator.playKeyEnv}")',
        ),
      );
      expect(fastfile, isNot(contains('json_key_data')));
    });
  });
}
