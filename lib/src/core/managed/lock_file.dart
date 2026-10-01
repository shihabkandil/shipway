import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../version.dart';
import 'content_hash.dart';

/// How much of a file shipway is allowed to touch.
enum Ownership {
  /// Present before shipway. We read it and describe it; we never write it.
  /// Import leaves every discovered file in this state — which is why running
  /// `shipway import` on a working project cannot break it.
  unmanaged,

  /// The user ran `shipway adopt`. A marked region is now ours.
  adopted,

  /// shipway created the file and owns it whole.
  generated;

  static Ownership parse(String value) => Ownership.values.firstWhere(
    (o) => o.name == value,
    orElse: () => Ownership.unmanaged,
  );

  bool get writable => this != Ownership.unmanaged;
}

/// How a writable file is rewritten.
enum WriteMode {
  /// Rewritten wholesale (Fastfile, Matchfile, .xcscheme, `main_<flavor>.dart`).
  full,

  /// Only the marked region is replaced (build.gradle.kts, .gitignore, Podfile).
  block;

  static WriteMode parse(String value) => WriteMode.values.firstWhere(
    (m) => m.name == value,
    orElse: () => WriteMode.full,
  );
}

/// One tracked file's record.
class LockEntry {
  const LockEntry({
    required this.path,
    required this.ownership,
    required this.mode,
    this.hash,
    this.blockHash,
    this.adoptedAt,
    this.disownedAt,
  });

  final String path;
  final Ownership ownership;
  final WriteMode mode;

  /// Digest of the whole file as shipway last left it.
  final String? hash;

  /// Digest of just our managed region.
  ///
  /// The pair distinguishes "the user edited around our block" — expected and
  /// fine — from "the user edited inside our block", which needs `--force`.
  final String? blockHash;

  final DateTime? adoptedAt;

  /// When `shipway disown` handed this file back. An unmanaged file with this
  /// set is one somebody declined, not one shipway has yet to be given: it is
  /// left alone quietly rather than reported as a conflict every run.
  final DateTime? disownedAt;

  LockEntry copyWith({
    Ownership? ownership,
    WriteMode? mode,
    String? hash,
    String? blockHash,
    DateTime? adoptedAt,
    DateTime? disownedAt,
  }) => LockEntry(
    path: path,
    ownership: ownership ?? this.ownership,
    mode: mode ?? this.mode,
    hash: hash ?? this.hash,
    blockHash: blockHash ?? this.blockHash,
    adoptedAt: adoptedAt ?? this.adoptedAt,
    disownedAt: disownedAt ?? this.disownedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ownership': ownership.name,
    'mode': mode.name,
    if (hash != null) 'hash': hash,
    if (blockHash != null) 'blockHash': blockHash,
    if (adoptedAt != null) 'adoptedAt': adoptedAt!.toUtc().toIso8601String(),
    if (disownedAt != null) 'disownedAt': disownedAt!.toUtc().toIso8601String(),
  };

  static LockEntry fromJson(String path, Map<String, dynamic> json) =>
      LockEntry(
        path: path,
        ownership: Ownership.parse(json['ownership'] as String? ?? 'unmanaged'),
        mode: WriteMode.parse(json['mode'] as String? ?? 'full'),
        hash: json['hash'] as String?,
        blockHash: json['blockHash'] as String?,
        adoptedAt: switch (json['adoptedAt']) {
          final String s => DateTime.tryParse(s),
          _ => null,
        },
        disownedAt: switch (json['disownedAt']) {
          final String s => DateTime.tryParse(s),
          _ => null,
        },
      );
}

/// The Flutter and Xcode a release was last built with.
///
/// Either may be null: an Android release says nothing about Xcode, and a
/// machine that could not be asked records nothing rather than a guess.
typedef LockedToolchain = ({String? flutter, String? xcode});

/// `.shipway/lock.json` — the record of what shipway may write.
///
/// Committed to version control on purpose: ownership is a team-wide fact, and
/// a teammate who pulls the repo must inherit the same permissions.
class LockFile {
  LockFile({
    required this.version,
    required this.generatedBy,
    Map<String, LockEntry>? files,
    Map<String, dynamic>? toolchain,
    Map<String, dynamic>? unrecognised,
  }) : _files = files ?? <String, LockEntry>{},
       _toolchain = toolchain ?? <String, dynamic>{},
       _unrecognised = unrecognised ?? <String, dynamic>{};

  /// Schema version of the lockfile itself.
  ///
  /// Still 1 with the `toolchain` section added: the key is optional, a file
  /// without it loads as before, and a reader that predates it ignores it. A
  /// bump would only make older shipways distrust a file they read correctly.
  static const int currentVersion = 1;

  static const String directoryName = '.shipway';
  static const String fileName = 'lock.json';

  static const String _toolchainKey = 'toolchain';
  static const String _flutterKey = 'flutter';
  static const String _xcodeKey = 'xcode';

  /// The top-level keys this version reads. Anything else is carried through
  /// untouched.
  static const Set<String> _knownKeys = <String>{
    'version',
    'generatedBy',
    'files',
    _toolchainKey,
  };

  final int version;
  final String generatedBy;
  final Map<String, LockEntry> _files;

