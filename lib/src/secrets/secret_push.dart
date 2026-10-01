import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/io/process_runner.dart';
import '../core/io/redactor.dart';
import 'repository_secrets.dart';
import 'secret_resolver.dart';

/// Why `gh` cannot be used, with what to do about it.
class GitHubCliFailure implements Exception {
  const GitHubCliFailure(this.message, {this.fixHint});

  final String message;
  final String? fixHint;

  @override
  String toString() => message;
}

/// The `gh` CLI, for the three things `secrets push` asks of it.
///
/// `gh` rather than the REST API because a repository secret has to be sealed
/// with the repository's public key before it is uploaded, and `gh` already
/// does that with the login the user already has. The alternative is a
/// libsodium dependency and a token of shipway's own to look after.
class GitHubCli {
  const GitHubCli({required this.runner, required this.workingDirectory});

  final ProcessRunner runner;

  /// Where `gh` works out which repository "this one" is.
  final String workingDirectory;

  /// Throws unless `gh` is installed and signed in.
  ///
  /// Asked first and separately, so the failure is "install gh" or "sign in"
  /// rather than whatever the first upload happens to print.
  Future<void> requireReady() async {
    final version = await runner.run('gh', const <String>['--version']);
    if (version.notFound) {
      throw const GitHubCliFailure(
        'The GitHub CLI (`gh`) is not installed, and it is what uploads '
        'repository secrets.',
        fixHint:
            'Install it from https://cli.github.com (`brew install gh`), '
            'then run `gh auth login`.',
      );
    }

    final status = await runner.run('gh', const <String>['auth', 'status']);
    if (!status.ok) {
      final said = _lastLine(status.output);
      throw GitHubCliFailure(
        'The GitHub CLI is not signed in'
        '${said == null ? '.' : ': $said'}',
        fixHint: 'Run `gh auth login`, then try again.',
      );
    }
  }

  /// `owner/name` of the repository [workingDirectory] is a checkout of.
  Future<String> currentRepository() async {
    final result = await runner.run('gh', const <String>[
      'repo',
      'view',
      '--json',
      'nameWithOwner',
    ], workingDirectory: workingDirectory);
    if (result.ok) {
      try {
        final Object? decoded = jsonDecode(result.stdout);
        if (decoded is Map<String, dynamic> &&
            decoded['nameWithOwner'] is String) {
          return decoded['nameWithOwner'] as String;
        }
      } on FormatException {
        // Falls through: an answer that is not JSON is no answer.
      }
    }
    final said = _lastLine(result.output);
    throw GitHubCliFailure(
      'Could not work out which GitHub repository this is'
      '${said == null ? '.' : ': $said'}',
      fixHint: 'Pass --repo <owner/name> to say which one.',
    );
  }

  /// Sets one repository secret.
  ///
  /// The value goes in on stdin, which is where `gh secret set` reads it from
  /// when given no `--body`. An argument would put it in `ps` for as long as
  /// the upload takes, and in this process's own logs of what it ran.
  Future<ProcessResultLite> setSecret(
    String name,
    String value, {
    required String repository,
  }) => runner.run(
    'gh',
    <String>['secret', 'set', name, '--repo', repository],
    workingDirectory: workingDirectory,
    stdin: value,
  );

  static String? _lastLine(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.isEmpty ? null : lines.last;
  }
}

/// One line of a push: a repository secret, and where its value would come
/// from. Carries no value, so the plan can be printed as it stands.
class PushEntry {
  const PushEntry({required this.secret, required this.status});

  final RepositorySecret secret;

  /// How the *local* variable resolved.
  final SecretStatus status;

  /// The name in the repository.
  String get name => secret.name;

  /// The name read on this machine, which differs for a file.
  String get localName => secret.requirement.name;

  bool get resolved => status.source.found;

  /// Where the value comes from, in words.
  String get origin {
    if (status.source == SecretSource.missingFile) {
      return '$localName names ${status.detail}, which does not exist';
    }
    if (!resolved) return '$localName is not set on this machine';
    final from = status.detail ?? status.source.name;
    return secret.requirement.isPath
        ? 'the file $localName names (set in $from)'
        : from;
  }
}

/// How one upload went.
class PushOutcome {
  const PushOutcome(this.entry, {this.error});

