import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/firebase/google_services.dart';
import '../core/model/firebase_model.dart';
import '../core/model/uncertainty.dart';

class FirebaseInspectResult {
  const FirebaseInspectResult({
    required this.firebase,
    required this.uncertainties,
  });

  final FirebaseModel firebase;
  final List<Uncertainty> uncertainties;
}

/// Finds per-flavor Firebase configuration.
///
/// Correlating these with flavors is the point: a project with a
/// `google-services.json` for one flavor and not another builds fine and fails
/// at runtime, which is exactly the kind of thing import should say out loud.
class FirebaseInspector {
  const FirebaseInspector();

  static const String androidFileName = 'google-services.json';
  static const String iosFileName = 'GoogleService-Info.plist';

  Future<FirebaseInspectResult> inspect(
    String root, {
    Set<String> flavors = const <String>{},
  }) async {
    final log = UncertaintyLog();
    final files = <FirebaseConfigFile>[
      ...await _readAndroid(root),
      ...await _readIos(root),
    ];

    final model = FirebaseModel(
      configFiles: files,
      hasFirebaseJson: File(p.join(root, 'firebase.json')).existsSync(),
      hasFirebaseOptionsDart: File(
        p.join(root, 'lib/firebase_options.dart'),
      ).existsSync(),
    );

    if (model.inUse) _reportGaps(model, flavors, log);
    return FirebaseInspectResult(firebase: model, uncertainties: log.build());
  }

  Future<List<FirebaseConfigFile>> _readAndroid(String root) async {
    final files = <FirebaseConfigFile>[];

    Future<void> consider(File file, String? sourceSet) async {
      if (!file.existsSync()) return;
      final apps = await _androidApps(file);
      // A file names "its" app only when it lists one. Firebase writes every
      // Android app in a project into the same download, and reporting the
      // first entry as the app is how a flavor ends up with another's app id.
      final only = apps.length == 1 ? apps.single : null;
      files.add(
        FirebaseConfigFile(
          path: p.relative(file.path, from: root),
          platform: 'android',
          sourceSet: sourceSet,
          projectId: apps.firstOrNull?.projectId,
          bundleOrPackageId: only?.packageName,
          appId: only?.appId,
        ),
      );
    }

    await consider(File(p.join(root, 'android/app', androidFileName)), null);

    final src = Directory(p.join(root, 'android/app/src'));
    if (src.existsSync()) {
      for (final dir in src.listSync().whereType<Directory>()) {
        await consider(
          File(p.join(dir.path, androidFileName)),
          p.basename(dir.path),
        );
      }
    }
    return files;
  }

  Future<List<FirebaseConfigFile>> _readIos(String root) async {
    final ios = Directory(p.join(root, 'ios'));
    if (!ios.existsSync()) return const <FirebaseConfigFile>[];

    final files = <FirebaseConfigFile>[];
    // The plist may live anywhere under ios/ — Runner/, config/<flavor>/,
    // flavors/<flavor>/ are all conventions in the wild — so search rather
    // than assume one layout.
    //
    // followLinks is off deliberately: `ios/.symlinks/plugins/` points into the
    // pub cache, and following it walks into plugin *example apps* whose own
    // Firebase config would otherwise be reported as this project's.
    for (final entity
        in ios
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()) {
      if (p.basename(entity.path) != iosFileName) continue;
      if (_isExcludedIosPath(p.relative(entity.path, from: root))) continue;
      final relative = p.relative(entity.path, from: root);
      final plist = await entity.readAsString();
      files.add(
        FirebaseConfigFile(
          path: relative,
          platform: 'ios',
          sourceSet: p.basename(p.dirname(entity.path)),
          bundleOrPackageId: _plistValue(plist, 'BUNDLE_ID'),
          appId: _plistValue(plist, 'GOOGLE_APP_ID'),
          projectId: _plistValue(plist, 'PROJECT_ID'),
        ),
      );
    }
    return files;
  }

  /// Directories under `ios/` whose contents are not this project's source:
  /// dependency checkouts, build output and CocoaPods.
  static bool _isExcludedIosPath(String relative) {
    const excluded = <String>['.symlinks', 'Pods', 'build', '.dart_tool'];
    final segments = p.split(relative);
    return segments.any(excluded.contains);
  }

  /// Reports flavors whose Firebase config is present on one platform but not
  /// the other, or missing entirely.
  void _reportGaps(
    FirebaseModel model,
    Set<String> flavors,
    UncertaintyLog log,
  ) {
    if (flavors.isEmpty) return;

    for (final platform in const <String>['android', 'ios']) {
      final configured = model
          .forPlatform(platform)
          .map((f) => f.sourceSet)
          .whereType<String>()
          .toSet();
      if (configured.isEmpty) continue;

      // Only meaningful once at least one flavor is configured: a project that
      // shares one config across flavors is a legitimate choice, not a gap.
      final named = flavors.where(configured.contains).toSet();
      if (named.isEmpty) continue;

      final missing = flavors.difference(named);
      if (missing.isEmpty) continue;

      final fileName = platform == 'android' ? androidFileName : iosFileName;
      log.defect(
        field: 'firebase.$platform',
        reason:
            '${missing.length == 1 ? 'flavor' : 'flavors'} '
            '${missing.map((f) => '`$f`').join(', ')} '
            '${missing.length == 1 ? 'has' : 'have'} no $fileName, but '
            '${named.map((f) => '`$f`').join(', ')} '
            '${named.length == 1 ? 'does' : 'do'}.',
        remedy:
            'Add the missing $fileName, or confirm those flavors are '
            'meant to share one Firebase project.',
      );
    }
  }

  static Future<List<GoogleServicesApp>> _androidApps(File file) async {
    try {
      return GoogleServices.appsIn(await file.readAsString());
    } on FormatException {
      return const <GoogleServicesApp>[];
    }
  }

  /// Pulls a value out of an XML plist without a full parse.
  ///
  /// These files are machine-generated with a fixed shape, so a targeted match
  /// is reliable here in a way it would not be for a hand-edited plist.
  static String? _plistValue(String plist, String key) {
    final match = RegExp(
      '<key>$key</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist);
    return match?.group(1);
  }
}
