import 'dart:io';

import '../io/process_runner.dart';
import 'host_platform.dart';

/// How much physical memory this machine has.
///
/// Asked so that a build can be sized to the machine it is on rather than the
/// one its `gradle.properties` was written on. Every way of asking can fail —
/// a container without `/proc`, a `sysctl` that is not on `PATH` — so the
/// answer is nullable and the caller falls back to something conservative.
abstract final class MachineMemory {
  static const String meminfoPath = '/proc/meminfo';

  /// Total physical memory in bytes, or null when it could not be read.
  ///
  /// [readMeminfo] is the Linux source, injected because the Linux path is
  /// only ever going to be exercised from a Mac.
  static Future<int?> totalBytes(
    ProcessRunner runner, {
    required HostPlatform host,
    String? Function()? readMeminfo,
  }) async {
    switch (host) {
      case HostPlatform.macos:
        final result = await runner.run('sysctl', const <String>[
          '-n',
          'hw.memsize',
        ]);
        return result.ok ? parseSysctl(result.stdout) : null;
      case HostPlatform.linux || HostPlatform.other:
        final contents = (readMeminfo ?? _readMeminfo)();
        return contents == null ? null : parseMeminfo(contents);
      case HostPlatform.windows:
        return null;
    }
  }

  /// `sysctl -n hw.memsize` prints the number of bytes and nothing else.
  static int? parseSysctl(String output) {
    final bytes = int.tryParse(output.trim());
    return bytes == null || bytes <= 0 ? null : bytes;
  }

  /// `MemTotal:       16314280 kB` — the kernel reports kibibytes whatever the
  /// suffix says.
  static int? parseMeminfo(String contents) {
    final match = RegExp(
      r'^MemTotal:\s+(\d+)\s*kB',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(contents);
    final kibibytes = match == null ? null : int.tryParse(match.group(1)!);
    return kibibytes == null || kibibytes <= 0 ? null : kibibytes * 1024;
  }

  static String? _readMeminfo() {
    try {
      final file = File(meminfoPath);
      return file.existsSync() ? file.readAsStringSync() : null;
    } on FileSystemException {
      return null;
    }
  }
}
