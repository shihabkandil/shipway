import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/io/process_runner.dart';
import '../../core/io/redactor.dart';
import '../../core/secrets/secret_names.dart';

/// How a match repository URL is reached, which decides the credential match
/// will use for it.
enum MatchUrlKind {
  /// `git@host:path` or `ssh://`. match uses `MATCH_GIT_PRIVATE_KEY`.
  ssh,

  /// `https://` or `http://`. match uses `MATCH_GIT_BASIC_AUTHORIZATION`.
  https,

  /// A local path, `file://`, `git://`: nothing to authenticate with.
  other,
}

/// What the probe authenticates with.
enum MatchAuthMethod {
  privateKey,
  basicAuthorization,

  /// Whatever the machine already has: an SSH agent, a credential helper, or
  /// a token in the URL itself.
  ambient,
}

enum MatchAccessStatus {
  ok,

  /// Could not be answered, or answered in a way that may not hold for the
  /// lane. Said, and the release carries on.
  warn,

  /// The clone in the lane would fail. Stops the release before the build.
  fail,
}

/// Why a verdict is what it is, for a caller that treats some differently.
enum MatchAccessReason {
  reachable,

  /// The only credential set is for the other kind of URL.
  wrongCredential,

  /// Nothing is set, where nothing ambient can be assumed.
  noCredential,

  /// The remote answered, and the answer was no.
  refused,

  /// The remote could not be reached at all.
  unreachable,

  /// git failed in a way this does not recognise, or is not installed.
  unknown,
}

class MatchAccessVerdict {
  const MatchAccessVerdict({
    required this.status,
    required this.reason,
    required this.what,
    this.fix,
  });

  final MatchAccessStatus status;
  final MatchAccessReason reason;

  /// What was found, stated as fact. Never contains a credential.
  final String what;

  /// The single next action that would resolve it.
  final String? fix;

  bool get blocks => status == MatchAccessStatus.fail;
}

/// The outcome of [MatchAccess.decide]: how to probe, or why not to.
class MatchAccessPlan {
  const MatchAccessPlan.probe(MatchAuthMethod this.method) : problem = null;

  const MatchAccessPlan.refuse(MatchAccessVerdict this.problem) : method = null;

  /// Set when the probe should run.
  final MatchAuthMethod? method;

  /// Set when the credentials on hand cannot work, so asking the remote would
  /// only say so more slowly.
  final MatchAccessVerdict? problem;
}