  /// Kept as the raw map so a key a newer shipway adds beside `flutter` and
  /// `xcode` survives a save by this one.
  final Map<String, dynamic> _toolchain;

  /// Top-level keys this version does not know.
  ///
  /// The file is committed and shared, so the shipway that saves it is not
  /// always the newest one that wrote it. Dropping what it does not understand
  /// would quietly undo a teammate's newer version on every save.
  final Map<String, dynamic> _unrecognised;

  /// The toolchain the last successful release was built with, or null when
  /// none has been recorded.
  LockedToolchain? get toolchain {
    final flutter = _toolchain[_flutterKey];
    final xcode = _toolchain[_xcodeKey];
    final LockedToolchain record = (
      flutter: flutter is String && flutter.isNotEmpty ? flutter : null,
      xcode: xcode is String && xcode.isNotEmpty ? xcode : null,
    );
    return record.flutter == null && record.xcode == null ? null : record;
  }

  /// Records the versions a release was just built with, and says whether
  /// anything changed.
  ///
  /// A null argument leaves that entry alone rather than clearing it: an
  /// Android release says nothing about Xcode, and must not erase what the
  /// last iOS release recorded. The answer lets a caller skip the save, since
  /// rewriting a committed file that has not changed is a diff nobody asked
  /// for.
  bool recordToolchain({String? flutter, String? xcode}) {
    var changed = false;
    void put(String key, String? value) {
      if (value == null || value.isEmpty || _toolchain[key] == value) return;
      _toolchain[key] = value;
      changed = true;
    }

    put(_flutterKey, flutter);
    put(_xcodeKey, xcode);
    return changed;
  }

  Map<String, LockEntry> get files =>
      Map<String, LockEntry>.unmodifiable(_files);

  LockEntry? operator [](String path) => _files[_normalise(path)];

  /// Ownership of [path], defaulting to [Ownership.unmanaged].
  ///
  /// The default is the safe one: a file shipway has never heard of is one it
  /// must not write.
  Ownership ownershipOf(String path) =>
      this[path]?.ownership ?? Ownership.unmanaged;

  bool mayWrite(String path) => ownershipOf(path).writable;

  void record(LockEntry entry) => _files[_normalise(entry.path)] = LockEntry(
    path: _normalise(entry.path),
    ownership: entry.ownership,
    mode: entry.mode,
    hash: entry.hash,
    blockHash: entry.blockHash,
    adoptedAt: entry.adoptedAt,
    disownedAt: entry.disownedAt,
  );

  /// Records [path] as discovered-but-untouched, as import does for everything
  /// it reads.
  void noteUnmanaged(String path, {WriteMode mode = WriteMode.block}) =>
      record(LockEntry(path: path, ownership: Ownership.unmanaged, mode: mode));

  void remove(String path) => _files.remove(_normalise(path));

  /// True when the on-disk [content] no longer matches what we last wrote.
  bool hasDrifted(String path, String content) {
    final entry = this[path];
    if (entry == null || entry.hash == null) return false;
    return !ContentHash.matches(entry.hash, content);
  }

  static String _normalise(String path) =>
      p.posix.normalize(path.replaceAll(r'\', '/'));

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'generatedBy': generatedBy,
    if (_toolchain.isNotEmpty)
      _toolchainKey: <String, dynamic>{
        for (final key in _toolchain.keys.toList()..sort())
          key: _toolchain[key],
      },
    'files': <String, dynamic>{
      for (final key in _sortedKeys()) key: _files[key]!.toJson(),
    },
    for (final key in _unrecognised.keys.toList()..sort())
      key: _unrecognised[key],
  };

  /// Sorted so the committed file produces stable, reviewable diffs.
  List<String> _sortedKeys() => _files.keys.toList()..sort();

  static LockFile empty() =>
      LockFile(version: currentVersion, generatedBy: packageVersion);

  static LockFile fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'];
    final files = <String, LockEntry>{};
    if (rawFiles is Map) {
      for (final entry in rawFiles.entries) {
        final key = _normalise(entry.key.toString());
        final value = entry.value;
        if (value is Map) {
          files[key] = LockEntry.fromJson(key, value.cast<String, dynamic>());
        }
      }
    }
    final rawToolchain = json[_toolchainKey];
    return LockFile(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      generatedBy: json['generatedBy'] as String? ?? 'unknown',
      files: files,
      toolchain: rawToolchain is Map
          ? <String, dynamic>{
              for (final entry in rawToolchain.entries)
                entry.key.toString(): entry.value,
            }
          : null,
      unrecognised: <String, dynamic>{
        for (final entry in json.entries)
          if (!_knownKeys.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// Path to the lockfile for a project rooted at [root].
  static String pathFor(String root) => p.join(root, directoryName, fileName);

  /// Loads the lockfile for [root], or an empty one if the project has never
  /// been touched by shipway.
  static Future<LockFile> load(String root) async {
    final file = File(pathFor(root));
    if (!file.existsSync()) return LockFile.empty();
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return LockFile.empty();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('${pathFor(root)} is not a JSON object.');
    }
    return LockFile.fromJson(decoded.cast<String, dynamic>());
  }

  /// Writes the lockfile, creating `.shipway/` if needed.
  Future<void> save(String root) async {
    final file = File(pathFor(root));
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(toJson())}\n');
  }
}
