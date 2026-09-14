# Changelog

## Unreleased

Fixes from the first field report of an app shipping to Firebase App
Distribution.

- The `firebase` lane is generated whenever `targets.firebase` is set. It used
  to be left out, silently, unless `android_app_id_ref` was set too.
- The Firebase app id is read from the flavor's `google-services.json`, matched
  on package name, so most projects need no app id variable.
  `android_app_id_ref` still overrides it.
- `targets.firebase.changelog_from` chooses the release notes, as it does for
  TestFlight. With no `groups`, a build is uploaded without being distributed,
  instead of being sent to a `testers` group that may not exist.
- `shipway release` stops before building when the target's lane is missing,
  and says whether to regenerate the Fastfile or adopt it. `shipway doctor`
  checks the same thing (`fastlane-lanes`).
- Fixed: `changelog_from: prompt` generated a Fastfile that Ruby could not
  parse.
- Fixed: uploading an app bundle to Firebase passed an artifact type the plugin
  rejects.
- `shipway release` runs fastlane from the project's bundle the way a binstub
  does, so a Homebrew `fastlane` earlier on `PATH` can no longer replace the
  pinned gems and plugins. Previously it ran `bundle exec fastlane`, which that
  shim hijacks.
- The release plan prints the Ruby, Bundler and fastlane the lane will run on,
  and a bundle that is not installed stops the release before anything builds.
- `shipway doctor` recognises a Homebrew fastlane by its install location too,
  and reports the Ruby, `bundle` and gem home it found.
- Firebase credentials per flavor:
  `flavors.<name>.firebase.distribution.service_account_ref` and
  `android_app_id_ref`, for flavors in separate Firebase projects. The
  pre-flight asks only for the flavor being shipped, and CI export and the
  generated workflow name each account.
- `shipway release` passes the credentials its pre-flight found — in `.env`,
  `.env.<flavor>` or the keychain — to the lane, with paths made absolute.
  Previously the pre-flight could pass while the lane could not see the value.
- `.env.<flavor>` now layers over `.env` instead of replacing it.
- A Firebase release prints the service account and the app's project, warns
  when they belong to different projects, and checks with App Distribution
  that the account may upload before building. A 403 names the account, the
  project and the role to grant. `--no-access-check` skips it.
- Fixed: adopting a Gradle file whose flavors the project already created made
  Gradle fail on a flavor created twice. When shipway writes its block it now
  rewrites the project's own declarations to `getByName`, removing only the
  properties the block sets; `adopt` shows the rewrite first. What it cannot
  rewrite stops `adopt` and `generate`, naming the line.
  The rewrite tidies the blank lines where it removed something, and leaves
  every other blank line alone.
- `adopt` and `generate` refuse to write entrypoints calling a `bootstrap` that
  an existing `lib/main_common.dart` does not define, and print one to add.
- `shipway build` and `shipway release` analyse the flavor's entrypoint before
  building, so a compile error fails in seconds. `--no-analyze` skips it.
- Fixed: the generated Gemfile let bundler resolve `google-apis-core` 1.1.0,
  which crashed Firebase App Distribution uploads partway through. It now caps
  it at `>= 0.18, < 1`. `shipway doctor` reads `android/Gemfile.lock` for it
  (`gem-lock`), and a Firebase release warns before building.
- New `doc/troubleshooting.md` covering each failure in the field report.
- `shipway run` checks every flavor and target a pipeline names before its
  first step, and suggests the closest name. `shipway doctor` checks all
  pipelines (`pipelines`).
- `shipway build` and `release` warn when build_runner output is missing or
  older than its source.
- New `shipway disown <path>`: keep your edits to a generated file and stop
  shipway writing it. The message for an edited generated file now says so.
- Commands run from a subdirectory such as `android/` find `shipway.yaml` in a
  parent directory, up to the repository root.

## 0.1.0-beta.1

First public beta.

- `shipway import` reads an existing Flutter project (flavors, Xcode schemes,
  Gradle, fastlane) and writes a `shipway.yaml` that describes it. It changes
  nothing else.
- `shipway generate` and `shipway adopt` write flavors, Xcode build
  configurations and schemes, and fastlane lanes. They only touch files you
  have handed over, and show a diff first.
- `shipway doctor` checks the machine: Flutter, Xcode, Ruby, the JDK,
  CocoaPods, fastlane.
- `shipway build` and `shipway release` build a flavor and send it to
  TestFlight, the App Store, Google Play or Firebase App Distribution.
- `shipway run` runs named pipelines from `shipway.yaml`, with parallel steps
  and `--resume` after a failure.
- `shipway secrets` and `shipway setup` cover signing and credentials, using
  the keychain on your own machine and environment variables in CI.
- Slack notifications: a message per event through a webhook, or one live
  message that updates as a run goes through a bot token. The message text is
  yours to write. `shipway notify test` sends a sample.
- Fixed: an installed shipway could not find its own Xcode and Gradle helper
  scripts.
