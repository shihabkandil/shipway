import 'dart:convert';
import 'dart:io';

import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:shipway/src/core/toolchain/toolchain_versions.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

/// A lock file exactly as shipway wrote it before the toolchain section.
const String _oldLock = '''
{
  "version": 1,
  "generatedBy": "0.1.0-beta.3",
  "files": {
    "ios/fastlane/Fastfile": {
      "ownership": "generated",
      "mode": "full",
      "hash": "sha256:abc"
    }
  }
}
''';

void main() {
  group('the toolchain section of the lock file', () {
    test('an old lock file loads, with no toolchain', () {
      final lock = LockFile.fromJson(
        jsonDecode(_oldLock) as Map<String, dynamic>,
      );
      expect(lock.toolchain, isNull);
      expect(lock.ownershipOf('ios/fastlane/Fastfile'), Ownership.generated);
    });

    test('and saves back byte for byte', () async {
      final dir = await Directory.systemTemp.createTemp('shipway_lock');
      addTearDown(() => dir.delete(recursive: true));
      File(LockFile.pathFor(dir.path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(_oldLock.trimLeft());

      await (await LockFile.load(dir.path)).save(dir.path);

      expect(
        File(LockFile.pathFor(dir.path)).readAsStringSync(),
        _oldLock.trimLeft(),
      );
    });

    test('the schema version did not need to change', () {
      expect(LockFile.currentVersion, 1);
      expect(LockFile.empty().toJson().containsKey('toolchain'), isFalse);
    });

    test('records, reports back and round-trips', () {
      final lock = LockFile.empty();
      expect(lock.recordToolchain(flutter: '3.47.2', xcode: '26.6'), isTrue);
      expect(lock.toolchain, (flutter: '3.47.2', xcode: '26.6'));

      final decoded = LockFile.fromJson(
        jsonDecode(jsonEncode(lock.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.toolchain, (flutter: '3.47.2', xcode: '26.6'));
    });

    test('says when nothing changed, so the file is not rewritten', () {
      final lock = LockFile.empty()
        ..recordToolchain(flutter: '3.47.2', xcode: '26.6');
      expect(lock.recordToolchain(flutter: '3.47.2', xcode: '26.6'), isFalse);
      expect(lock.recordToolchain(flutter: '3.47.2'), isFalse);
      expect(lock.recordToolchain(), isFalse);
      expect(lock.recordToolchain(flutter: '3.50.0'), isTrue);
    });

    test('an Android release does not erase the recorded Xcode', () {
      final lock = LockFile.empty()
        ..recordToolchain(flutter: '3.47.2', xcode: '26.6')
        ..recordToolchain(flutter: '3.50.0');
      expect(lock.toolchain, (flutter: '3.50.0', xcode: '26.6'));
    });

    test('keys it does not know survive a load and a save', () {
      final json =
          jsonDecode('''
{
  "version": 1,
  "generatedBy": "9.9.9",
  "toolchain": {"flutter": "3.47.2", "ruby": "3.4.1"},
  "files": {},
  "futureSection": {"kept": true}
}
''')
              as Map<String, dynamic>;

      final lock = LockFile.fromJson(json)..recordToolchain(xcode: '26.6');
      final saved = lock.toJson();

      expect(saved['futureSection'], <String, dynamic>{'kept': true});
      expect(saved['toolchain'], <String, dynamic>{
        'flutter': '3.47.2',
        'ruby': '3.4.1',
        'xcode': '26.6',
      });
    });

    test('a toolchain section of the wrong shape is ignored, not fatal', () {
      final lock = LockFile.fromJson(<String, dynamic>{
        'version': 1,
        'toolchain': 'nonsense',
        'files': <String, dynamic>{},
      });
      expect(lock.toolchain, isNull);
    });
  });

  group('asking the machine', () {
    test('reads Flutter from --machine JSON, past any preamble', () {
      expect(
        ToolchainVersions.parseFlutter(
          'Downloading things...\n'
          '{\n  "frameworkVersion": "3.47.2",\n  "channel": "stable"\n}',
        ),
        '3.47.2',
      );
    });

    test('and from the banner', () {
      expect(
        ToolchainVersions.parseFlutter(
          'Flutter 3.47.2 • channel stable • https://github.com/flutter\n'
          'Tools • Dart 3.13.2 • DevTools 2.60.0',
        ),
        '3.47.2',
      );
      expect(ToolchainVersions.parseFlutter('command not found'), isNull);
    });

    test('reads Xcode as it is named, without the build number', () {
      expect(
        ToolchainVersions.parseXcode('Xcode 26.6\nBuild version 17F113'),
        '26.6',
      );
      expect(ToolchainVersions.parseXcode('Xcode 26.0.1\nBuild'), '26.0.1');
      expect(
        ToolchainVersions.parseXcode(
          'xcode-select: error: tool requires Xcode',
        ),
        isNull,
      );
    });
  });

  group('recording after a release', () {
    late Directory dir;
    late RecordingProcessRunner runner;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('shipway_toolchain');
      addTearDown(() => dir.delete(recursive: true));
      runner = RecordingProcessRunner()
        ..stub(
          'flutter --version --machine',
          stdout: '{"frameworkVersion": "3.47.2"}',
        )
        ..stub('xcodebuild -version', stdout: 'Xcode 26.6\nBuild version 1');
    });

    test('an iOS release records both, an Android one only Flutter', () async {
      expect(
        await ToolchainRecord.afterRelease(runner, root: dir.path, ios: false),
        (flutter: '3.47.2', xcode: null),
      );
      expect(
        await ToolchainRecord.afterRelease(runner, root: dir.path, ios: true),
        (flutter: '3.47.2', xcode: '26.6'),
      );
      expect((await LockFile.load(dir.path)).toolchain, (
        flutter: '3.47.2',
        xcode: '26.6',
      ));
    });

    test('keeps what the lock file already tracks', () async {
      await (LockFile.empty()..noteUnmanaged('ios/Podfile')).save(dir.path);
      await ToolchainRecord.afterRelease(runner, root: dir.path, ios: true);
      final lock = await LockFile.load(dir.path);
      expect(lock.files, contains('ios/Podfile'));
      expect(lock.toolchain!.xcode, '26.6');
    });

    test('nothing to record writes no file', () async {
      final silent = RecordingProcessRunner();
      expect(
        await ToolchainRecord.afterRelease(silent, root: dir.path, ios: true),
        isNull,
      );
      expect(File(LockFile.pathFor(dir.path)).existsSync(), isFalse);
    });

    test('an unreadable lock file does not fail a release', () async {
      File(LockFile.pathFor(dir.path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('not json');
      expect(
        await ToolchainRecord.afterRelease(runner, root: dir.path, ios: true),
        isNull,
      );
      expect(File(LockFile.pathFor(dir.path)).readAsStringSync(), 'not json');
    });
  });
}
