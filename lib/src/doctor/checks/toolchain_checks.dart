import '../../core/managed/lock_file.dart';
import '../../core/toolchain/toolchain_versions.dart';
import '../check.dart';

/// Whether this machine's Flutter and Xcode are the ones the last release was
/// built with.
///
/// A warning, never a failure. A different version is how upgrades happen, and
/// the next release records it; what this is for is the machine that differs
/// without anybody having decided it should — a runner image that moved, or
/// one that did not.
class ToolchainDriftCheck extends Check {
  @override
  String get id => 'toolchain_drift';

  @override
  String get title => 'Release toolchain';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final LockedToolchain? recorded;
    try {
      recorded = (await LockFile.load(context.projectRoot)).toolchain;
    } on FormatException catch (error) {
      return CheckResult.warn(
        'Could not read .shipway/lock.json: ${error.message}',
      );
    }
    if (recorded == null) {
      return const CheckResult.skip(
        'No release has recorded a toolchain in .shipway/lock.json yet.',
      );
    }

    final same = <String>[];
    final differs = <String>[];
    void compare(String name, String? was, String? now) {
      // Unanswerable on either side is not drift. The tool's own check says
      // when it is missing.
      if (was == null || now == null) return;
      if (was == now) {
        same.add('$name $now');
      } else {
        differs.add('$name $now here, $was at the last release');
      }
    }

    compare(
      'Flutter',
      recorded.flutter,
      recorded.flutter == null
          ? null
          : await ToolchainVersions.flutter(
              context.runner,
              workingDirectory: context.projectRoot,
            ),
    );
    compare(
      'Xcode',
      recorded.xcode,
      recorded.xcode == null || !context.host.canBuildIos
          ? null
          : await ToolchainVersions.xcode(context.runner),
    );

    if (differs.isNotEmpty) {
      return CheckResult.warn(
        '${differs.join('; ')}.',
        fixHint:
            'Install the recorded version to build what was last shipped, or '
            'release from this machine to record the new one. The record is '
            'in .shipway/lock.json.',
      );
    }
    if (same.isEmpty) {
      return const CheckResult.skip(
        'Could not ask this machine for the recorded tools.',
      );
    }
    return CheckResult.ok('${same.join(', ')}, as at the last release');
  }
}
