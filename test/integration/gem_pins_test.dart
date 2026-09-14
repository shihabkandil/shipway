@Tags(<String>['ruby', 'integration'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/io/process_runner.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/toolchain/fastlane_pins.dart';
import 'package:shipway/src/doctor/checks/fastlane_checks.dart';
import 'package:shipway/src/generators/fastlane_generators.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:test/test.dart';

void main() {
  // Resolving against rubygems.org is network-bound.
  Timeout.factor(6);

  test(
    'the generated Android bundle resolves a gem set Firebase uploads with',
    () async {
      // The field report's crash came from resolution, not from a pin anybody
      // wrote: fastlane and the Firebase plugin both allow google-apis-core 1.x,
      // and with nothing else capping it that is what bundler chose.
      final directory = await Directory.systemTemp.createTemp('shipway_pins');
      addTearDown(() => directory.delete(recursive: true));

      const app = ResolvedApp(
        appId: 'main',
        projectName: 'acme_app',
        flavors: <ResolvedFlavor>[],
        androidApplicationId: 'com.acme.app',
        iosBundleId: null,
        gradleDsl: GradleDsl.kotlin,
      );
      for (final file in <GeneratedFile>[
        ...const GemfileGenerator().render(app),
        ...const PluginfileGenerator().render(app),
      ]) {
        if (!file.path.startsWith('android/')) continue;
        final target = File(
          p.join(directory.path, file.path.substring('android/'.length)),
        );
        await target.parent.create(recursive: true);
        await target.writeAsString(file.contents);
      }

      final result = await SystemProcessRunner(
        redactor: Redactor(),
      ).run('bundle', const <String>['lock'], workingDirectory: directory.path);
      expect(result.ok, isTrue, reason: result.output);

      final locked = GemLockCheck.lockedVersions(
        File(p.join(directory.path, 'Gemfile.lock')).readAsStringSync(),
      );
      expect(locked['fastlane'], FastlanePins.fastlane);
      expect(
        locked['fastlane-plugin-firebase_app_distribution'],
        FastlanePins.firebaseAppDistribution,
      );
      expect(
        FastlanePins.googleApisCoreAboveCeiling(locked['google-apis-core']!),
        isFalse,
        reason: 'resolved google-apis-core ${locked['google-apis-core']}',
      );
    },
  );
}
