import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/config/shipway_config.dart';
import '../core/secrets/secret_names.dart';

/// Why a secret could not be turned into the file a lane needs.
class MaterialisationFailure implements Exception {
  const MaterialisationFailure(this.what, {required this.fix});

  final String what;
  final String fix;

  @override
  String toString() => what;
}

/// Reads a secret by name, or null when it is not set anywhere this
/// environment may look.
typedef SecretReader = Future<String?> Function(String name);

/// Turns secrets a runner holds as *content* into the *files* a lane reads,
/// for the length of one run.
///
/// A service-account key and a signing keystore are files on a developer's
/// machine and repository secrets on a runner. Something has to write them
/// out, and it used to be the workflow: a shell step per file, which worked on
/// a hosted runner because the machine was destroyed afterwards. On a machine
/// that keeps running, those files — and the passwords in `key.properties` —
/// were still on disk for the next job, and the next person, to read.
///
/// So the writing moved here, where it can be paired with the removing. Every
/// file goes into one directory made for this run, outside the checkout, and
/// [cleanUp] takes the directory away again whatever happened in between.
/// `key.properties` is the exception: Gradle reads it from `android/`, so that
/// is where it goes, marked as shipway's so a later run can tell it from one
/// the machine's owner put there.
class SecretMaterialiser {
  SecretMaterialiser({
    required this.projectRoot,
    required this.read,
    required this.baseDirectory,
  });

  final String projectRoot;
  final SecretReader read;

  /// Where the run's directory is created. See [baseDirectoryFor].
  final String baseDirectory;

  /// Set by GitHub Actions to a directory the runner empties around each job,
  /// on self-hosted machines too. Preferred over the system's temporary
  /// directory because it is a second thing that removes the files.
  static const String runnerTempVariable = 'RUNNER_TEMP';

  /// Every run directory starts with this.
  static const String directoryPrefix = 'shipway-run-';

  /// The first line of a `key.properties` this class wrote.
  ///
  /// It is how a leftover is told apart from a file that belongs to the
  /// machine: one is removed, the other must never be touched.
  static const String keyPropertiesMarker =
      '# Written by shipway for one release run. Removed when the run ends.';

  static const String keystoreFileName = 'upload-keystore.jks';

  Directory? _directory;
  final List<File> _outsideDirectory = <File>[];

  /// The run's temporary directory under [environment].
  static String baseDirectoryFor(Map<String, String> environment) {
    final runnerTemp = environment[runnerTempVariable]?.trim();
    if (runnerTemp != null &&
        runnerTemp.isNotEmpty &&
        Directory(runnerTemp).existsSync()) {
      return runnerTemp;
    }
    return Directory.systemTemp.path;
  }

  /// What a run directory for [projectRoot] is named, before its random
  /// suffix.
  ///
  /// Carries the project so that cleaning up after one checkout cannot remove
  /// the files of a release running from another on the same machine.
  static String directoryPrefixFor(String projectRoot) {
    final canonical = p.canonicalize(projectRoot);
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    return '$directoryPrefix${digest.substring(0, 12)}-';
  }

  static File keyPropertiesFile(String projectRoot) =>
      File(p.join(projectRoot, 'android', 'key.properties'));

  /// Every path written so far and not yet removed.
  List<String> get written => <String>[
    if (_directory case final directory?)
      for (final entity in directory.listSync()) entity.path,
    for (final file in _outsideDirectory) file.path,
  ];

  bool get isEmpty => _directory == null && _outsideDirectory.isEmpty;

  /// Writes a file for each of [variables] that names a path with nothing at
  /// it, from the secret holding its content, and returns where each went.
  ///
  /// A variable that already points at a real file is left alone: a
  /// self-hosted machine may keep its service account on disk, and that is its
  /// owner's decision. One with neither a file nor a content secret is left
  /// alone too — the pre-flight has already named it as missing.
  Future<Map<String, String>> pathVariables(Iterable<String> variables) async {
    final environment = <String, String>{};
    for (final variable in variables) {
      final existing = await read(variable);
      if (existing != null && _resolve(existing).existsSync()) continue;

      final content = await read(SecretNames.contentSecretFor(variable));
      if (content == null) continue;

      final file = File(
        p.join(_runDirectory().path, '${variable.toLowerCase()}.json'),
      );
      file.writeAsStringSync(content.endsWith('\n') ? content : '$content\n');
      environment[variable] = file.path;
    }
    return environment;
  }

