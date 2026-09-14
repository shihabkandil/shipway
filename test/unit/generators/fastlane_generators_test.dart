import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/toolchain/fastlane_pins.dart';
import 'package:shipway/src/generators/fastfile_generator.dart';
import 'package:shipway/src/generators/fastlane_generators.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:test/test.dart';

ResolvedApp app({
  IosExport export = IosExport.gym,
  String? matchGitUrl,
  AscApiKeyConfig? apiKey,
  bool flavors = true,
}) => ResolvedApp(
  appId: 'main',
  projectName: 'acme_app',
  androidApplicationId: 'com.acme.app',
  iosBundleId: 'com.acme.app',
  gradleDsl: GradleDsl.kotlin,
  iosTeamId: 'ABCDE12345',
  iosExport: export,
  matchGitUrl: matchGitUrl,
  ascApiKey: apiKey,
  flavors: !flavors
      ? const <ResolvedFlavor>[]
      : const <ResolvedFlavor>[
          ResolvedFlavor(
            name: 'dev',
            suffix: '.dev',
            entrypoint: 'lib/main_dev.dart',
            dimension: 'environment',
            iosBundleId: 'com.acme.app.dev',
          ),
          ResolvedFlavor(
            name: 'prod',
            suffix: '',
            entrypoint: 'lib/main_prod.dart',
            dimension: 'environment',
            iosBundleId: 'com.acme.app',
          ),
        ],
);

String renderOne(Generator generator, ResolvedApp resolved, String path) =>
    generator.render(resolved).firstWhere((f) => f.path == path).contents;

