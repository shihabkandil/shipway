import 'package:mason_logger/mason_logger.dart';

import '../../secrets/credential_verifier.dart';

/// Renders what `shipway secrets check --verify` found out.
///
/// Three answers, because they call for three different things: nothing, a
/// new key, and trying again later. A key that is valid but under-privileged
/// gets its own word, so that nobody rotates it.
abstract final class SecretsVerifyReport {
  static void print(Logger logger, List<VerifyResult> results) {
    logger
      ..info('')
      ..info('Verifying with each service:')
      ..info('');

    if (results.isEmpty) {
      logger.info('  Nothing in scope can be verified.');
      return;
    }

    for (final result in results) {
      final names = result.names.join(', ');
      logger
        ..info('  ${_label(result.outcome)} ${result.credential}')
        ..info('                  ${darkGray.wrap(names) ?? names}')
        ..info('                  ${result.detail}');
    }

    final rejected = results.where((r) => r.outcome.fails).toList();
    final unreachable = results
        .where((r) => r.outcome == VerifyOutcome.unreachable)
        .toList();

    logger.info('');
    if (unreachable.isNotEmpty) {
      // Said outright, because silence here reads as "verified".
      logger.warn(
        '${unreachable.map((r) => r.credential).join(', ')} could not be '
        'checked. That is not a failure, and not a pass either.',
      );
    }
    if (rejected.isNotEmpty) {
      logger.err(
        '${rejected.length} '
        '${rejected.length == 1 ? 'credential was' : 'credentials were'} '
        'rejected: ${rejected.map((r) => r.credential).join(', ')}',
      );
    }
  }

  static String _label(VerifyOutcome outcome) => switch (outcome) {
    VerifyOutcome.ok => green.wrap('             ok') ?? 'ok',
    VerifyOutcome.limited => yellow.wrap(' valid, limited') ?? 'valid, limited',
    VerifyOutcome.rejected => red.wrap('       rejected') ?? 'rejected',
    VerifyOutcome.unreachable =>
      yellow.wrap('could not check') ?? 'could not check',
    VerifyOutcome.skipped => darkGray.wrap('    not checked') ?? 'not checked',
  };
}
