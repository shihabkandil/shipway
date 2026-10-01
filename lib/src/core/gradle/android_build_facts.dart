import 'dart:io';

import 'package:path/path.dart' as p;

import 'gradle_layout.dart';

/// What a build file says `compileSdk` is.
///
/// Exactly one of [level] and [expression] is set. An expression is anything
/// that is not a number on the page — `flutter.compileSdkVersion` above all —
/// and its value is decided by a plugin at configuration time, so nothing
/// static may claim to know it.
class CompileSdk {
  const CompileSdk.literal(int this.level, {required this.file})
    : expression = null;

  const CompileSdk.expression(String this.expression, {required this.file})
    : level = null;

  final int? level;
  final String? expression;

  /// The build file it was read from, relative to the project root.
  final String file;
}

/// Where the Android Gradle Plugin version is declared, and what it says.
///
/// [version] is null when the declaration is there but names a variable or a
/// version catalog entry, which is then in [expression].
class AgpDeclaration {
  const AgpDeclaration({required this.file, this.version, this.expression});

  final String? version;
  final String? expression;
  final String file;
}

/// One directory under the SDK's `platforms/`.
class InstalledPlatform {
  const InstalledPlatform({
    required this.directory,
    required this.level,
    this.minor,
  });

  /// The directory name: `android-36`, or `android-37.0`.
  final String directory;

  final int level;

  /// Set when the directory carries a minor version. Only newer Android
  /// Gradle Plugins look for these.
  final int? minor;
}

/// Static facts about an Android build, read without running Gradle.
///
/// Regex over a comment-stripped source rather than the structural parser:
/// these are single assignments whose position in the file does not matter,
/// and a reader that has to cope with every block shape would be wrong more
/// often than one that looks for the line.
abstract final class AndroidBuildFacts {
  /// The files an AGP version may be declared in, newest convention first.
  static const List<String> agpFiles = <String>[
    'android/settings.gradle.kts',
    'android/settings.gradle',
    'android/build.gradle.kts',
    'android/build.gradle',
  ];

  /// The app module's `compileSdk`, or null when it declares none.
  static CompileSdk? compileSdk(String root) {
    final located = GradleLayout.locateBuildFile(root);
    if (located == null) return null;
    final source = File(p.join(root, located.path)).readAsStringSync();
    return parseCompileSdk(source, file: located.path);
  }

  static CompileSdk? parseCompileSdk(String source, {required String file}) {
    final code = stripComments(source);

    // AGP 9's block form: `compileSdk { version = release(36) }`.
    final block = RegExp(r'\bcompileSdk\s*\{([^}]*)\}').firstMatch(code);
    if (block != null) {
      final body = block.group(1)!;
      final release = RegExp(r'release\s*\(\s*(\d+)\s*\)').firstMatch(body);
      return release == null
          ? CompileSdk.expression(
              body.trim().replaceAll(RegExp(r'\s+'), ' '),
              file: file,
            )
          : CompileSdk.literal(int.parse(release.group(1)!), file: file);
    }

    // `compileSdk = 37`, `compileSdk 37`, `compileSdkVersion(37)`. The word
    // boundary keeps `compileSdkExtension` and `compileSdkPreview` out.
    final assignment = RegExp(
      r'\bcompileSdk(?:Version)?\b[ \t]*(?:=[ \t]*|\([ \t]*|[ \t]+)([^\s)]+)',
    ).firstMatch(code);
    if (assignment == null) return null;

    final value = assignment.group(1)!;
    final number = RegExp(
      r'''^["']?(?:android-)?(\d+)["']?$''',
    ).firstMatch(value);
    return number == null
        ? CompileSdk.expression(value, file: file)
        : CompileSdk.literal(int.parse(number.group(1)!), file: file);
  }

  /// The Android Gradle Plugin declaration, or null when no file has one.
  static AgpDeclaration? agp(String root) {
    for (final relative in agpFiles) {
      final file = File(p.join(root, relative));
      if (!file.existsSync()) continue;
      final found = parseAgp(file.readAsStringSync(), file: relative);
      if (found != null) return found;
    }
    return null;
  }