/// Whether the match repository can be cloned with what this environment has.
///
/// A field report's `match_git_url` was HTTPS while its runner held only an
/// SSH deploy key. match ignores the credential that does not fit the URL, so
/// the clone failed minutes into the lane with an authentication error that
/// looked like a signing problem. Both halves of that are knowable before the
/// build: which credential the URL calls for is in the URL, and whether the
/// remote accepts it is one `git ls-remote`.
abstract final class MatchAccess {
  static MatchUrlKind kindOf(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('ssh://')) return MatchUrlKind.ssh;
    if (trimmed.startsWith('https://') || trimmed.startsWith('http://')) {
      return MatchUrlKind.https;
    }
    if (trimmed.contains('://')) return MatchUrlKind.other;
    // The scp form, `git@github.com:acme/certs.git`. A colon before any slash
    // is what git itself takes to mean a host.
    if (RegExp(r'^[^/\s:@]+@[^/\s:]+:').hasMatch(trimmed)) {
      return MatchUrlKind.ssh;
    }
    return MatchUrlKind.other;
  }

  /// Whether [url] carries its own `user:token@`.
  static bool hasEmbeddedCredentials(String url) {
    if (kindOf(url) != MatchUrlKind.https) return false;
    return Uri.tryParse(url.trim())?.userInfo.isNotEmpty ?? false;
  }

  /// [url] as it may be printed: a token embedded in it is a secret.
  static String displayUrl(String url) {
    if (!hasEmbeddedCredentials(url)) return url.trim();
    final uri = Uri.parse(url.trim());
    return uri.replace(userInfo: '').toString().replaceFirst('//@', '//');
  }

  /// URL kind × credentials present → what to do. Pure, so every case in the
  /// table is a unit test rather than a runner somebody has to set up.
  ///
  /// [mayPrompt] is true on a workstation, where an SSH agent or a credential
  /// helper may well grant access with neither variable set. Anywhere else
  /// there is neither, which is why the wrong credential — or none — is a
  /// refusal there and only a reason to try the ambient route here.
  static MatchAccessPlan decide({
    required String url,
    required bool hasPrivateKey,
    required bool hasBasicAuthorization,
    required bool mayPrompt,
  }) {
    final kind = kindOf(url);
    final shown = displayUrl(url);

    switch (kind) {
      case MatchUrlKind.ssh:
        if (hasPrivateKey) {
          return const MatchAccessPlan.probe(MatchAuthMethod.privateKey);
        }
      case MatchUrlKind.https:
        if (hasBasicAuthorization) {
          return const MatchAccessPlan.probe(
            MatchAuthMethod.basicAuthorization,
          );
        }
        if (hasEmbeddedCredentials(url)) {
          return const MatchAccessPlan.probe(MatchAuthMethod.ambient);
        }
      case MatchUrlKind.other:
        return const MatchAccessPlan.probe(MatchAuthMethod.ambient);
    }

    if (mayPrompt) return const MatchAccessPlan.probe(MatchAuthMethod.ambient);

    const key = SecretNames.matchGitPrivateKey;
    const basic = SecretNames.matchGitBasicAuthorization;
    final isSsh = kind == MatchUrlKind.ssh;
    final wanted = isSsh ? key : basic;
    final other = isSsh ? basic : key;
    final hasOther = isSsh ? hasBasicAuthorization : hasPrivateKey;

    if (hasOther) {
      return MatchAccessPlan.refuse(
        MatchAccessVerdict(
          status: MatchAccessStatus.fail,
          reason: MatchAccessReason.wrongCredential,
          what:
              'The match repository $shown is ${isSsh ? 'an SSH' : 'an HTTPS'} '
              'URL, but only $other is set. match ignores it for '
              '${isSsh ? 'SSH' : 'HTTPS'}, so the clone would fail partway '
              'through the lane.',
          fix: isSsh
              ? 'Set $wanted to a deploy key for that repository, or change '
                    'signing.ios.match_git_url to its https:// form.'
              : 'Change signing.ios.match_git_url to the SSH form '
                    '(git@host:owner/repo.git) so the key is used, or set '
                    '$wanted to base64 of "user:token".',
        ),
      );
    }

    return MatchAccessPlan.refuse(
      MatchAccessVerdict(
        status: MatchAccessStatus.fail,
        reason: MatchAccessReason.noCredential,
        what:
            'The match repository $shown needs a credential, and neither '
            '$key nor $basic is set. A runner has no SSH agent and no '
            'credential helper to fall back on.',
        fix:
            'Set $wanted, which is the one match uses for '
            '${isSsh ? 'an SSH' : 'an HTTPS'} URL.',
      ),
    );
  }

  /// git's own words for "you may not", across SSH and HTTPS.
  static final RegExp _refused = RegExp(
    'Permission denied|Authentication failed|could not read Username|'
    'could not read Password|terminal prompts disabled|'
    'Repository not found|returned error: 40[13]|Invalid username or '
    'password|invalid credentials|Load key|error in libcrypto|'
    'Host key verification failed|access denied',
    caseSensitive: false,
  );

  /// git's and ssh's words for "nobody answered".
  static final RegExp _unreachable = RegExp(
    'Could not resolve host|Could not resolve hostname|'
    'Temporary failure in name resolution|Connection timed out|'
    'Operation timed out|Connection refused|Network is unreachable|'
    'No route to host|Failed to connect|Connection reset|'
    'Operation too slow|SSL_connect|returned error: 5\\d\\d',
    caseSensitive: false,
  );

  /// Reads the answer to an `ls-remote`.
  ///
  /// Only a refusal blocks. A network failure is a warning because the lane
  /// runs later and elsewhere in time — a runner that cannot resolve a host
  /// this second may a minute from now — and stopping a release over it would
  /// make the check something people switch off. A failure this does not
  /// recognise warns for the same reason: its text is git's and the remote's
  /// to change.
  static MatchAccessVerdict interpret(
    ProcessResultLite result, {
    required String url,
    required MatchAuthMethod method,
    required bool mayPrompt,
  }) {
    final shown = displayUrl(url);
    if (result.ok) {
      return MatchAccessVerdict(
        status: MatchAccessStatus.ok,
        reason: MatchAccessReason.reachable,
        what: 'The match repository $shown answered ${_with(method)}.',
      );
    }
    if (result.notFound) {
      return const MatchAccessVerdict(
        status: MatchAccessStatus.warn,
        reason: MatchAccessReason.unknown,
        what:
            '`git` is not on PATH, so access to the match repository was '
            'not checked.',
        fix: 'match needs git to clone it; install git.',
      );
    }

    final said = _lastMeaningfulLine(result.output);
    if (_refused.hasMatch(result.output)) {
      // On a workstation the ambient route is not the one the lane takes: a
      // key with a passphrase is refused here, where nothing may be asked,
      // and unlocked there, where it can be.
      final ambientAtDesk = method == MatchAuthMethod.ambient && mayPrompt;
      return MatchAccessVerdict(
        status: ambientAtDesk ? MatchAccessStatus.warn : MatchAccessStatus.fail,
        reason: MatchAccessReason.refused,
        what:
            'The match repository $shown refused access ${_with(method)}: '
            '$said',
        fix: switch (method) {
          MatchAuthMethod.privateKey =>
            'Check ${SecretNames.matchGitPrivateKey} is the private half of '
                'a deploy key added to that repository, complete with its '
                'BEGIN and END lines.',
          MatchAuthMethod.basicAuthorization =>
            'Check ${SecretNames.matchGitBasicAuthorization} is base64 of '
                '"user:token", and that the token can still read that '
                'repository.',
          MatchAuthMethod.ambient =>
            ambientAtDesk
                ? 'Check `git ls-remote $shown` works in your own shell. If '
                      'it only works after a passphrase or a login prompt, '
                      'the lane will ask too.'
                : 'Check the URL, and that this machine can read it.',
        },
      );
    }

    if (_unreachable.hasMatch(result.output)) {
      return MatchAccessVerdict(
        status: MatchAccessStatus.warn,
        reason: MatchAccessReason.unreachable,
        what: 'Could not reach the match repository $shown: $said',
        fix:
            'Continuing, since the network may be back by the time the lane '
            'clones it. If the host is wrong, fix signing.ios.match_git_url.',
      );
    }

    return MatchAccessVerdict(
      status: MatchAccessStatus.warn,
      reason: MatchAccessReason.unknown,
      what:
          'Could not confirm access to the match repository $shown '
          '(git exited ${result.exitCode}): $said',
      fix: 'Continuing. Run `git ls-remote $shown` yourself to see why.',
    );
  }

  static String _with(MatchAuthMethod method) => switch (method) {
    MatchAuthMethod.privateKey => 'with ${SecretNames.matchGitPrivateKey}',
    MatchAuthMethod.basicAuthorization =>
      'with ${SecretNames.matchGitBasicAuthorization}',
    MatchAuthMethod.ambient => "with this machine's own git credentials",
  };

  /// The line worth quoting. git ends an SSH failure with two lines of
  /// boilerplate about access rights; the cause is above them.
  static String _lastMeaningfulLine(String output) {
    final lines = <String>[
      for (final line in output.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) return 'no output';
    return lines.firstWhere(
      (line) => _refused.hasMatch(line) || _unreachable.hasMatch(line),
      orElse: () => lines.first,
    );
  }
}

