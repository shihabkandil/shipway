import 'package:shipway/src/core/toolchain/fastlane_pins.dart';

import 'recording_process_runner.dart';

/// What the toolchain probe prints for a healthy bundle.
String toolchainProbeOutput({String fastlane = FastlanePins.fastlane}) =>
    '''
ruby=/Users/dev/.rvm/rubies/ruby-3.3.6/bin/ruby
ruby_version=3.3.6
bundler=2.6.3
fastlane=$fastlane
fastlane_path=/Users/dev/.rvm/gems/ruby-3.3.6/gems/fastlane-$fastlane/bin/fastlane
gem_home=/Users/dev/.rvm/gems/ruby-3.3.6
''';

/// Answers the probe `shipway release` runs before printing its plan.
///
/// Matched on `RUBY_VERSION`, which the probe script contains and a lane
/// invocation never does.
void stubFastlaneToolchain(
  RecordingProcessRunner runner, {
  String fastlane = FastlanePins.fastlane,
}) => runner.stub(
  'RUBY_VERSION',
  stdout: toolchainProbeOutput(fastlane: fastlane),
);
