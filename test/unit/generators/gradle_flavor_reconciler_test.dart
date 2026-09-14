import 'package:shipway/src/generators/gradle_flavor_reconciler.dart';
import 'package:shipway/src/generators/write_guards.dart';
import 'package:test/test.dart';

ReconcileResult reconcile(
  String source, {
  List<String> flavors = const <String>['development', 'production'],
  List<String> dimensions = const <String>['environment'],
  bool kotlin = true,
}) => GradleFlavorReconciler(
  path: 'android/app/build.gradle.kts',
  flavors: flavors,
  dimensions: dimensions,
  kotlin: kotlin,
).reconcile(source);

/// The field report's build file, before the hand fix.
const String reported = '''
android {
    namespace = "com.acme.app"
    flavorDimensions += "environment"

    productFlavors {
        create("development") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Acme Dev")
            manifestPlaceholders["deepLinkHost"] = "dev.acme.app"
        }
        create("production") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
            manifestPlaceholders["deepLinkHost"] = "acme.app"
        }
    }
}
''';

void main() {
  group('the field report\'s build file', () {
    test('becomes the hand fix', () {
      final result = reconcile(reported);

      expect(result.blockers, isEmpty);
      // What the report's author wrote by hand: configure, do not create, and
      // keep only what shipway does not set.
      expect(result.text, contains('getByName("development") {'));
      expect(result.text, contains('getByName("production") {'));
      expect(
        result.text,
        contains('manifestPlaceholders["deepLinkHost"] = "dev.acme.app"'),
      );
      for (final gone in const <String>[
        'create(',
        'applicationIdSuffix',
        'versionNameSuffix',
        'dimension =',
        'app_name',
        'flavorDimensions',
      ]) {
        expect(result.text, isNot(contains(gone)), reason: gone);
      }
      expect(result.text, contains('namespace = "com.acme.app"'));
    });

    test('and a second pass changes nothing', () {
      final once = reconcile(reported).text;
      expect(reconcile(once).text, once);
    });
  });

  test('declarations that were all shipway\'s disappear entirely', () {
    final result = reconcile('''
android {
    flavorDimensions += "environment"

    productFlavors {
        create("development") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
        }

        create("production") {
            dimension = "environment"
        }
    }
}
''');
    expect(result.text, isNot(contains('productFlavors')));
    expect(result.text, isNot(contains('flavorDimensions')));
    expect(result.text, startsWith('android {'));
  });

  test(
    'Groovy keeps its configure-or-create blocks, minus shipway\'s lines',
    () {
      final result = reconcile(kotlin: false, '''
android {
    flavorDimensions "environment"
    productFlavors {
        development {
            dimension "environment"
            applicationIdSuffix ".dev"
            resValue "string", "app_name", "Acme Dev"
            buildConfigField "String", "HOST", "\\"dev.acme.app\\""
        }
    }
}
''');
      expect(result.text, contains('development {'));
      expect(result.text, contains('buildConfigField'));
      expect(result.text, isNot(contains('applicationIdSuffix')));
      expect(result.text, isNot(contains('app_name')));
      expect(result.text, isNot(contains('flavorDimensions')));
    },
  );

  test('a flavor shipway does not manage is left exactly as it is', () {
    const source = '''
android {
    productFlavors {
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".stg"
        }
    }
}
''';
    expect(reconcile(source).text, source);
  });

  test('a statement spanning lines is kept rather than half-removed', () {
    final result = reconcile('''
android {
    productFlavors {
        create("development") {
            resValue(
                "string", "app_name", "Acme Dev"
            )
        }
    }
}
''');
    expect(result.text, contains('getByName("development")'));
    expect(result.text, contains('resValue('));
    expect(result.text, contains('"string", "app_name", "Acme Dev"'));
  });

  test('a dimension list naming one of the project\'s own is kept', () {
    const line = 'flavorDimensions += listOf("environment", "store")';
    expect(reconcile('android {\n    $line\n}\n').text, contains(line));
  });

  test('outside android { } nothing is touched', () {
    const source = 'dependencies {\n    implementation("a:b:1")\n}\n';
    expect(reconcile(source).text, source);
  });

  group('what it refuses rather than rewrites', () {
    test('productFlavors.create outside a productFlavors block', () {
      final result = reconcile('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    productFlavors.create("development") {
        dimension = "environment"
    }
}
''');
      expect(result.blockers, hasLength(1));
      expect(
        result.blockers.single.reason,
        contains('android/app/build.gradle.kts:5'),
      );
      expect(result.blockers.single.remedy, contains('getByName'));
    });

    test('flavors created in a loop, in Kotlin', () {
      const source = '''
android {
    productFlavors {
        listOf("development", "production").forEach { name ->
            create(name) { dimension = "environment" }
        }
    }
}
''';
      expect(reconcile(source).blockers, hasLength(1));
      // Groovy's container configures a flavor that already exists.
      expect(reconcile(source, kotlin: false).blockers, isEmpty);
    });

    test('but not a line that is only a comment', () {
      expect(
        reconcile(
          'android {\n    // productFlavors.create("development")\n}\n',
        ).blockers,
        isEmpty,
      );
    });
  });
}
