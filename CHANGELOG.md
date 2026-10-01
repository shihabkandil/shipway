# Changelog

## Unreleased

Fixes from a field report of moving a release workflow to a self-hosted Mac.

Failures:

- `shipway release` attributes a failed lane to the fastlane step that failed
  and diagnoses only that step's output. A failed `pod install` is no longer
  reported as "App Store Connect refused the API key".
- The failure summary is now: failed step, fastlane's error line, then the
  fix. A failure shipway does not recognise is said to be that, with the last
  20 lines of the failing step, instead of a guess.
- Warnings such as fastlane's Ruby end-of-support notice are listed separately
  after the cause, and no longer in red.
- `shipway release` recovers from an out-of-date CocoaPods specs repository:
  it runs `pod install --repo-update` in `ios/` and re-runs the lane once. New
  diagnosis `ios.pods.specs_out_of_date`.
- Lanes run with `FASTLANE_SKIP_UPDATE_CHECK=1`, so fastlane's update
  changelog no longer buries the error.

Self-hosted runners:

- `ci.runner: hosted | self-hosted` chooses which release workflow
  `shipway generate ci` writes. `shipway init` asks, or takes `--runner`. The
  self-hosted workflow uses no setup actions and no caches, and ends each job
  with `shipway cleanup`.
- The generated workflow runs `shipway release` instead of calling fastlane,
  so the pre-flight and failure summary apply in CI. It has `ios` and
  `android` inputs to release one platform, checks credentials per platform,
  and installs Ruby 3.3 on hosted runners.
- Off the workstation, `shipway release` writes service-account files, the
  keystore and `key.properties` from their content secrets for the length of
  the run and removes them however it ends. The workflow no longer has
  "Materialise" steps. It also runs `bundle install` when `bundle check`
  fails.
- Android releases on a build machine limit Gradle through `GRADLE_OPTS`
  (heap a quarter of RAM between 2 and 8 GB, at most 4 workers, no daemon),
  which fixes builds killed with exit 143. Nothing is written to `~/.gradle`.
- New `shipway cleanup` removes credential files left by a release that was
  killed.

Pre-flight:

- `shipway doctor` checks `compileSdk` against the Android Gradle Plugin and
  the installed SDK platforms (`compile_sdk`): `compileSdk 37` with AGP below
  9 fails in doctor rather than minutes into Gradle. It warns when the
  platform is not installed, with the `sdkmanager` command.
- `shipway release ios` asks the match repository whether the credentials the
  environment has can read it before building, and names a mismatch such as an
  HTTPS `match_git_url` with only `MATCH_GIT_PRIVATE_KEY` set.
  `--no-match-check` skips it.
- A successful `shipway release` from a workstation records its Flutter and
  Xcode versions in `.shipway/lock.json`. `shipway doctor` warns when the
  machine differs (`toolchain_drift`), and a newly generated workflow pins
  them.
- `.shipway/lock.json` keeps keys it does not recognise when saved.

Secrets:

- `shipway secrets push` uploads the secrets CI needs to the GitHub repository
  through `gh`. It maps local names to repository names
  (`FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH` →
  `FIREBASE_DEV_SERVICE_ACCOUNT_JSON`), encodes file-backed secrets as the
  workflow expects, and passes every value on stdin. It prints its plan and
  asks first; `--yes`, `--dry-run` and `--repo owner/name` are supported.
- `shipway secrets check --verify` asks each service whether its credential is
  still valid with one read-only request: App Store Connect API keys and
  Firebase and Play service accounts. A network failure is reported as "could
  not check" and does not fail the command.
- `secrets list`, `check` and `push` take `--platform ios|android` and
  `--target`, so an iOS job no longer fails for an Android credential it was
  never given, and the reverse.
- `shipway secrets check` on a runner accepts a content secret for a
  path-valued variable.

## 0.1.0-beta.3

- Added `example/README.md`, so pub.dev finds and shows the example. It
  explains the example app, shows the full `shipway.yaml`, and lists the
  credentials each target needs.

## 0.1.0-beta.2

Fixes from the first field report of an app shipping to Firebase App
Distribution, and a guide to a first release.

- New in the README: a step-by-step guide from install to a first upload on
  Firebase App Distribution, Google Play or TestFlight, for apps with or
  without flavors.
- New `example/`: a `shipway.yaml` using every target and kind of `*_ref`,
  with the fastlane lanes shipway generates from it. A test keeps them in step
  with the generators.
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
- The lane's output streams while `shipway release` runs, each line marked
  with its platform. It used to appear only when the lane finished, so a long
  build looked like a hang.
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
- Fixed: `shipway setup firebase` stored and printed the first app in a
  `google-services.json`, which Firebase fills with every Android app in the
  project. Each flavor's app is now found by its package name, and one shared
  `targets.firebase.android_app_id_ref` is stored only when every flavor names
  the same app — otherwise `setup` says why it was not.
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
- Fixed: the Android `play` and `firebase` lanes ignored `versioning.strategy`
  and built with pubspec's build number, although the release plan named the
  strategy. Both now resolve the version before building. `remote` asks Play
  across every standard track with the configured key, and fails when no track
  answers; the Firebase lane asks App Distribution for the app's latest
  release.
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
