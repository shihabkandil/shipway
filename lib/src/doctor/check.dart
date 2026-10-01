import 'dart:io';

import '../core/config/shipway_config.dart';
import '../core/env/host_platform.dart';
import '../core/io/process_runner.dart';
import 'tool_version.dart';

/// Outcome of one check.
enum CheckStatus {
  /// Requirement met.
  ok,

  /// Usable, but something will bite later.
  warn,

  /// Cannot ship until this is fixed.
  fail,

  /// Not applicable to this project or machine.
  skip;

  /// Whether an overall run containing this status is still a pass.
  bool get blocks => this == CheckStatus.fail;
}

class CheckResult {
  const CheckResult({
    required this.status,
    required this.detail,
    this.version,
    this.fixHint,
    this.docsUrl,
  });

  /// Everything is fine.
  const CheckResult.ok(this.detail, {this.version})
    : status = CheckStatus.ok,
      fixHint = null,
      docsUrl = null;

  const CheckResult.warn(
    this.detail, {
    this.version,
    this.fixHint,
    this.docsUrl,
  }) : status = CheckStatus.warn;

  const CheckResult.fail(
    this.detail, {
    this.version,
    this.fixHint,
    this.docsUrl,
  }) : status = CheckStatus.fail;

  const CheckResult.skip(this.detail)
    : status = CheckStatus.skip,
      version = null,
      fixHint = null,
      docsUrl = null;

  final CheckStatus status;

  /// What was found, stated as fact.
  final String detail;

  /// The detected version, when there is one.
  final ToolVersion? version;

  /// The single next action that would resolve this.
  final String? fixHint;

  final String? docsUrl;
}

/// What a check may look at.
class DoctorContext {
  DoctorContext({
    required this.runner,
    required this.projectRoot,
    required this.config,
    required this.now,
    HostPlatform? host,
    Map<String, String>? environment,
  }) : host = host ?? HostPlatform.current,
       environment = environment ?? Platform.environment;

  final ProcessRunner runner;

  /// Root of the Flutter project, which may not contain one.
  final String projectRoot;

  /// Null when doctor runs outside a configured project — `doctor` must work
  /// before `init` does, because its whole job is telling you why nothing else
  /// will.
  final ShipwayConfig? config;

  final DateTime now;

  /// The machine this is running on. Injected so the Linux answer can be
  /// tested from a Mac, which is the only place it will be.
  final HostPlatform host;

  /// The variables this process was started with. Injected because where the
  /// Android SDK lives is read from them, and a test must not find the one on
  /// the machine running it.
  final Map<String, String> environment;

  bool get hasProject =>
      File('$projectRoot/pubspec.yaml').existsSync() &&
      Directory('$projectRoot/android').existsSync();

  bool get hasIos => Directory('$projectRoot/ios').existsSync();

  bool get hasAndroid => Directory('$projectRoot/android').existsSync();

  /// Whether this project can be built for iOS *here*.
  ///
  /// An `ios/` directory in a checkout is not the question — it is there on
  /// Linux too, and it is what makes an Android-only machine look broken.
  bool get canBuildIos => host.canBuildIos && hasIos;

  /// The platform directory whose Gemfile a lane on this machine would use.
  ///
  /// `ios` where iOS can be built, because that is the harder setup and the one
  /// that must work. Where it cannot, the Android bundle is the one that will
  /// actually be installed, and reporting on the iOS one would describe a
  /// bundle nothing here can run.
  String? get fastlaneDirectory {
    if (canBuildIos) return 'ios';
    if (hasAndroid) return 'android';
    return null;
  }
}

/// One environment check.
abstract class Check {
  /// Stable identifier, used as the JSON key and in `--only` filters.
  String get id;

  /// Human-facing name.
  String get title;

  /// Whether this check can only say something true on a Mac.
  ///
  /// [Doctor] skips these with one reason rather than running them, so a Linux
  /// machine building Android reports "not applicable" instead of a wall of
  /// failures for tools that were never going to be there.
  bool get needsMacOS => false;

  Future<CheckResult> run(DoctorContext context);
}
