import '../core/dart/generated_parts.dart';
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
