/// How much of a build machine Gradle may take, sized from the machine.
///
/// A Flutter project's `gradle.properties` commonly asks for an 8 GB heap,
/// which is a number chosen on a developer's laptop. On a 16 GB runner that
/// also holds the Kotlin daemon, a Dart compiler and whatever the other job is
/// doing, the operating system kills the build and all that is reported is
/// exit 143 — a signal, with no Gradle error to read.
///
/// The limits travel in the lane's environment and nowhere else. Nothing is
/// written to `~/.gradle`: on a self-hosted runner that directory is shared by
/// every project the machine builds, and a heap chosen for this one would
/// become everybody's.
class GradleLimits {
  const GradleLimits({
    required this.heapMegabytes,
    required this.metaspaceMegabytes,
    required this.workers,
    required this.memoryKnown,
  });

  /// Sized from [totalBytes] of physical memory, or conservatively when that
  /// could not be read.
  ///
  /// A quarter of the machine for the heap: Gradle is one of at least three
  /// JVMs in an Android build, and none of the others is counted here. Floored
  /// at [minimumHeapMegabytes], below which R8 on a real app fails with its
  /// own out-of-memory error, and capped at [maximumHeapMegabytes], past which
  /// more heap only buys longer collections.
  factory GradleLimits.forMemory(int? totalBytes) {
    if (totalBytes == null || totalBytes <= 0) {
      return const GradleLimits(
        heapMegabytes: minimumHeapMegabytes,
        metaspaceMegabytes: metaspaceMegabytesDefault,
        workers: 2,
        memoryKnown: false,
      );
    }

    final totalMegabytes = totalBytes ~/ (1024 * 1024);
    final quarter = totalMegabytes ~/ 4;
    // Whole gigabytes, rounded down: `-Xmx3891m` is correct and reads like a
    // mistake in a build log.
    final heap = (quarter ~/ 1024 * 1024).clamp(
      minimumHeapMegabytes,
      maximumHeapMegabytes,
    );

    // One worker per four gigabytes. Each may fork a process with a heap of
    // its own, so it is workers, far more than the daemon's heap, that decide
    // whether the machine runs out.
    final workers = (totalMegabytes ~/ 4096).clamp(1, maximumWorkers);

    return GradleLimits(
      heapMegabytes: heap,
      metaspaceMegabytes: metaspaceMegabytesDefault,
      workers: workers,
      memoryKnown: true,
    );
  }

  static const int minimumHeapMegabytes = 2048;
  static const int maximumHeapMegabytes = 8192;
  static const int metaspaceMegabytesDefault = 1024;
  static const int maximumWorkers = 4;

  /// The variable Gradle's launcher script passes to the client JVM.
  static const String gradleOptsVariable = 'GRADLE_OPTS';

  final int heapMegabytes;
  final int metaspaceMegabytes;
  final int workers;

  /// False when the sizes are the fallback rather than derived.
  final bool memoryKnown;

  /// What the build daemon's JVM is started with.
  String get jvmArguments =>
      '-Xmx${heapMegabytes}m -XX:MaxMetaspaceSize=${metaspaceMegabytes}m '
      '-Dfile.encoding=UTF-8';

  /// The `GRADLE_OPTS` value.
  ///
  /// `GRADLE_OPTS` on its own sizes only the small client JVM; the daemon that
  /// does the work takes `org.gradle.jvmargs` from the project's
  /// `gradle.properties`, which is exactly the value that needs overriding.
  /// Passed as a `-D` system property of the client it outranks the project's
  /// file, and the same holds for the worker count and the daemon switch.
  ///
  /// Verified against Gradle 8.14 with a project asking for `-Xmx8G`: the
  /// daemon reported the heap, metaspace and worker count given here. The
  /// quotes are needed — the launcher script splits the variable on spaces —
  /// and were what that run used.
  ///
  /// No daemon, because a daemon outlives the job: on a runner that keeps
  /// running it holds its heap until it idles out, long after the release it
  /// was started for.
  String get gradleOpts =>
      '-Dorg.gradle.jvmargs="$jvmArguments" '
      '-Dorg.gradle.workers.max=$workers '
      '-Dorg.gradle.daemon=false';

  /// The variables to add to a lane's environment.
  ///
  /// [existing] is whatever `GRADLE_OPTS` already holds. It is kept and put
  /// last: where the same property appears twice the JVM takes the later one,
  /// so a value somebody set on the runner deliberately still wins.
  Map<String, String> environment({String? existing}) {
    final kept = existing?.trim() ?? '';
    return <String, String>{
      gradleOptsVariable: kept.isEmpty ? gradleOpts : '$gradleOpts $kept',
    };
  }

  /// One line for the log, so a build that is still killed can be read
  /// against what it was allowed.
  String get summary =>
      'heap ${heapMegabytes ~/ 1024} GB, $workers '
      'worker${workers == 1 ? '' : 's'}, no daemon';
}
