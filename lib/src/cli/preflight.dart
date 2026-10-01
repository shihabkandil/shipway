import '../core/config/shipway_config.dart';
import '../core/dart/generated_parts.dart';
import '../core/secrets/secret_names.dart';
import '../generators/generated_file.dart';
import '../platform/ios/match_access.dart';
import '../secrets/secret_resolver.dart';
import 'exit_codes.dart';
import 'run_context.dart';

/// Says when build_runner's output is missing or behind its source.
///
/// A warning, never a refusal: whether generated code is committed and how it
/// is built is the project's decision, and a stale part may still compile.
/// Missing ones will not, and the entrypoint analysis that follows usually
/// says so — this names the likely cause first.
void warnAboutGeneratedCode(RunContext context) {
  if (!GeneratedParts.usesBuildRunner(context.projectRoot)) return;
  final stale = GeneratedParts.find(context.projectRoot);
  if (stale.isEmpty) return;

  final missing = stale.where((part) => part.missing).length;
  final shown = stale.take(3).map((part) => part.part).join(', ');
  context.logger
    ..warn(
      '${stale.length} build_runner output${stale.length == 1 ? ' is' : 's are'} '
      '${missing == stale.length
          ? 'missing'
          : missing == 0
          ? 'older than the source'
          : 'missing or older than the source'}: '
      '$shown${stale.length > 3 ? ', and ${stale.length - 3} more' : ''}.',
    )
    ..info(
      '  Run `dart run build_runner build --delete-conflicting-outputs` first, '
      'or add it to a pipeline as a `run` step.',
    );
}

/// Checks the match repository can be cloned with the credentials this
/// environment has, before a build that would end in finding out.
///
/// Returns the exit code to stop with, or null to carry on. A release
/// pre-flight rather than a `doctor` check: the answer depends on the secret
/// chain, which `doctor` — reading only `core` — has no way to consult.
///
/// [probe] is whether the remote may be asked. The caller passes false while
/// other credentials are still missing: the mismatch that needs no network is
/// still reported, since "this URL is HTTPS but only the SSH key is set" is a
/// better answer than "a credential is not set", but there is no point
/// waiting on a remote for a release that is about to stop anyway.
Future<int?> checkMatchAccess(
  RunContext context,
  ResolvedApp app, {
  required String flavor,
  required bool probe,
}) async {
  final configured = app.matchGitUrl;
  // Only a git repository is cloned. The other storage modes authenticate to
  // a bucket, with credentials this has no business testing.
  if (configured == null || app.matchStorage != MatchStorage.git) return null;

  final environment = context.environment.environment;
  final resolver = SecretResolver(
    environment: environment,
    projectRoot: context.projectRoot,
    runner: context.runner,
    redactor: context.redactor,
    processEnvironment: context.processEnvironment,
    flavor: flavor,
    host: context.host,
  );
  // The Matchfile reads MATCH_GIT_URL first, so that is the URL the lane
  // will clone — and it may be the other kind from the one in the config.
  final url = await resolver.read(SecretNames.matchGitUrl) ?? configured;
  final privateKey = await resolver.read(SecretNames.matchGitPrivateKey);
  final basic = await resolver.read(SecretNames.matchGitBasicAuthorization);

  final MatchAccessVerdict verdict;
  if (probe) {
    verdict =
        await MatchAccessCheck(
          runner: context.runner,
          redactor: context.redactor,
        ).run(
          url: url,
          mayPrompt: environment.mayPrompt,
          privateKey: privateKey,
          basicAuthorization: basic,
          processEnvironment: context.processEnvironment,
        );
  } else {
    final problem = MatchAccess.decide(
      url: url,
      hasPrivateKey: privateKey != null,
      hasBasicAuthorization: basic != null,
      mayPrompt: environment.mayPrompt,
    ).problem;
    // With nothing set at all, the missing-credential report that follows
    // already names the variable; saying it twice helps nobody.
    if (problem == null || problem.reason == MatchAccessReason.noCredential) {
      return null;
    }
    verdict = problem;
  }

  final logger = context.logger;
  final fix = verdict.fix;
  switch (verdict.status) {
    case MatchAccessStatus.ok:
      logger.detail(verdict.what);
      return null;
    case MatchAccessStatus.warn:
      logger.warn(verdict.what);
      if (fix != null) logger.info('  $fix');
      return null;
    case MatchAccessStatus.fail:
      logger.err(verdict.what);
      if (fix != null) logger.info('  $fix');
      logger.info('  Pass --no-match-check to build anyway.');
      return ShipwayExit.environmentError;
  }
}