  final PushEntry entry;

  /// Null when it was set.
  final String? error;

  bool get ok => error == null;
}

/// Moves the secrets a CI run needs from this machine to the repository.
///
/// `secrets check` could say what was missing and nothing could fix it: the
/// values lived in a `.env` or a keychain, the destination wanted them under
/// partly different names, and the step in between was grep and a pipe. The
/// names are where that went wrong — the lane reads
/// `FIREBASE_SERVICE_ACCOUNT_JSON_PATH`, the repository holds
/// `FIREBASE_SERVICE_ACCOUNT_JSON` — so this reads through the same
/// [RepositorySecret] mapping `export` prints and the workflow is generated
/// from, rather than a second table of its own.
class SecretPush {
  const SecretPush({
    required this.resolver,
    required this.redactor,
    required this.projectRoot,
  });

  /// Resolves on *this* machine. What a runner could see is beside the point:
  /// the runner is where the values are going.
  final SecretResolver resolver;
  final Redactor redactor;
  final String projectRoot;

  /// What would be pushed, and from where. Reads no value.
  Future<List<PushEntry>> plan(List<RepositorySecret> secrets) async =>
      <PushEntry>[
        for (final secret in secrets)
          PushEntry(
            secret: secret,
            status: await resolver.status(secret.requirement),
          ),
      ];

  /// The value the repository should hold for [entry], in the form the
  /// generated workflow decodes. Null when there is nothing to send.
  ///
  /// Three shapes, each matching a line of the workflow:
  ///
  /// - a path variable becomes the file's **content, as it is** — the
  ///   workflow does `echo "$SECRET" > file`, with no decoding;
  /// - a base64 variable (the keystore, the `.p8`) is sent as it is stored,
  ///   or encoded here from the file when the local value is still a path to
  ///   it — the workflow does `base64 --decode`, and encoding the bytes here
  ///   avoids the line-wrapped form GNU `base64` produces by default;
  /// - anything else is sent unchanged.
  ///
  /// Registered with the redactor before it is returned, in the form it is
  /// sent in.
  Future<String?> valueFor(PushEntry entry) async {
    final requirement = entry.secret.requirement;
    final local = await resolver.read(requirement.name);
    if (local == null) return null;

    String value = local;
    if (requirement.isPath) {
      final file = _file(local);
      if (!file.existsSync()) return null;
      value = file.readAsStringSync();
    } else if (requirement.holdsBase64) {
      // A path is short and names a file; base64 of a keystore is neither.
      final file = local.length < 1024 ? _file(local.trim()) : null;
      if (file != null && file.existsSync()) {
        value = base64.encode(file.readAsBytesSync());
      }
    }

    // `gh` drops trailing newlines itself; doing it here keeps what is
    // registered identical to what is stored.
    value = value.trimRight();
    if (value.isEmpty) return null;
    redactor.register(value);
    return value;
  }

  File _file(String path) =>
      File(p.isAbsolute(path) ? path : p.join(projectRoot, path));

  /// Uploads every resolved entry of [entries] to [repository].
  ///
  /// Carries on past a failure: one secret GitHub refuses is no reason to
  /// leave the other eight unset, and the report names which.
  Future<List<PushOutcome>> push(
    List<PushEntry> entries, {
    required GitHubCli gh,
    required String repository,
    void Function(PushOutcome outcome)? onOutcome,
  }) async {
    final outcomes = <PushOutcome>[];
    for (final entry in entries) {
      if (!entry.resolved) continue;
      final PushOutcome outcome;
      final value = await valueFor(entry);
      if (value == null) {
        outcome = PushOutcome(entry, error: 'the value is empty');
      } else {
        final result = await gh.setSecret(
          entry.name,
          value,
          repository: repository,
        );
        outcome = result.ok
            ? PushOutcome(entry)
            : PushOutcome(
                entry,
                // The runner has already redacted this; a second pass costs
                // nothing and covers a runner that did not.
                error: redactor.redact(
                  result.notFound
                      ? 'gh could not be run'
                      : result.output.isEmpty
                      ? 'gh exited ${result.exitCode}'
                      : result.output,
                ),
              );
      }
      outcomes.add(outcome);
      onOutcome?.call(outcome);
    }
    return outcomes;
  }
}
