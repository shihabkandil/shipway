import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/pipeline_references.dart';
import 'package:test/test.dart';

/// The field report's shape: flavors spelled out, a pipeline that abbreviates.
const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    android:
      application_id: com.acme.app
    flavors:
      development:
        suffix: .dev
      production:
        suffix: ""
    targets:
      play:
        track: internal
pipelines:
  beta:
    - analyze
    - release: { flavor: prod, target: play }
    - parallel:
        - build: { platform: android, flavor: dev }
        - release: { flavor: production, target: testflight }
  typo:
    - release: { flavor: production, target: fire }
  fine:
    - release: { flavor: production, target: play }
''';

void main() {
  final config = ConfigLoader.parse(_config);

  List<String> problems({String? pipeline}) => <String>[
    for (final problem in PipelineReferences.check(config, pipeline: pipeline))
      problem.what,
  ];

  test('an abbreviated flavor, with the name it probably meant', () {
    expect(
      problems(pipeline: 'beta'),
      contains(
        'Pipeline `beta` releases flavor `prod`, which this config does not '
        'declare. Did you mean `production`?',
      ),
    );
  });

  test('steps inside parallel blocks are checked too', () {
    expect(
      problems(pipeline: 'beta'),
      contains(
        'Pipeline `beta` builds flavor `dev`, which this config does not '
        'declare. Did you mean `development`?',
      ),
    );
  });

  test('a target the config never configured', () {
    expect(
      problems(pipeline: 'beta'),
      contains(
        'Pipeline `beta` releases to `testflight`, but targets.testflight is '
        'not configured.',
      ),
    );
  });

  test('a target that does not exist at all', () {
    expect(
      problems(pipeline: 'typo').single,
      contains('Did you mean `firebase`?'),
    );
  });

  test('a correct pipeline has nothing to say', () {
    expect(problems(pipeline: 'fine'), isEmpty);
  });

  test('without a name, every pipeline is checked', () {
    expect(problems(), hasLength(4));
  });

  group('did you mean', () {
    test('a prefix, either way round', () {
      expect(
        PipelineReferences.didYouMean('prod', <String>[
          'development',
          'production',
        ]),
        'production',
      );
    });

    test('a near miss', () {
      expect(
        PipelineReferences.didYouMean('prodution', <String>['production']),
        'production',
      );
    });

    test('nothing, rather than a guess', () {
      expect(
        PipelineReferences.didYouMean('staging', <String>['development']),
        isNull,
      );
    });
  });
}
