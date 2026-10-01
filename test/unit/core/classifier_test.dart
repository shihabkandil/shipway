import 'package:shipway/src/core/errors/classifier.dart';
import 'package:test/test.dart';

void main() {
  /// Verbatim fragments of output produced by real tools during the Phase 2
  /// spike. Copied rather than paraphrased: a classifier tested against
  /// prose someone remembered writing matches nothing in the field.
  group('real output from the spike', () {
    void expectId(String output, String id) =>
        expect(ErrorClassifier.classify(output)?.id, id);

    test('gym exporting an archive built with --no-codesign', () {
      expectId(
        'error: exportArchive No Team Found in Archive\n'
            '** EXPORT FAILED **',
        'ios.export.no_team',
      );
    });

    test('an Xcode-managed profile used with manual signing', () {
      expectId(
        'error: exportArchive Provisioning profile "iOS Team Provisioning '
            'Profile: *" is Xcode managed, but signing settings require a '
            'manually managed profile.',
        'ios.export.xcode_managed_profile',
      );
    });

    test('gym archiving a Flutter app on a fresh clone', () {
      expectId(
        'xcodebuild: error: Could not resolve package dependencies:\n'
            "  the package at '/x/ios/Flutter/ephemeral/Packages/"
            "FlutterGeneratedPluginSwiftPackage' cannot be accessed "
            "(doesn't exist in file system)\n"
            'Exit status: 74',
        'ios.gym.missing_ephemeral',
      );
    });

    test('gym prompting for a scheme, which hangs rather than fails', () {
      expectId(
        '?  Ambiguous choice.  Please choose one of [1, 2, 3, Runner, dev, '
            'prod].',
        'ios.gym.scheme_prompt',
      );
    });

    test('codesign refused the key by ACL', () {
      expectId(
        '/x/App.framework/App: replacing existing signature\n'
            '/x/App.framework/App: errSecInternalComponent',
        'ios.codesign.key_acl',
      );
    });

    test('a Homebrew fastlane shadowing the bundled gems', () {
      expectId(
        'Could not find CFPropertyList-3.0.9, aws-sdk-s3-1.230.0 in locally '
            'installed gems (Bundler::GemNotFound)',
        'ruby.bundle_gem_missing',
      );
    });

    test('a gem pinned above what the Ruby floor allows', () {
      expectId(
        'So, because current Ruby version is = 3.1.1,\n'
            '  version solving has failed.',
        'ruby.version_solving_failed',
      );
    });

    test('fastlane warning about the Ruby version', () {
      expectId(
        'WARNING: Support for your Ruby version (3.1.1) is going away. '
            'fastlane will soon require Ruby 3.3.0 or newer.',
        'ruby.too_old_for_fastlane',
      );
    });

    test('a flavored build that silently lost its version numbers', () {
      // Flutter exits zero here, which is the entire problem.
      expectId(
        '[!] App Settings Validation\n'
            '    ! Version Number: Missing\n'
            '    ! Build Number: Missing\n'
            '    • Bundle Identifier: com.acme.app.dev',
        'ios.flavor.missing_version',
      );
    });
  });

  group('catalog signatures', () {
    test('a missing provisioning profile', () {
      expect(
        ErrorClassifier.classify(
          "error: No profiles for 'com.acme.app.dev' were found",
        )?.id,
        'ios.signing.no_profile',
      );
    });

    test('a wrong match passphrase', () {
      expect(
        ErrorClassifier.classify(
          'OpenSSL::Cipher::CipherError: wrong final block length',
        )?.id,
        'ios.match.wrong_password',
      );
    });

    test('a reused Play version code', () {
      expect(
        ErrorClassifier.classify(
          'Google Api Error: Version code has already been used.',
        )?.id,
        'play.version_code_used',
      );
    });

    test('a reused App Store Connect build number', () {
      expect(
        ErrorClassifier.classify(
          'The provided entity includes an attribute with a value that has '
          'already been used',
        )?.id,
        'asc.duplicate_build_number',
      );
    });

    test('a Play service account without permission', () {
      expect(
        ErrorClassifier.classify(
          'androidpublisher: Error 403: The caller does not have permission',
        )?.id,
        'play.permission_denied',
      );
    });
  });

  group('store failures', () {
    void expectId(String output, String id) =>
        expect(ErrorClassifier.classify(output)?.id, id);

    test('a package name Play does not know', () {
      expectId(
        'Google Api Error: applicationNotFound: No application was found',
        'play.app_not_found',
      );
    });

    test('a track Play does not know', () {
      expectId(
        "Google Api Error: 'alpha2' is not a valid track",
        'play.unknown_track',
      );
    });

    test('a rejected App Store Connect key', () {
      expectId(
        'App Store Connect API returned 401 NOT_AUTHORIZED',
        'asc.key_rejected',
      );
    });

    test('external distribution with no group', () {
      expectId(
        'distribute_external is true but no groups were provided',
        'testflight.external_without_groups',
      );
    });

    test('a reused Play version code names the strategy that fixes it', () {
      final diagnosis = ErrorClassifier.classify(
        'Google Api Error: Version code has already been used.',
      );
      expect(diagnosis?.fix, contains('remote'));
    });
  });

  group('a failure is read where it happened', () {
    String step(String name) => '[10:00:00]: --- Step: $name ---\n';

    test('a rejected key is recognised in a step that uses the key', () {
      for (final name in <String>[
        'app_store_connect_api_key',
        'upload_to_testflight',
        'pilot',
        'upload_to_app_store',
        'deliver',
        'latest_testflight_build_number',
        'sync_code_signing',
        'match',
      ]) {
        final report = ErrorClassifier.diagnose(
          '${step(name)}'
          '[10:00:01]: Authentication credentials are missing or invalid.\n'
          '\n'
          '[!] The request could not be completed\n',
        );
        expect(report.cause?.id, 'asc.key_rejected', reason: name);
      }
    });

    test('and not in a step that never talks to App Store Connect', () {
      final report = ErrorClassifier.diagnose(
        '${step('app_store_connect_api_key')}'
        '${step('cd /app && flutter build ipa')}'
        '[10:00:01]: ▸ App Store Connect API returned 401 NOT_AUTHORIZED\n'
        '\n'
        '[!] Exit status was 1\n',
      );
      expect(report.hasCause('asc.key_rejected'), isFalse);
      expect(report.recognised, isFalse);
    });

    test('nor from text outside the failing step', () {
      final report = ErrorClassifier.diagnose(
        '${step('sync_code_signing')}'
        '[10:00:01]: App Store Connect API returned 401 NOT_AUTHORIZED, '
        'retrying\n'
        '${step('upload_to_testflight')}'
        '[10:00:02]: uploading\n'
        '\n'
        '[!] The provided entity includes an attribute with a value that has '
        'already been used\n'
        '\n'
        'NOT_AUTHORIZED appears in a changelog down here\n',
      );
      expect(report.causes.map((d) => d.id), <String>[
        'asc.duplicate_build_number',
      ]);
    });

    test('match failing on its git remote is not a rejected key', () {
      final report = ErrorClassifier.diagnose(
        '${step('sync_code_signing')}'
        '[10:00:01]: fatal: Authentication failed for '
        "'https://github.com/acme/certs.git/'\n"
        '\n'
        '[!] Error cloning certificates repo, please make sure you have read '
        'access to the repository you want to use\n',
      );
      expect(report.hasCause('asc.key_rejected'), isFalse);
    });

    test('"invalid" near the API is not on its own a rejected key', () {
      // The wording of fastlane's changelog, which is what the old pattern
      // matched in the field.
      expect(
        ErrorClassifier.classify(
          '* [spaceship] retry App Store Connect API requests that fail with '
          'an invalid response body',
        ),
        isNull,
      );
    });

    test('an unrecognised failure has no cause rather than a near one', () {
      final report = ErrorClassifier.diagnose(
        '${step('build_app')}'
        '[10:00:01]: something nobody has seen before\n'
        '\n'
        '[!] It broke\n',
      );
      expect(report.recognised, isFalse);
      expect(report.cause, isNull);
      expect(report.attribution.errorLine, '[!] It broke');
    });

    test('output with no steps is classified whole, as it always was', () {
      final report = ErrorClassifier.diagnose(
        'Running Xcode build...\n'
        'error: exportArchive No Team Found in Archive\n'
        'App Store Connect API returned 401 NOT_AUTHORIZED',
      );
      expect(
        report.causes.map((d) => d.id),
        containsAll(<String>['ios.export.no_team', 'asc.key_rejected']),
      );
    });

    test('a stale spec repo is recognised by either wording', () {
      for (final wording in <String>[
        "Error: CocoaPods's specs repository is too out-of-date to satisfy "
            'dependencies.',
        '[!] CocoaPods could not find compatible versions for pod '
            '"FirebaseAnalytics":',
      ]) {
        expect(
          ErrorClassifier.classify(wording)?.id,
          ErrorClassifier.podSpecsOutOfDate,
        );
      }
    });

    test('nothing at all diagnoses to nothing', () {
      for (final output in <String?>[null, '']) {
        final report = ErrorClassifier.diagnose(output);
        expect(report.causes, isEmpty);
        expect(report.warnings, isEmpty);
      }
    });
  });

  group('warnings', () {
    test('are never a cause, wherever they are printed', () {
      final report = ErrorClassifier.diagnose(
        'WARNING: Support for your Ruby version (3.1.1) is going away.\n'
        'error: exportArchive No Team Found in Archive',
      );
      expect(report.causes.map((d) => d.id), <String>['ios.export.no_team']);
      expect(report.warnings.map((d) => d.id), <String>[
        'ruby.too_old_for_fastlane',
      ]);
    });

    test('come after causes when everything is asked for', () {
      final all = ErrorClassifier.classifyAll(
        'WARNING: Support for your Ruby version (3.1.1) is going away.\n'
        'error: exportArchive No Team Found in Archive',
      );
      expect(all.map((d) => d.id), <String>[
        'ios.export.no_team',
        'ruby.too_old_for_fastlane',
      ]);
    });

    test('the signatures that are warnings are the ones meant to be', () {
      // Changing a kind changes what is printed in red; do it on purpose.
      expect(
        <String>[
          for (final signature in ErrorClassifier.signatures)
            if (signature.kind == DiagnosisKind.warning) signature.id,
        ],
        unorderedEquals(<String>[
          'ruby.too_old_for_fastlane',
          'ios.flavor.missing_version',
        ]),
      );
    });
  });

  group('discipline', () {
    test('every id is unique', () {
      final ids = ErrorClassifier.ids;
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every signature says what to do, not just what happened', () {
      for (final signature in ErrorClassifier.signatures) {
        expect(signature.fix.trim(), isNotEmpty, reason: signature.id);
        expect(signature.summary.trim(), isNotEmpty, reason: signature.id);
        // A "fix" that only restates the problem is not a fix.
        expect(
          signature.fix,
          isNot(equals(signature.summary)),
          reason: signature.id,
        );
      }
    });

    test('ids are namespaced so they can be grouped and filtered', () {
      for (final id in ErrorClassifier.ids) {
        expect(id, matches(RegExp(r'^[a-z]+\.[a-z_.]+$')), reason: id);
      }
    });

    test('nothing matches ordinary successful output', () {
      // The cost of a false positive is a confident, wrong explanation, which
      // is worse than no explanation at all.
      const clean = '''
Running Xcode build...
Xcode archive done.                    23.6s
✓ Built build/ios/archive/Runner.xcarchive (169.6MB)
[✓] App Settings Validation
    • Version Number: 1.0.0
    • Build Number: 1
Successfully exported and signed the ipa file
''';
      expect(ErrorClassifier.classifyAll(clean), isEmpty);
    });

    test('empty and null output classify to nothing', () {
      expect(ErrorClassifier.classify(null), isNull);
      expect(ErrorClassifier.classify(''), isNull);
      expect(ErrorClassifier.classifyAll(null), isEmpty);
    });

    test('the more specific of two overlapping signatures wins', () {
      // Both the SPM and the CocoaPods form describe gym archiving a Flutter
      // app; a log containing the exportArchive wording must not be reported
      // as the ephemeral one, and vice versa.
      expect(
        ErrorClassifier.classify(
          'error: exportArchive The data couldn\'t be read because it isn\'t '
          'in the correct format',
        )?.id,
        'ios.gym.wraps_flutter_build',
      );
    });

    test('several diagnoses surface together when a run trips several', () {
      // A stale Ruby warning must not hide the real failure underneath it.
      final all = ErrorClassifier.classifyAll(
        'WARNING: Support for your Ruby version (3.1.1) is going away.\n'
        'error: exportArchive No Team Found in Archive',
      );
      expect(
        all.map((d) => d.id),
        containsAll(<String>[
          'ios.export.no_team',
          'ruby.too_old_for_fastlane',
        ]),
      );
    });
  });
}