  /// Rebuilds the keystore and `android/key.properties` from the secrets
  /// [signing] names. Returns whether anything was written.
  ///
  /// Nothing is written when a `key.properties` is already there and is not a
  /// leftover of shipway's: the machine signs with its own, and replacing it
  /// would be replacing somebody's working build.
  Future<bool> androidSigning(AndroidSigningConfig? signing) async {
    final keystoreRef = signing?.keystoreRef;
    if (keystoreRef == null) return false;

    final properties = keyPropertiesFile(projectRoot);
    if (properties.existsSync() && !_isOurs(properties)) return false;
    // Ours, and the keystore it names is still there: another release from
    // this checkout is using it right now, and it is that run's to remove.
    if (properties.existsSync() && _storeFileExists(properties)) return false;

    final encoded = await read(keystoreRef);
    if (encoded == null) return false;

    final List<int> keystore;
    try {
      keystore = base64.decode(encoded.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      throw MaterialisationFailure(
        '$keystoreRef is not base64, so there is no keystore to write.',
        fix:
            'Set it to the output of `base64 -i <your keystore>`, with nothing '
            'added.',
      );
    }

    final keyProperties = signing!.keyProperties;
    final storeVariable =
        keyProperties?.storePasswordRef ??
        SecretNames.androidStorePasswordDefault;
    final keyVariable =
        keyProperties?.keyPasswordRef ?? SecretNames.androidKeyPasswordDefault;
    final storePassword = await read(storeVariable);
    final keyPassword = await read(keyVariable);
    if (storePassword == null || keyPassword == null) {
      final missing = <String>[
        if (storePassword == null) storeVariable,
        if (keyPassword == null) keyVariable,
      ];
      throw MaterialisationFailure(
        'android/key.properties cannot be written: ${missing.join(' and ')} '
        '${missing.length == 1 ? 'is' : 'are'} not set.',
        fix:
            'Set ${missing.length == 1 ? 'it' : 'them'} beside $keystoreRef, '
            'or name the variables you do use under '
            'signing.android.key_properties.',
      );
    }

    final store = File(p.join(_runDirectory().path, keystoreFileName))
      ..writeAsBytesSync(keystore);

    // Absolute, because Gradle resolves `storeFile` from android/app and a
    // relative path silently names a file that is not there.
    properties
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '$keyPropertiesMarker\n'
        'storeFile=${_propertiesValue(store.path)}\n'
        'storePassword=${_propertiesValue(storePassword)}\n'
        'keyPassword=${_propertiesValue(keyPassword)}\n'
        'keyAlias=${_propertiesValue(keyProperties?.keyAlias ?? 'upload')}\n',
      );
    _outsideDirectory.add(properties);
    return true;
  }

  /// Removes everything this instance wrote. Safe to call twice, and never
  /// throws: it runs in a `finally`, where an exception would replace the
  /// failure somebody actually needs to read.
  void cleanUp() {
    for (final file in _outsideDirectory) {
      _delete(file);
    }
    _outsideDirectory.clear();
    final directory = _directory;
    if (directory != null) _delete(directory);
    _directory = null;
  }

  /// Removes what an earlier run for [projectRoot] left behind — one that was
  /// killed before its own [cleanUp] could run. Returns what was removed.
  ///
  /// Not called at the start of a release: a pipeline runs two at once from
  /// one checkout, and each would delete the other's files.
  static List<String> sweep({
    required String projectRoot,
    required String baseDirectory,
  }) {
    final removed = <String>[];

    final properties = keyPropertiesFile(projectRoot);
    if (properties.existsSync() && _isOurs(properties)) {
      if (_delete(properties)) removed.add(properties.path);
    }

    final base = Directory(baseDirectory);
    if (!base.existsSync()) return removed;
    final prefix = directoryPrefixFor(projectRoot);
    for (final entity in base.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      if (!p.basename(entity.path).startsWith(prefix)) continue;
      if (_delete(entity)) removed.add(entity.path);
    }
    return removed;
  }

  Directory _runDirectory() => _directory ??= Directory(
    baseDirectory,
  ).createTempSync(directoryPrefixFor(projectRoot));

  File _resolve(String path) =>
      File(p.isAbsolute(path) ? path : p.join(projectRoot, path));

  static bool _isOurs(File properties) {
    try {
      return properties.readAsStringSync().startsWith(keyPropertiesMarker);
    } on FileSystemException {
      return false;
    }
  }

  static bool _storeFileExists(File properties) {
    for (final line in properties.readAsLinesSync()) {
      if (!line.startsWith('storeFile=')) continue;
      final path = line.substring('storeFile='.length).replaceAll(r'\\', r'\');
      return File(path).existsSync();
    }
    return false;
  }

  /// A `.properties` value: a backslash begins an escape, so a literal one is
  /// doubled. Nothing else in a password or a POSIX path needs touching.
  static String _propertiesValue(String value) => value.replaceAll(r'\', r'\\');

  static bool _delete(FileSystemEntity entity) {
    try {
      if (entity.existsSync()) entity.deleteSync(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