/// Asks the remote, with exactly the credential match would use.
class MatchAccessCheck {
  MatchAccessCheck({
    required this.runner,
    required this.redactor,
    this.timeout = const Duration(seconds: 30),
  });

  final ProcessRunner runner;

  /// Every credential handed to [run] is registered here before git is
  /// started, so neither its output nor anything quoted from it can carry one.
  final Redactor redactor;

  /// How long the remote gets. See [run] for what enforces it.
  final Duration timeout;

  /// How long ssh waits for a connection, and how long an HTTPS transfer may
  /// stall, before git gives up on its own.
  static const int connectSeconds = 10;

  /// Decides, and probes unless the decision is already a refusal.
  ///
  /// [privateKey] is the key itself or a path to one, as match accepts.
  /// [basicAuthorization] is base64 of `user:token`.
  ///
  /// It cannot hang. Nothing may be asked: `GIT_TERMINAL_PROMPT=0` stops git
  /// asking for a username and `BatchMode` stops ssh asking for a passphrase.
  /// A remote that never answers is cut off by ssh's `ConnectTimeout` or git's
  /// low-speed limit, and [timeout] returns a warning past that — the
  /// [ProcessRunner] interface has no way to kill a process, so it is git's
  /// own limits that actually end it.
  Future<MatchAccessVerdict> run({
    required String url,
    required bool mayPrompt,
    String? privateKey,
    String? basicAuthorization,
    Map<String, String> processEnvironment = const <String, String>{},
  }) async {
    final key = _nonEmpty(privateKey);
    final basic = _nonEmpty(basicAuthorization);
    redactor
      ..register(key)
      ..register(basic);
    if (MatchAccess.hasEmbeddedCredentials(url)) {
      final userInfo = Uri.parse(url.trim()).userInfo;
      redactor
        ..register(userInfo)
        ..register(userInfo.split(':').last);
    }

    final plan = MatchAccess.decide(
      url: url,
      hasPrivateKey: key != null,
      hasBasicAuthorization: basic != null,
      mayPrompt: mayPrompt,
    );
    final problem = plan.problem;
    if (problem != null) return problem;
    final method = plan.method!;

    Directory? scratch;
    try {
      final environment = <String, String>{'GIT_TERMINAL_PROMPT': '0'};
      const sshOptions = '-o BatchMode=yes -o ConnectTimeout=$connectSeconds';

      if (method == MatchAuthMethod.privateKey) {
        final String keyPath;
        if (key!.contains('-----BEGIN')) {
          // mkdtemp makes the directory 0700, so the key is unreadable to
          // anybody else from the moment it exists; the chmod is for ssh,
          // which refuses a key file that is group- or world-readable.
          scratch = await Directory.systemTemp.createTemp('shipway_match_key');
          keyPath = p.join(scratch.path, 'key');
          await File(
            keyPath,
          ).writeAsString(key.endsWith('\n') ? key : '$key\n', flush: true);
          await runner.run('chmod', <String>['600', keyPath]);
        } else {
          keyPath = key;
        }
        // IdentitiesOnly, so an agent's keys cannot answer for the one being
        // tested. accept-new, because a runner has never seen the host and a
        // prompt to trust it is a hang.
        environment['GIT_SSH_COMMAND'] =
            "ssh -i '${keyPath.replaceAll("'", r"'\''")}' "
            '-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new '
            '$sshOptions';
      } else if (MatchAccess.kindOf(url) == MatchUrlKind.ssh &&
          !processEnvironment.containsKey('GIT_SSH_COMMAND')) {
        // Ambient: the machine's own keys and known hosts, but still unable
        // to ask. Somebody's own GIT_SSH_COMMAND is left alone.
        environment['GIT_SSH_COMMAND'] = 'ssh $sshOptions';
      }

      final arguments = <String>[
        '-c',
        'http.lowSpeedLimit=1',
        '-c',
        'http.lowSpeedTime=$connectSeconds',
        if (method == MatchAuthMethod.basicAuthorization) ...<String>[
          '-c',
          'http.extraheader=Authorization: Basic $basic',
        ],
        'ls-remote',
        '--heads',
        '--',
        url.trim(),
      ];

      final ProcessResultLite result;
      try {
        result = await runner
            .run('git', arguments, environment: environment)
            .timeout(timeout);
      } on TimeoutException {
        return MatchAccessVerdict(
          status: MatchAccessStatus.warn,
          reason: MatchAccessReason.unreachable,
          what:
              'The match repository ${MatchAccess.displayUrl(url)} did not '
              'answer within ${timeout.inSeconds} seconds.',
          fix: 'Continuing; the lane will try again when it clones it.',
        );
      }

      final verdict = MatchAccess.interpret(
        result,
        url: url,
        method: method,
        mayPrompt: mayPrompt,
      );
      // Already redacted by the runner. Done again because this text is
      // printed, and a runner that is not the system one makes no promise.
      return MatchAccessVerdict(
        status: verdict.status,
        reason: verdict.reason,
        what: redactor.redact(verdict.what),
        fix: verdict.fix == null ? null : redactor.redact(verdict.fix!),
      );
    } finally {
      if (scratch != null && scratch.existsSync()) {
        await scratch.delete(recursive: true);
      }
    }
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value.trim();
}
