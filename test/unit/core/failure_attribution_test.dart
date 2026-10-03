import 'dart:io';

import 'package:shipway/src/core/errors/classifier.dart';
import 'package:shipway/src/core/errors/failure_attribution.dart';
import 'package:test/test.dart';

/// The shape of the log from the field report: the App Store Connect key and
/// match succeed, `flutter build ipa` fails in `pod install`, and fastlane's
/// update changelog follows. Reconstructed from the report, which quoted the
/// CocoaPods error and the summary but did not keep the whole log.
String _fieldReport() =>
    File('test/fixtures/lane_logs/ios_stale_pod_specs.log').readAsStringSync();

String _step(String name) =>
    '[10:00:00]: ---------\n'
    '[10:00:00]: --- Step: $name ---\n'
    '[10:00:00]: ---------\n';

void main() {
  group('the field report', () {
    test('the failed step is the build, not the last thing mentioned', () {
      final attribution = FailureAttribution.parse(_fieldReport());
      expect(attribution.hasStepMarkers, isTrue);
      expect(attribution.failedStep, startsWith('cd /Users/runner/work/app'));
      expect(attribution.failedStep, contains('flutter build ipa'));
    });

    test("the error line is fastlane's own, not CocoaPods'", () {
      final attribution = FailureAttribution.parse(_fieldReport());
      expect(attribution.errorLines, hasLength(1));
      expect(attribution.errorLine, startsWith('[!] Exit status of command'));
    });

    test('the region holds the CocoaPods error and not the changelog', () {
      final region = FailureAttribution.parse(_fieldReport()).region;
      expect(region, contains('too out-of-date'));
      expect(region, contains('[!] Exit status of command'));
      expect(region, isNot(contains('Improvements')));
      expect(region, isNot(contains('App Store Connect API')));
      expect(region, isNot(contains('fastlane summary')));
      // Nor the steps that succeeded before it.
      expect(region, isNot(contains('Successfully decrypted')));
    });

    test('the context is the end of the failing step, not the summary', () {
      final context = FailureAttribution.parse(_fieldReport()).context;
      expect(context, hasLength(20));
      expect(context.last, contains('Error running pod install'));
      expect(context.join('\n'), isNot(contains('fastlane summary')));
    });

    test('is diagnosed as the spec repo, and not as the API key', () {
      final log = _fieldReport();
      // What made the old classifier wrong is really in the fixture.
      expect(log, contains('App Store Connect API'));
      expect(log, contains('invalid'));
      expect(log, contains('401'));

      final report = ErrorClassifier.diagnose(log);
      expect(report.causes.map((d) => d.id), <String>[
        ErrorClassifier.podSpecsOutOfDate,
      ]);
      expect(report.hasCause('asc.key_rejected'), isFalse);
    });

    test('the Ruby notice is a warning, not a cause', () {
      final report = ErrorClassifier.diagnose(_fieldReport());
      expect(report.warnings.map((d) => d.id), <String>[
        'ruby.too_old_for_fastlane',
      ]);
      expect(report.warnings.single.isWarning, isTrue);
      expect(report.hasCause('ruby.too_old_for_fastlane'), isFalse);
    });
  });

  group('finding the step', () {
    test('without a summary table it is the last step before the error', () {
      final attribution = FailureAttribution.parse(
        '${_step('sync_code_signing')}'
        '[10:00:01]: installed\n'
        '${_step('upload_to_testflight')}'
        '[10:00:02]: uploading\n'
        '\n'
        '[!] The upload was refused\n',
      );
      expect(attribution.failedStep, 'upload_to_testflight');
      expect(attribution.region, contains('uploading'));
      expect(attribution.region, isNot(contains('installed')));
    });

    test('a step run by the error block does not take the blame', () {
      // An `error do` block posts to Slack after the step that failed, so the
      // last step before the error line is not the failing one.
      final attribution = FailureAttribution.parse(
        '${_step('build_app')}'
        '[10:00:01]: the export failed\n'
        '${_step('slack')}'
        '[10:00:02]: Successfully sent Slack notification\n'
        '+------+-----------+-------------+\n'
        '|        fastlane summary        |\n'
        '+------+-----------+-------------+\n'
        '| 1    | slack     | 0           |\n'
        '| 💥   | build_app | 3           |\n'
        '+------+-----------+-------------+\n'
        '\n'
        '[!] Error building the application\n',
      );
      expect(attribution.failedStep, 'build_app');
      expect(attribution.region, contains('the export failed'));
      expect(attribution.region, isNot(contains('Slack')));
    });

    test('a step name the table shortened is still found', () {
      final attribution = FailureAttribution.parse(
        '${_step('cd /a/very/long/path && flutter build ipa --release')}'
        '[10:00:01]: ▸ failed\n'
        '${_step('slack')}'
        '| 💥   | cd /a/very/long/path && flu... | 3 |\n'
        '\n'
        '[!] Exit status was 1\n',
      );
      expect(attribution.failedStep, startsWith('cd /a/very/long/path'));
    });

    test('colour codes do not hide a marker or an error line', () {
      final attribution = FailureAttribution.parse(
        '\x1B[32m[10:00:00]: --- Step: deliver ---\x1B[0m\n'
        '[10:00:01]: uploading\n'
        '\x1B[31m[!] Refused\x1B[0m\n',
      );
      expect(attribution.failedStep, 'deliver');
      expect(attribution.errorLine, '[!] Refused');
    });

    test('an error with steps and no error line still has a step', () {
      final attribution = FailureAttribution.parse(
        '${_step('match')}[10:00:01]: cloning\n',
      );
      expect(attribution.failedStep, 'match');
      expect(attribution.errorLines, isEmpty);
      expect(attribution.context, <String>['[10:00:01]: cloning']);
    });
  });

  group('the error line', () {
    test('keeps the lines that continue it, up to a blank one', () {
      final attribution = FailureAttribution.parse(
        '${_step('pilot')}'
        '\n'
        '[!] The request failed\n'
        '    with a second line\n'
        '\n'
        'something printed afterwards\n',
      );
      expect(attribution.errorLines, <String>[
        '[!] The request failed',
        '    with a second line',
      ]);
      expect(attribution.region, isNot(contains('printed afterwards')));
    });

    test('inside a step, a tool\'s own [!] is not fastlane\'s', () {
      final attribution = FailureAttribution.parse(
        '${_step('cocoapods')}'
        '[10:00:01]: ▸ [!] CocoaPods could not find compatible versions\n',
      );
      expect(attribution.errorLines, isEmpty);
    });
  });

  group('output with no steps', () {
    test('is its own region, whole', () {
      // `shipway build` hands Flutter's output over, which has no markers.
      const output =
          'Running Xcode build...\n'
          'error: exportArchive No Team Found in Archive\n'
          '** EXPORT FAILED **';
      final attribution = FailureAttribution.parse(output);
      expect(attribution.hasStepMarkers, isFalse);
      expect(attribution.failedStep, isNull);
      expect(attribution.region, output);
      expect(attribution.errorLines, isEmpty);
      expect(attribution.context, isEmpty);
    });

    test('an error line brings the twenty lines above it', () {
      final lines = <String>[
        for (var i = 1; i <= 30; i++) 'line $i',
        '[!] Something went wrong',
      ];
      final attribution = FailureAttribution.parse(lines.join('\n'));
      expect(attribution.errorLine, '[!] Something went wrong');
      expect(attribution.context, hasLength(20));
      expect(attribution.context.first, 'line 11');
      expect(attribution.context.last, 'line 30');
    });

    test('empty output is nothing, without throwing', () {
      final attribution = FailureAttribution.parse('');
      expect(attribution.failedStep, isNull);
      expect(attribution.errorLines, isEmpty);
      expect(attribution.region, isEmpty);
    });
  });
}
