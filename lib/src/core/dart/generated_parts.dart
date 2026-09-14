import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One `part` file build_runner produces that is missing, or older than the
/// library that declares it.
class StalePart {
  const StalePart({
    required this.part,
    required this.source,
    required this.missing,
  });

  /// Relative to the project root.
  final String part;
  final String source;
  final bool missing;
}

/// Finds generated Dart code that has fallen behind its source.
///
/// A field report's release build failed until
/// `dart run build_runner build --delete-conflicting-outputs` was run by
/// hand. shipway does not run it — whether generated code is committed, and
/// how it is built, is a project's decision — but it can say so before a build
/// rather than let the build find out.
abstract final class GeneratedParts {
  /// How much older a part may be before it counts as stale.
  ///
  /// A checkout writes files in no particular order, seconds apart, so a
  /// freshly cloned project must not report every generated file.
  static const Duration tolerance = Duration(seconds: 5);

  /// Whether the project has build_runner as a dev dependency.
  static bool usesBuildRunner(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return false;
    try {
      final document = loadYaml(pubspec.readAsStringSync());
      if (document is! YamlMap) return false;
      final dev = document['dev_dependencies'];
      return dev is YamlMap && dev.containsKey('build_runner');
    } on YamlException {
      return false;
    }
  }

  /// `part 'user.g.dart';` — a part whose name has a second extension, which
  /// is how every build_runner builder names its output. A plain
  /// `part 'src/widget.dart';` is hand-written and not looked at.
  static final RegExp _generatedPart = RegExp(
    r'''^part\s+['"]([^'"]+\.[A-Za-z0-9_]+\.dart)['"]\s*;''',
    multiLine: true,
  );

  static final RegExp _generatedName = RegExp(r'\.[A-Za-z0-9_]+\.dart$');

  /// Every stale generated part under `lib/`.
  static List<StalePart> find(String root) {
    final lib = Directory(p.join(root, 'lib'));
    if (!lib.existsSync()) return const <StalePart>[];

    final stale = <StalePart>[];
    for (final entity in lib.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (_generatedName.hasMatch(p.basename(entity.path))) continue;

      final String source;
      try {
        source = entity.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      for (final match in _generatedPart.allMatches(source)) {
        final part = File(p.join(entity.parent.path, match.group(1)!));
        final missing = !part.existsSync();
        if (!missing &&
            !part
                .lastModifiedSync()
                .add(tolerance)
                .isBefore(entity.lastModifiedSync())) {
          continue;
        }
        stale.add(
          StalePart(
            part: p.relative(part.path, from: root),
            source: p.relative(entity.path, from: root),
            missing: missing,
          ),
        );
      }
    }
    stale.sort((a, b) => a.part.compareTo(b.part));
    return stale;
  }
}
