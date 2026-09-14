import 'package:shipway/src/platform/android/firebase_access.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

void main() {
  late RecordingProcessRunner runner;

  setUp(() => runner = RecordingProcessRunner());

  const script = '/shipway/tool/ruby/firebase_access_check.rb';

  Future<FirebaseAccess> check(String stdout) {
    runner.stub('firebase_access_check.rb', stdout: stdout);
    return FirebaseAccessCheck(runner: runner, scriptPath: script).check(
      directory: '/project/android',
      serviceAccountPath: '/project/firebase.json',
      appId: '1:111:android:abc',
    );
  }

  test('asks from the bundle, with the account and the app', () async {
    // The bundle, because it already holds googleauth and the App
    // Distribution client through the plugin: no gem of shipway's own.
    await check('{"ok":true}');

    final invocation = runner.invocation('firebase_access_check.rb');
    expect(invocation.executable, 'bundle');
    expect(invocation.arguments, <String>[
      'exec',
      'ruby',
      script,
      '/project/firebase.json',
      '1:111:android:abc',
    ]);
    expect(invocation.workingDirectory, '/project/android');
  });

  test('reads each answer the script gives', () async {
    expect((await check('{"ok":true}')).outcome, FirebaseAccessOutcome.ok);
    expect(
      (await check('{"ok":false,"stage":"api","status":403}')).outcome,
      FirebaseAccessOutcome.denied,
    );
    expect(
      (await check('{"ok":false,"stage":"api","status":404}')).outcome,
      FirebaseAccessOutcome.appNotFound,
    );
    expect(
      (await check(
        '{"ok":false,"stage":"auth","message":"invalid_grant"}',
      )).outcome,
      FirebaseAccessOutcome.badCredentials,
    );
  });

  test('warnings before the answer are not the answer', () async {
    final access = await check(
      'WARNING: Support for your Ruby version is going away.\n'
      '{"ok":false,"stage":"api","status":403,"message":"denied"}\n',
    );
    expect(access.outcome, FirebaseAccessOutcome.denied);
    expect(access.status, 403);
    expect(access.message, 'denied');
  });

  test('no answer at all is unknown, never a refusal', () async {
    // A check that cannot run must not block a release that would work.
    expect(
      (await check('bundler: command not found')).outcome,
      FirebaseAccessOutcome.unknown,
    );
  });

  test('the script ships where shipway looks for it', () {
    expect(FirebaseAccessCheck.locateScript(), isNotNull);
  });
}