void main() {
  group('Gemfile', () {
    test('pins fastlane rather than floating it', () {
      final gemfile = renderOne(const GemfileGenerator(), app(), 'ios/Gemfile');
      expect(gemfile, contains('gem "fastlane", "${FastlanePins.fastlane}"'));
      // A floated gem is a build that changes under you.
      expect(gemfile, isNot(contains('gem "fastlane"\n')));
      expect(gemfile, contains('ruby ">= ${FastlanePins.rubyFloor}"'));
    });

    test('caps google-apis-core, which nothing else does', () {
      // fastlane and the Firebase plugin both admit 1.x, and bundler picked it:
      // the field report's upload crashed on 1.1.0.
      final gemfile = renderOne(
        const GemfileGenerator(),
        app(),
        'android/Gemfile',
      );
      expect(gemfile, contains('gem "google-apis-core", ">= 0.18", "< 1"'));
    });

    test('plugins come from the Pluginfile, not a second gem line', () {
      // Declared in both places they drift; declared only in the Pluginfile
      // without this eval, fastlane reports plugins "couldn't be loaded" and
      // carries on without them.
      for (final platform in const <String>['ios', 'android']) {
        final gemfile = renderOne(
          const GemfileGenerator(),
          app(),
          '$platform/Gemfile',
        );
        expect(gemfile, contains('eval_gemfile(plugins_path)'));
        expect(
          gemfile,
          isNot(contains('gem "fastlane-plugin')),
          reason: '$platform/Gemfile duplicates the Pluginfile',
        );
      }
      expect(
        renderOne(
          const PluginfileGenerator(),
          app(),
          'ios/fastlane/Pluginfile',
        ),
        contains('fastlane-plugin-firebase_app_distribution'),
      );
    });
  });

  group('Matchfile', () {
    test('is not written at all without a match repo', () {
      // An empty Matchfile is worse than none: it makes match look configured.
      expect(const MatchfileGenerator().render(app()), isEmpty);
    });

    test('lists every flavor bundle id', () {
      final matchfile = renderOne(
        const MatchfileGenerator(),
        app(matchGitUrl: 'git@github.com:acme/certs.git'),
        'ios/fastlane/Matchfile',
      );
      expect(
        matchfile,
        contains('app_identifier(["com.acme.app.dev", "com.acme.app"])'),
      );
      expect(matchfile, contains('storage_mode("git")'));
      // Overridable, so one checkout can point at another repo.
      expect(matchfile, contains('ENV.fetch("MATCH_GIT_URL"'));
    });
  });

  group('ExportOptions plist', () {
    test('is written only when Flutter does the export', () {
      expect(
        const ExportOptionsGenerator().render(app(export: IosExport.gym)),
        isEmpty,
        reason: 'a stale plist beside a gym export is a trap',
      );
      expect(
        const ExportOptionsGenerator()
            .render(app(export: IosExport.flutter))
            .map((f) => f.path),
        <String>['ios/ExportOptions-dev.plist', 'ios/ExportOptions-prod.plist'],
      );
    });

    test('names the match profile and signs manually', () {
      final plist = renderOne(
        const ExportOptionsGenerator(),
        app(export: IosExport.flutter),
        'ios/ExportOptions-dev.plist',
      );
      expect(
        plist,
        contains('<string>match AppStore com.acme.app.dev</string>'),
      );
      // Automatic signing resolves to whatever the machine happens to have.
      expect(plist, contains('<string>manual</string>'));
      expect(plist, contains('<string>ABCDE12345</string>'));
    });
  });

  group('Fastfile', () {
    test('defaults to letting gym export the archive Flutter made', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(),
        IosFastfileGenerator.path,
      );

      expect(fastfile, contains('skip_build_archive: true'));
      expect(fastfile, contains('extra: ["--no-codesign"]'));
      // Required even when only exporting; without it gym prompts and a
      // non-interactive run hangs forever.
      expect(fastfile, contains('scheme: flavor'));
      expect(
        fastfile,
        contains('SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING'),
      );
    });

    test('the gym shape passes an export team id', () {
      // An archive built with --no-codesign records an empty Team, so export
      // has none to infer: without this the lane dies with
      // "exportArchive No Team Found in Archive". Found by running the lane,
      // not by reading it.
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(),
        IosFastfileGenerator.path,
      );
      expect(
        fastfile,
        contains(
          'export_team_id: ENV.fetch("DEVELOPER_PORTAL_TEAM_ID", '
          '"ABCDE12345")',
        ),
      );
    });

    test('a project with no configured team still resolves one at runtime', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        ResolvedApp(
          appId: 'main',
          projectName: 'acme_app',
          androidApplicationId: 'com.acme.app',
          iosBundleId: 'com.acme.app',
          gradleDsl: GradleDsl.kotlin,
          flavors: app().flavors,
        ),
        IosFastfileGenerator.path,
      );
      // No default to fall back on, so it must come from the environment or
      // fail saying so — never be omitted.
      expect(
        fastfile,
        contains('export_team_id: ENV.fetch("DEVELOPER_PORTAL_TEAM_ID")'),
      );
    });

    test('the flutter shape exports in one command and uses the plist', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(export: IosExport.flutter),
        IosFastfileGenerator.path,
      );

      expect(fastfile, contains('--export-options-plist='));
      expect(fastfile, isNot(contains('skip_build_archive')));
      expect(fastfile, isNot(contains('--no-codesign')));
      expect(fastfile, contains('flutter_build('));
    });

    test('never predicts the ipa filename', () {
      // Flutter names it after CFBundleDisplayName, gym after the product.
      for (final export in IosExport.values) {
        final fastfile = renderOne(
          const IosFastfileGenerator(),
          app(export: export),
          IosFastfileGenerator.path,
        );
        expect(fastfile, contains('Dir[root_path('), reason: export.name);
        // Only a file this build wrote: every flavor exports to the same
        // name, so any-match would upload the previous flavor's build.
        expect(
          fastfile,
          contains('exported_ipa(started)'),
          reason: export.name,
        );
        expect(
          fastfile,
          isNot(contains('Runner.ipa')),
          reason: 'hardcoding the name finds nothing under ${export.name}',
        );
      }
    });

    test('match is readonly unless explicitly asked otherwise', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(),
        IosFastfileGenerator.path,
      );
      expect(fastfile, contains('readonly: options.fetch(:readonly, true)'));
    });

    test(
      'a half-configured ASC key produces no key lane, not a broken one',
      () {
        final fastfile = renderOne(
          const IosFastfileGenerator(),
          app(apiKey: const AscApiKeyConfig(keyIdRef: 'ASC_KEY_ID')),
          IosFastfileGenerator.path,
        );
        // Rendering ENV.fetch("null") would fail at lane runtime with nothing
        // pointing back at the config that caused it.
        expect(fastfile, isNot(contains('null')));
        expect(fastfile, isNot(contains('app_store_connect_api_key')));
      },
    );

    test('a complete ASC key is read entirely from the environment', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(
          apiKey: const AscApiKeyConfig(
            keyIdRef: 'ASC_KEY_ID',
            issuerIdRef: 'ASC_ISSUER_ID',
            p8Ref: 'ASC_KEY_P8_BASE64',
          ),
        ),
        IosFastfileGenerator.path,
      );
      expect(fastfile, contains('ENV.fetch("ASC_KEY_ID")'));
      expect(fastfile, contains('ENV.fetch("ASC_KEY_P8_BASE64")'));
      expect(fastfile, contains('is_key_content_base64: true'));
    });

    test('produces nothing for a project with no flavors', () {
      expect(const IosFastfileGenerator().render(app(flavors: false)), isEmpty);
    });
  });

  group('the App Store lane', () {
    ResolvedApp withAppStore({bool submit = false, String? metadata}) =>
        ResolvedApp(
          appId: 'main',
          projectName: 'acme_app',
          androidApplicationId: 'com.acme.app',
          iosBundleId: 'com.acme.app',
          gradleDsl: GradleDsl.kotlin,
          iosTeamId: 'ABCDE12345',
          appstore: AppstoreTarget(
            submitForReview: submit,
            metadataPath: metadata,
          ),
          flavors: app().flavors,
        );

    test('is absent unless the config names that target', () {
      expect(
        renderOne(
          const IosFastfileGenerator(),
          app(),
          IosFastfileGenerator.path,
        ),
        isNot(contains('upload_to_app_store')),
      );
    });

    test('is a separate lane from beta', () {
      // TestFlight is a build going to testers; the App Store is a
      // submission. Sharing a lane would make the more consequential one a
      // flag on the other.
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        withAppStore(),
        IosFastfileGenerator.path,
      );
      expect(fastfile, contains('lane :beta'));
      expect(fastfile, contains('lane :release'));
    });

    test('never submits for review on its own', () {
      // Submitting is a decision a person makes, not something a tool does
      // because it could.
      expect(
        renderOne(
          const IosFastfileGenerator(),
          withAppStore(),
          IosFastfileGenerator.path,
        ),
        contains('submit_for_review: false'),
      );
      expect(
        renderOne(
          const IosFastfileGenerator(),
          withAppStore(submit: true),
          IosFastfileGenerator.path,
        ),
        contains('submit_for_review: true'),
      );
    });

    test('leaves the store listing alone unless given a metadata path', () {
      final without = renderOne(
        const IosFastfileGenerator(),
        withAppStore(),
        IosFastfileGenerator.path,
      );
      expect(without, contains('skip_metadata: true'));

      final with_ = renderOne(
        const IosFastfileGenerator(),
        withAppStore(metadata: 'ios/fastlane/metadata'),
        IosFastfileGenerator.path,
      );
      expect(with_, contains('ios/fastlane/metadata'));
      expect(with_, isNot(contains('skip_metadata: true')));
    });
  });

  group('the changelog', () {
    ResolvedApp withChangelog(ChangelogSource source) => ResolvedApp(
      appId: 'main',
      projectName: 'acme_app',
      androidApplicationId: 'com.acme.app',
      iosBundleId: 'com.acme.app',
      gradleDsl: GradleDsl.kotlin,
      iosTeamId: 'ABCDE12345',
      testflight: TestflightTarget(changelogFrom: source),
      flavors: app().flavors,
    );

    String render(ChangelogSource source) => renderOne(
      const IosFastfileGenerator(),
      withChangelog(source),
      IosFastfileGenerator.path,
    );

    test('reaches the upload at all', () {
      // The field has been in the schema from the beginning and nothing read
      // it: a config could ask for a changelog and silently get none.
      expect(render(ChangelogSource.git), contains('changelog: changelog'));
    });

    test('is resolved before the build', () {
      // So a changelog that cannot be produced fails in seconds rather than
      // after the slowest part of the job.
      final fastfile = render(ChangelogSource.git);
      expect(
        fastfile.indexOf('changelog = what_to_test'),
        lessThan(fastfile.indexOf('ipa = build_ipa(')),
      );
    });

    test('git survives a repository with no tags', () {
      // The first release has nothing to describe, and the action raises
      // rather than returning nothing. A failed upload is the wrong answer.
      final fastfile = render(ChangelogSource.git);
      expect(fastfile, contains('changelog_from_git_commits'));
      expect(fastfile, contains('rescue StandardError'));
    });

    test('file says which file, and copes without it', () {
      final fastfile = render(ChangelogSource.file);
      expect(fastfile, contains(IosFastfileGenerator.changelogFileName));
      expect(fastfile, contains('File.exist?'));
      expect(fastfile, isNot(contains('changelog_from_git_commits')));
    });

    test('prompt refuses to hang a runner', () {
      // A prompt on CI burns the job timeout and reports nothing.
      final fastfile = render(ChangelogSource.prompt);
      expect(fastfile, contains('if is_ci'));
      expect(fastfile, contains('user_error!'));
    });

    test('an explicit changelog always wins', () {
      for (final source in ChangelogSource.values) {
        expect(
          render(source),
          contains('return override unless override.to_s.strip.empty?'),
          reason: source.name,
        );
      }
    });
  });

  group('the version a release claims', () {
    test('is resolved before the build, not after', () {
      // Resolving afterwards is how a build ends up stamped with one number
      // and announced to the store with another.
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(),
        IosFastfileGenerator.path,
      );
      final resolve = fastfile.indexOf('number = build_number(');
      final build = fastfile.indexOf('ipa = build_ipa(');
      expect(resolve, isNot(-1));
      expect(resolve, lessThan(build));
    });

    test('reaches the artifact rather than only the upload', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(),
        IosFastfileGenerator.path,
      );
      expect(fastfile, contains('version_name: name'));
      expect(fastfile, contains('build_number: number'));
    });
  });

  group('no generated fastlane file may contain a credential', () {
    /// Shapes that mean somebody pasted a value where a name belongs.
    ///
    /// The plan requires this grep over *all* fastlane output, so it runs
    /// across every generator and both export shapes rather than one file.
    const patterns = <String, Pattern>{
      'a PEM block': '-----BEGIN',
      'a base64 p8 body': r'MIIE',
      'an App Store Connect issuer uuid':
          r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
      'a Google API key': 'AIza',
      'an AWS access key': 'AKIA',
      'a GitHub token': 'ghp_',
      'a Slack webhook': 'hooks.slack.com',
      'an assigned password':
          r'password\s*[:=]\s*["'
          "'"
          r']',
    };

    for (final export in IosExport.values) {
      test('under the ${export.name} export shape', () {
        final resolved = app(
          export: export,
          matchGitUrl: 'git@github.com:acme/certs.git',
          apiKey: const AscApiKeyConfig(
            keyIdRef: 'ASC_KEY_ID',
            issuerIdRef: 'ASC_ISSUER_ID',
            p8Ref: 'ASC_KEY_P8_BASE64',
          ),
        );

        final rendered = <GeneratedFile>[
          ...const GemfileGenerator().render(resolved),
          ...const PluginfileGenerator().render(resolved),
          ...const AppfileGenerator().render(resolved),
          ...const MatchfileGenerator().render(resolved),
          ...const ExportOptionsGenerator().render(resolved),
          ...const IosFastfileGenerator().render(resolved),
        ];
        expect(rendered, isNotEmpty);

        for (final file in rendered) {
          for (final entry in patterns.entries) {
            expect(
              file.contents,
              isNot(contains(entry.value)),
              reason: '${file.path} looks like it contains ${entry.key}',
            );
          }
        }
      });
    }

    test('every secret reaches a lane through ENV', () {
      final fastfile = renderOne(
        const IosFastfileGenerator(),
        app(
          apiKey: const AscApiKeyConfig(
            keyIdRef: 'ASC_KEY_ID',
            issuerIdRef: 'ASC_ISSUER_ID',
            p8Ref: 'ASC_KEY_P8_BASE64',
          ),
        ),
        IosFastfileGenerator.path,
      );

      // Anything named like a credential must appear as an ENV lookup, never
      // as an assigned literal.
      for (final name in const <String>[
        'ASC_KEY_ID',
        'ASC_ISSUER_ID',
        'ASC_KEY_P8_BASE64',
        'MATCH_PASSWORD',
      ]) {
        expect(
          fastfile,
          contains(RegExp('(ENV\\.fetch\\(|ENV\\[|require_env\\()"$name"')),
          reason: '$name must be read from the environment',
        );
      }
    });
  });
}
