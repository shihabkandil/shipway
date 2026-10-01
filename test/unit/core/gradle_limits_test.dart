import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/env/machine_memory.dart';
import 'package:shipway/src/core/gradle/gradle_limits.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

const int _gigabyte = 1024 * 1024 * 1024;

void main() {
  group('sizing Gradle from the machine', () {
    test('a 16 GB runner gets a quarter of it, not the 8 GB a laptop asked '
        'for', () {
      // The field report: gradle.properties asked for 8 GB, the runner had 16,
      // and the build was killed with exit 143.
      final limits = GradleLimits.forMemory(16 * _gigabyte);
      expect(limits.heapMegabytes, 4096);
      expect(limits.workers, 4);
      expect(limits.memoryKnown, isTrue);
    });

    test('a small machine is floored, not starved', () {
      // A quarter of 4 GB is a heap R8 cannot finish in.
      final limits = GradleLimits.forMemory(4 * _gigabyte);
      expect(limits.heapMegabytes, GradleLimits.minimumHeapMegabytes);
      expect(limits.workers, 1);
    });

    test('a large machine is capped', () {
      final limits = GradleLimits.forMemory(128 * _gigabyte);
      expect(limits.heapMegabytes, GradleLimits.maximumHeapMegabytes);
      expect(limits.workers, GradleLimits.maximumWorkers);
    });

    test('the heap is a whole number of gigabytes', () {
      // 18 GB / 4 is 4608 MB, which is correct and reads like a mistake.
      final limits = GradleLimits.forMemory(18 * _gigabyte);
      expect(limits.heapMegabytes, 4096);
      expect(limits.heapMegabytes % 1024, 0);
    });

    test('an unreadable machine gets the conservative answer', () {
      for (final unknown in <int?>[null, 0, -1]) {
        final limits = GradleLimits.forMemory(unknown);
        expect(limits.heapMegabytes, GradleLimits.minimumHeapMegabytes);
        expect(limits.workers, 2);
        expect(limits.memoryKnown, isFalse);
      }
    });

    test('never more than a quarter of a machine with 8 GB or more', () {
      for (var gigabytes = 8; gigabytes <= 256; gigabytes += 4) {
        final limits = GradleLimits.forMemory(gigabytes * _gigabyte);
        expect(
          limits.heapMegabytes,
          lessThanOrEqualTo(gigabytes * 1024 ~/ 4),
          reason: '$gigabytes GB',
        );
      }
    });
  });

  group('how the limits reach Gradle', () {
    final limits = GradleLimits.forMemory(16 * _gigabyte);

    test('through GRADLE_OPTS and nothing else', () {
      // Not a file: ~/.gradle on a self-hosted runner is every project's.
      expect(limits.environment().keys, <String>['GRADLE_OPTS']);
    });

    test('as org.gradle.jvmargs, which is what the daemon is sized by', () {
      // A bare -Xmx in GRADLE_OPTS sizes the client JVM and leaves the
      // project's 8 GB daemon exactly as it was.
      final options = limits.environment()['GRADLE_OPTS']!;
      expect(
        options,
        contains('-Dorg.gradle.jvmargs="-Xmx4096m -XX:MaxMetaspaceSize=1024m'),
      );
      expect(options, isNot(startsWith('-Xmx')));
    });

    test('with workers limited and no daemon left behind', () {
      final options = limits.environment()['GRADLE_OPTS']!;
      expect(options, contains('-Dorg.gradle.workers.max=4'));
      expect(options, contains('-Dorg.gradle.daemon=false'));
    });

    test('what the runner already set comes last, so it still wins', () {
      // The JVM takes the later of two definitions of one property.
      final options = limits.environment(
        existing: '-Dorg.gradle.workers.max=8',
      )['GRADLE_OPTS']!;
      expect(options, endsWith(' -Dorg.gradle.workers.max=8'));
      expect(
        options.indexOf('-Dorg.gradle.workers.max=4'),
        lessThan(options.indexOf('-Dorg.gradle.workers.max=8')),
      );
    });

    test('an empty GRADLE_OPTS adds nothing', () {
      expect(limits.environment(existing: '  '), limits.environment());
    });
  });

  group('reading how much memory there is', () {
    late RecordingProcessRunner runner;

    setUp(() => runner = RecordingProcessRunner());

    test('macOS is asked through sysctl', () async {
      runner.stub('sysctl -n hw.memsize', stdout: '17179869184');
      expect(
        await MachineMemory.totalBytes(runner, host: HostPlatform.macos),
        16 * _gigabyte,
      );
    });

    test('a sysctl that fails is an unknown, not a zero', () async {
      runner.stub('sysctl', exitCode: 1);
      expect(
        await MachineMemory.totalBytes(runner, host: HostPlatform.macos),
        isNull,
      );
    });

    test('Linux is read from /proc/meminfo, with no process spawned', () async {
      final bytes = await MachineMemory.totalBytes(
        runner,
        host: HostPlatform.linux,
        readMeminfo: () =>
            'MemTotal:       16314280 kB\n'
            'MemFree:          263204 kB\n',
      );
      expect(bytes, 16314280 * 1024);
      expect(runner.invocations, isEmpty);
    });

    test('a container with no /proc is an unknown', () async {
      expect(
        await MachineMemory.totalBytes(
          runner,
          host: HostPlatform.linux,
          readMeminfo: () => null,
        ),
        isNull,
      );
    });

    test('nonsense parses to unknown rather than to a number', () {
      expect(MachineMemory.parseSysctl('sysctl: unknown oid'), isNull);
      expect(MachineMemory.parseSysctl('0'), isNull);
      expect(MachineMemory.parseMeminfo('MemFree: 12 kB'), isNull);
    });
  });
}