  static AgpDeclaration? parseAgp(String source, {required String file}) {
    final code = stripComments(source);

    // The plugins block, in either dialect:
    //   id("com.android.application") version "8.11.1" apply false
    //   id 'com.android.application' version '8.11.1' apply false
    final plugin = RegExp(
      r'''id\s*\(?\s*["']com\.android\.application["']\s*\)?\s*version\s*\(?\s*([^\s)]+)''',
    ).firstMatch(code);
    // The older buildscript classpath.
    final classpath = RegExp(
      r'''com\.android\.tools\.build:gradle:([^"'\s)]+)''',
    ).firstMatch(code);

    final raw = (plugin ?? classpath)?.group(1);
    if (raw == null) return null;
    final value = raw.replaceAll(RegExp(r'''["']'''), '');
    return RegExp(r'^\d+\.\d+').hasMatch(value)
        ? AgpDeclaration(file: file, version: value)
        : AgpDeclaration(file: file, expression: value);
  }

  /// Removes `//` and `/* */` comments, so a commented-out old value is not
  /// read as the current one.
  ///
  /// `//` is left alone after a colon, which is a URL in a string rather than
  /// a comment.
  static String stripComments(String source) => source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'(?<!:)//[^\n]*'), '');
}

/// The Android SDK a Gradle build on this machine would use.
abstract final class AndroidSdk {
  /// Finds the SDK directory, or null when nothing points at one that exists.
  ///
  /// In the order the Android Gradle Plugin itself looks: `sdk.dir` in
  /// `android/local.properties`, then `ANDROID_HOME`, then the deprecated
  /// `ANDROID_SDK_ROOT`. The per-user default locations come last; they are
  /// where Android Studio installs one, and where Flutter finds it when
  /// nothing else says.
  static String? locate(
    String root, {
    required Map<String, String> environment,
  }) {
    final home = environment['HOME'];
    final candidates = <String?>[
      _sdkDirFromLocalProperties(root),
      environment['ANDROID_HOME'],
      environment['ANDROID_SDK_ROOT'],
      if (home != null) p.join(home, 'Library', 'Android', 'sdk'),
      if (home != null) p.join(home, 'Android', 'Sdk'),
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.trim().isEmpty) continue;
      if (Directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Every platform installed under [sdk], sorted by directory name.
  static List<InstalledPlatform> platforms(String sdk) {
    final directory = Directory(p.join(sdk, 'platforms'));
    if (!directory.existsSync()) return const <InstalledPlatform>[];
    final found = <InstalledPlatform>[];
    for (final entity in directory.listSync()) {
      if (entity is! Directory) continue;
      final parsed = parsePlatform(p.basename(entity.path));
      if (parsed != null) found.add(parsed);
    }
    found.sort((a, b) => a.directory.compareTo(b.directory));
    return found;
  }

  /// Reads `android-36` or `android-37.0`. Codename previews such as
  /// `android-Baklava` have no level to compare and are ignored.
  static InstalledPlatform? parsePlatform(String name) {
    final match = RegExp(r'^android-(\d+)(?:\.(\d+))?$').firstMatch(name);
    if (match == null) return null;
    final minor = match.group(2);
    return InstalledPlatform(
      directory: name,
      level: int.parse(match.group(1)!),
      minor: minor == null ? null : int.parse(minor),
    );
  }

  static String? _sdkDirFromLocalProperties(String root) {
    final file = File(p.join(root, 'android', 'local.properties'));
    if (!file.existsSync()) return null;
    for (final line in file.readAsLinesSync()) {
      final match = RegExp(r'^\s*sdk\.dir\s*[=:]\s*(.+?)\s*$').firstMatch(line);
      if (match == null) continue;
      // A properties file escapes backslashes and colons, which is how a
      // Windows path is written in one.
      return match
          .group(1)!
          .replaceAll(r'\\', '\u0000')
          .replaceAll(r'\', '')
          .replaceAll('\u0000', r'\');
    }
    return null;
  }
}
