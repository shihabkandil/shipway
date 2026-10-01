import 'dart:io';

import 'package:shipway/src/core/io/process_runner.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/platform/ios/match_access.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

const String _https = 'https://github.com/acme/certs.git';
const String _ssh = 'git@github.com:acme/certs.git';

/// base64 of `ci:ghp_notARealToken`, long enough for the redactor to take.
const String _basic = 'Y2k6Z2hwX25vdEFSZWFsVG9rZW4=';

const String _pem =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt\n'
    '-----END OPENSSH PRIVATE KEY-----';

ProcessResultLite _result(int exitCode, {String stderr = ''}) =>
    ProcessResultLite(
      executable: 'git',
      arguments: const <String>['ls-remote'],
      exitCode: exitCode,
      stdout: '',
      stderr: stderr,
    );

void main() {
  group('reading the URL', () {
    test('tells SSH, HTTPS and everything else apart', () {
      expect(MatchAccess.kindOf(_ssh), MatchUrlKind.ssh);
      expect(MatchAccess.kindOf('ssh://git@host/acme/certs'), MatchUrlKind.ssh);
      expect(MatchAccess.kindOf('deploy@git.acme.io:certs'), MatchUrlKind.ssh);
      expect(MatchAccess.kindOf(_https), MatchUrlKind.https);
      expect(MatchAccess.kindOf('http://host/certs.git'), MatchUrlKind.https);
      expect(MatchAccess.kindOf('/srv/git/certs.git'), MatchUrlKind.other);
      expect(MatchAccess.kindOf('file:///srv/certs.git'), MatchUrlKind.other);
    });

    test('never shows a token embedded in it', () {
      const url = 'https://ci:ghp_secret123@github.com/acme/certs.git';
      expect(MatchAccess.hasEmbeddedCredentials(url), isTrue);
      expect(MatchAccess.displayUrl(url), _https);
      expect(MatchAccess.displayUrl(_ssh), _ssh);
    });
  });

  group('deciding before asking anybody', () {
    MatchAccessPlan decide(
      String url, {
      bool key = false,
      bool basic = false,
      bool mayPrompt = false,
    }) => MatchAccess.decide(
      url: url,
      hasPrivateKey: key,
      hasBasicAuthorization: basic,
      mayPrompt: mayPrompt,
    );

    test('the credential that fits the URL is the one probed with', () {
      expect(
        decide(_https, basic: true).method,
        MatchAuthMethod.basicAuthorization,
      );
      expect(decide(_ssh, key: true).method, MatchAuthMethod.privateKey);
      // With both set, match uses the one for the URL, and so does this.
      expect(
        decide(_https, key: true, basic: true).method,
        MatchAuthMethod.basicAuthorization,
      );
      expect(
        decide(_ssh, key: true, basic: true).method,
        MatchAuthMethod.privateKey,
      );
    });

    test('an HTTPS URL with only the SSH key is the field report', () {
      final problem = decide(_https, key: true).problem!;
      expect(problem.blocks, isTrue);
      expect(problem.reason, MatchAccessReason.wrongCredential);
      expect(problem.what, contains('HTTPS'));
      expect(problem.what, contains('only MATCH_GIT_PRIVATE_KEY is set'));
      expect(problem.fix, contains('git@host:owner/repo.git'));
      expect(problem.fix, contains('MATCH_GIT_BASIC_AUTHORIZATION'));
    });

    test('an SSH URL with only basic authorization is its mirror', () {
      final problem = decide(_ssh, basic: true).problem!;
      expect(problem.blocks, isTrue);
      expect(problem.reason, MatchAccessReason.wrongCredential);
      expect(
        problem.what,
        contains('only MATCH_GIT_BASIC_AUTHORIZATION is set'),
      );
      expect(problem.fix, contains('MATCH_GIT_PRIVATE_KEY'));
    });

    test('neither, off the workstation, names the one to set', () {
      final https = decide(_https).problem!;
      expect(https.reason, MatchAccessReason.noCredential);
      expect(https.blocks, isTrue);
      expect(https.fix, contains('Set MATCH_GIT_BASIC_AUTHORIZATION'));
      expect(decide(_ssh).problem!.fix, contains('Set MATCH_GIT_PRIVATE_KEY'));
    });

    test('on a workstation the agent or the helper may still answer', () {
      expect(decide(_https, mayPrompt: true).method, MatchAuthMethod.ambient);
      expect(decide(_ssh, mayPrompt: true).method, MatchAuthMethod.ambient);
      // Even with the wrong one set: match ignores it, and so does git.
      expect(
        decide(_https, key: true, mayPrompt: true).method,
        MatchAuthMethod.ambient,
      );
    });

    test('a URL that needs no credential variable is simply asked', () {
      expect(decide('/srv/git/certs.git').method, MatchAuthMethod.ambient);
      expect(
        decide('https://ci:token@github.com/acme/certs.git').method,
        MatchAuthMethod.ambient,
      );
    });
  });

  group('reading the answer', () {
    MatchAccessVerdict interpret(
      ProcessResultLite result, {
      MatchAuthMethod method = MatchAuthMethod.basicAuthorization,
      bool mayPrompt = false,
      String url = _https,
    }) => MatchAccess.interpret(
      result,
      url: url,
      method: method,
      mayPrompt: mayPrompt,
    );

    test('an answer is a pass', () {
      expect(interpret(_result(0)).status, MatchAccessStatus.ok);
    });

    test('a refusal blocks, and says which credential was refused', () {
      for (final stderr in <String>[
        "fatal: Authentication failed for '$_https/'",
        'remote: Repository not found.\nfatal: repository not found',
        "fatal: unable to access '$_https/': The requested URL returned "
            'error: 403',
        "fatal: could not read Username for 'https://github.com': terminal "
            'prompts disabled',
      ]) {
        final verdict = interpret(_result(128, stderr: stderr));
        expect(verdict.status, MatchAccessStatus.fail, reason: stderr);
        expect(verdict.reason, MatchAccessReason.refused);
        expect(verdict.what, contains('MATCH_GIT_BASIC_AUTHORIZATION'));
      }

      final ssh = interpret(
        _result(
          128,
          stderr:
              'git@github.com: Permission denied (publickey).\n'
              'fatal: Could not read from remote repository.\n\n'
              'Please make sure you have the correct access rights\n'
              'and the repository exists.',
        ),
        method: MatchAuthMethod.privateKey,
        url: _ssh,
      );
      expect(ssh.status, MatchAccessStatus.fail);
      // The cause, not the boilerplate git prints under it.
      expect(ssh.what, contains('Permission denied (publickey)'));
      expect(ssh.fix, contains('deploy key'));
    });

    test('a host that cannot be reached warns and does not block', () {
      for (final stderr in <String>[
        "fatal: unable to access '$_https/': Could not resolve host: "
            'github.com',
        'ssh: Could not resolve hostname github.com: nodename nor servname '
            'provided\nfatal: Could not read from remote repository.',
        'ssh: connect to host github.com port 22: Operation timed out',
        "fatal: unable to access '$_https/': Failed to connect to "
            'github.com port 443',
      ]) {
        final verdict = interpret(_result(128, stderr: stderr));
        expect(verdict.status, MatchAccessStatus.warn, reason: stderr);
        expect(verdict.reason, MatchAccessReason.unreachable);
        expect(verdict.blocks, isFalse);
      }
    });

    test('a failure it does not recognise warns rather than guessing', () {
      final verdict = interpret(_result(1, stderr: 'fatal: something new'));
      expect(verdict.status, MatchAccessStatus.warn);
      expect(verdict.reason, MatchAccessReason.unknown);
      expect(verdict.what, contains('something new'));
    });

    test('a refusal of ambient credentials at a desk is only a warning', () {
      final verdict = interpret(
        _result(128, stderr: 'git@github.com: Permission denied (publickey).'),
        method: MatchAuthMethod.ambient,
        mayPrompt: true,
        url: _ssh,
      );
      expect(verdict.status, MatchAccessStatus.warn);
    });

    test('git missing is said, not treated as a refusal', () {
      final verdict = interpret(_result(ProcessResultLite.exitCodeNotFound));
      expect(verdict.status, MatchAccessStatus.warn);
      expect(verdict.what, contains('git'));
    });
  });

  group('asking the remote', () {
    late RecordingProcessRunner runner;
    late Redactor redactor;
    late MatchAccessCheck check;

    setUp(() {
      runner = RecordingProcessRunner();
      redactor = Redactor();
      check = MatchAccessCheck(runner: runner, redactor: redactor);
    });

    test(
      'HTTPS sends the authorization as a header, and can ask nothing',
      () async {
        final verdict = await check.run(
          url: _https,
          mayPrompt: false,
          basicAuthorization: _basic,
        );
        expect(verdict.status, MatchAccessStatus.ok);

        final git = runner.invocation('ls-remote');
        expect(git.executable, 'git');
        expect(
          git.arguments,
          containsAllInOrder(<String>[
            '-c',
            'http.extraheader=Authorization: Basic $_basic',
            'ls-remote',
            '--heads',
            '--',
            _https,
          ]),
        );
        expect(git.environment, containsPair('GIT_TERMINAL_PROMPT', '0'));
        expect(git.environment, isNot(contains('GIT_SSH_COMMAND')));
        // Bounded by git itself, since the runner cannot kill it.
        expect(git.arguments, contains('http.lowSpeedTime=10'));
      },
    );

    test('the authorization is registered before git is started', () async {
      runner.onRun = (invocation) {
        if (invocation.executable != 'git') return;
        expect(
          redactor.redact(invocation.commandLine),
          isNot(contains(_basic)),
        );
      };
      // A remote that echoes the header back, as a proxy error page can.
      runner.stub(
        'ls-remote',
        exitCode: 128,
        stderr: 'fatal: Authentication failed (Authorization: Basic $_basic)',
      );

      final verdict = await check.run(
        url: _https,
        mayPrompt: false,
        basicAuthorization: _basic,
      );

      expect(verdict.status, MatchAccessStatus.fail);
      expect(verdict.what, isNot(contains(_basic)));
      expect(verdict.what, contains('***'));
      expect(verdict.fix, isNot(contains(_basic)));
    });

    test('SSH writes the key to a private file and removes it', () async {
      String? keyPath;
      String? keyContents;
      runner.onRun = (invocation) {
        if (invocation.executable != 'git') return;
        final command = invocation.environment!['GIT_SSH_COMMAND']!;
        keyPath = RegExp(r"-i '([^']+)'").firstMatch(command)!.group(1);
        keyContents = File(keyPath!).readAsStringSync();
      };

      final verdict = await check.run(
        url: _ssh,
        mayPrompt: false,
        privateKey: _pem,
      );
      expect(verdict.status, MatchAccessStatus.ok);

      // ssh refuses a key that does not end in a newline.
      expect(keyContents, '$_pem\n');
      expect(runner.invocation('chmod').arguments, <String>['600', keyPath!]);
      // chmod first: the key must be private before anything reads it.
      expect(runner.commandLines.first, startsWith('chmod 600'));

      final git = runner.invocation('ls-remote');
      final command = git.environment!['GIT_SSH_COMMAND']!;
      expect(command, contains('-o IdentitiesOnly=yes'));
      expect(command, contains('-o StrictHostKeyChecking=accept-new'));
      expect(command, contains('-o BatchMode=yes'));
      expect(command, contains('-o ConnectTimeout=10'));
      expect(git.environment, containsPair('GIT_TERMINAL_PROMPT', '0'));
      expect(git.arguments.join(' '), isNot(contains('extraheader')));

      expect(File(keyPath!).existsSync(), isFalse);
      expect(File(keyPath!).parent.existsSync(), isFalse);
    });

    test('the key file is removed when the remote refuses it too', () async {
      String? keyPath;
      runner
        ..stub(
          'ls-remote',
          exitCode: 128,
          stderr: 'git@github.com: Permission denied (publickey).',
        )
        ..onRun = (invocation) {
          if (invocation.executable != 'git') return;
          keyPath = RegExp(
            r"-i '([^']+)'",
          ).firstMatch(invocation.environment!['GIT_SSH_COMMAND']!)!.group(1);
        };

      final verdict = await check.run(
        url: _ssh,
        mayPrompt: false,
        privateKey: _pem,
      );

      expect(verdict.status, MatchAccessStatus.fail);
      expect(File(keyPath!).existsSync(), isFalse);
    });

    test('a key given as a path is used where it is', () async {
      await check.run(
        url: _ssh,
        mayPrompt: false,
        privateKey: '/runner/keys/match_deploy',
      );
      expect(runner.ran('chmod'), isFalse);
      expect(
        runner.invocation('ls-remote').environment!['GIT_SSH_COMMAND'],
        contains("-i '/runner/keys/match_deploy'"),
      );
    });

    test('the wrong credential never reaches the network', () async {
      final verdict = await check.run(
        url: _https,
        mayPrompt: false,
        privateKey: _pem,
      );
      expect(verdict.status, MatchAccessStatus.fail);
      expect(verdict.reason, MatchAccessReason.wrongCredential);
      expect(runner.invocations, isEmpty);
    });

    test(
      'at a desk it asks with what the machine has, without prompting',
      () async {
        await check.run(url: _ssh, mayPrompt: true);
        final git = runner.invocation('ls-remote');
        expect(
          git.environment!['GIT_SSH_COMMAND'],
          'ssh -o BatchMode=yes -o ConnectTimeout=10',
        );

        runner.clear();
        // Somebody's own ssh command is theirs to keep.
        await check.run(
          url: _ssh,
          mayPrompt: true,
          processEnvironment: const <String, String>{
            'GIT_SSH_COMMAND': 'ssh -F /custom',
          },
        );
        expect(
          runner.invocation('ls-remote').environment,
          isNot(contains('GIT_SSH_COMMAND')),
        );
      },
    );

    test('a token in the URL is kept out of what is printed', () async {
      runner.stub(
        'ls-remote',
        exitCode: 128,
        stderr:
            'fatal: Authentication failed for '
            "'https://ci:ghp_secret123@github.com/acme/certs.git/'",
      );
      final verdict = await check.run(
        url: 'https://ci:ghp_secret123@github.com/acme/certs.git',
        mayPrompt: false,
      );
      expect(verdict.status, MatchAccessStatus.fail);
      expect(verdict.what, isNot(contains('ghp_secret123')));
    });

    test('a remote that never answers is a warning, not a hang', () async {
      final slow = _NeverAnswers();
      final verdict = await MatchAccessCheck(
        runner: slow,
        redactor: redactor,
        timeout: const Duration(milliseconds: 20),
      ).run(url: _https, mayPrompt: false, basicAuthorization: _basic);
      expect(verdict.status, MatchAccessStatus.warn);
      expect(verdict.reason, MatchAccessReason.unreachable);
    });
  });
}

class _NeverAnswers extends RecordingProcessRunner {
  @override
  Future<ProcessResultLite> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    String? stdin,
  }) => Future<ProcessResultLite>.delayed(
    const Duration(seconds: 2),
    () => _result(0),
  );
}
