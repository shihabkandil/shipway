# `shipway.yaml` reference

Schema `version: 1`.

Every `*_ref` field names an environment variable or keychain key — **never a
value**. A validator rejects any `*_ref` that looks like a secret rather than a
name (contains `-----BEGIN`, exceeds 100 characters, decodes as base64 of more
than 64 bytes, or matches a known credential prefix), because this file is
committed and a pasted key in it is a disclosed key.

`shipway import` derives this file from a project. Anything the readers could
not determine is **left out** rather than guessed.

## Full example

```yaml
version: 1

project:
  name: acme_app              # from pubspec.yaml
  pubspec: pubspec.yaml       # source of version and build number
  flutter_min: "3.35.0"       # doctor enforces this floor when set

apps:                         # keyed by app id; a single-app repo uses `main`
  main:
    path: .

    android:
      application_id: com.acme.app     # defaultConfig.applicationId, unsuffixed
    ios:
      bundle_id: com.acme.app          # PRODUCT_BUNDLE_IDENTIFIER, unsuffixed
      export: gym                      # gym | flutter — who turns the archive into an .ipa

    flavors:
      dev:
        suffix: .dev                   # appended to the base id on both platforms
        version_name_suffix: "-dev"    # Android versionNameSuffix
        dimension: environment         # omit unless it is not `environment`
        display_name: "Acme Dev"       # app_name on Android, CFBundleDisplayName on iOS
        entrypoint: lib/main_dev.dart  # omit when it is lib/main_<flavor>.dart
        dart_defines: { ENV: dev, API: "https://dev.api" }
        icon: assets/icon/dev.png
        firebase:
          android: android/app/src/dev/google-services.json
          ios: ios/config/dev/GoogleService-Info.plist
          distribution:                # App Distribution credentials, when this flavor's differ
            service_account_ref: FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH  # names a path
            android_app_id_ref: FB_DEV_ANDROID_APP_ID  # optional; wins over targets.firebase
      prod:
        suffix: ""                     # the unsuffixed production flavor
        display_name: "Acme"

    signing:
      ios:
        match_git_url: git@github.com:acme/certs.git
        match_storage: git             # git | googlecloud | s3
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64    # names the secret holding the base64 .p8
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
          key_alias: upload            # not a secret, so a literal

    targets:
      testflight:
        groups: [internal, qa]
        distribute_external: false
        changelog_from: git            # git | file | prompt — the "What to Test" text
      appstore:
        submit_for_review: false
        metadata_path: ios/fastlane/metadata
      play:
        track: internal                # internal | alpha | beta | production
        release_status: draft          # draft | completed | inProgress | halted
        rollout: 0.1                   # user fraction; supply derives the status
        artifact: aab                  # aab | apk
        service_account_ref: PLAY_SERVICE_ACCOUNT_JSON
      firebase:                        # App Distribution; Android only for now
        groups: [testers]              # none: uploaded, not distributed
        changelog_from: git            # git | file | prompt — the release notes
        android_app_id_ref: FB_ANDROID_APP_ID  # optional; see below
        ios_app_id_ref: FB_IOS_APP_ID  # accepted, read by nothing yet

    versioning:
      strategy: increment              # timestamp | increment | remote
      sync_ios_android: true           # keep CFBundleVersion == versionCode

secrets:
  dotenv: .env.{flavor}                # `{flavor}` substituted at resolution
  keychain: true

notify:
  slack_webhook_ref: SLACK_WEBHOOK       # one message per event
  slack_bot_token_ref: SLACK_BOT_TOKEN   # optional: one live message per run
  slack_channel: C0123ABCD               # required with the bot token
  on: [started, failure]                 # always | success | failure, or a list
  messages:                              # each replaces a default
    failure: "<!here> *{name}* failed at {failed_step}"

ci:
  environment: persistent      # workstation | ci | persistent

pipelines:                     # named sequences, run with `shipway run <name>`
  beta:
    - analyze
    - test
    - parallel:                # these two run together
        - release: { flavor: prod, target: testflight }
        - release: { flavor: prod, target: play }
```

## Minimal valid config

```yaml
version: 1
project:
  name: minimal_app
apps:
  main:
```

A map entry written with no body — `main:` or `prod:` — means "this exists and
takes every default".

## Validation rules beyond the schema

These are semantic and cannot be expressed as a shape:

- `version` must be `1`.
- `apps` must be non-empty, and when there is more than one, exactly one must be
  named `main` — otherwise no command knows what to act on without `--app`.
- Flavor names must match `^[A-Za-z][A-Za-z0-9]*$`. Both Gradle product flavors
  and Xcode build-configuration names derive from them, and Flutter matches them
  **case-sensitively**.
- Two flavors may not share a `suffix`. They would produce one application id,
  and installing the second would silently replace the first on a device.
- `rollout` must be in `(0, 1]`, mirroring `supply`'s own check. It does **not**
  require `release_status: inProgress`: supply derives the status from the user
  fraction on both the upload and the promote path, setting `inProgress` below 1
  and `completed` at 1. `shipway release --dry-run` shows the status that will
  actually be used.
- `targets.testflight.distribute_external` requires at least one entry in
  `groups`. Without one the build uploads and then fails at distribution, which
  is after the slowest part of the job.
- No `*_ref` may hold a secret rather than name one.

## Fields added beyond the original plan

Each of these exists because a real project could not otherwise be described
faithfully, and `shipway status` reported drift immediately after a clean
import. Import fidelity is a correctness gate, so a value the readers can find
must have somewhere to live.

| Field | Why |
|---|---|
| `apps.<id>.android.application_id` and `apps.<id>.ios.bundle_id` | The plan assumed one base id with a per-flavor suffix. The two platforms genuinely disagree: an Android `applicationId` may not contain a hyphen, so a project whose bundle id does (`com.acme-co.app` on iOS, `com.acme_co.app` on Android) needs two base ids. |
| `flavors.<name>.entrypoint` | Flavors named `development`/`production` very often have `main_dev.dart`/`main_prod.dart`. Assuming `main_<flavor>.dart` would build the wrong app under the right bundle id — a failure that looks like success. |
| `flavors.<name>.version_name_suffix` | Read from Gradle's `versionNameSuffix`. Without it the round trip loses the value and `status` reports drift on a freshly imported project. |
| `flavors.<name>.dimension` | Recorded only when it is not `environment`, the dimension shipway generates. Projects using another name would otherwise drift forever. |

## `notify` — telling a channel how a release went

`shipway release` and `shipway run` post to Slack when `notify` says to. A
notification that cannot be sent is a warning; it never fails the release.

| Field | Meaning |
|---|---|
| `slack_webhook_ref` | An incoming webhook. Posts a new message for each event. |
| `slack_bot_token_ref` | A bot token with `chat:write`. Posts one message and edits it as each step finishes. |
| `slack_channel` | Where the bot posts: a channel id, or `#name` for a public channel. Only with the bot token. |
| `on` | `failure` (the default), `success`, `always`, or a list that may also hold `started`. |
| `messages.started` / `.success` / `.failure` | Your own text for each event. |

The bot token wins when it resolves on the machine, and the webhook is used when
only it does. One config serves a laptop that has the webhook and a runner that
has both.

With the bot token, `started` in `on` is what turns on the live message: without
a first post there is nothing to edit. Slack notifies nobody about an edit, so a
failure is also posted as a thread reply sent to the channel. A success is just
the edit.

Messages take Slack formatting (`*bold*`, `<!here>`) and these placeholders.
An unknown one fails when the config loads, not when the message is sent.

| Placeholder | Holds |
|---|---|
| `{project}` | `project.name` |
| `{name}` | the pipeline name, or `release <flavor> → <target>` |
| `{status}` | `started`, `success` or `failure` |
| `{duration}` | how long the run took, e.g. `4m 12s`; empty when starting |
| `{failed_step}` | the step that failed; empty otherwise |
| `{flavor}`, `{target}`, `{platform}` | what was released; empty for a pipeline |
| `{version}` | the version name from `pubspec.yaml` |
| `{branch}`, `{commit}` | from git, or from the CI runner on a detached checkout |
| `{host}`, `{user}` | where it ran, and who ran it |
| `{run_url}` | a link to the CI run, when there is one |

`shipway notify test` sends a sample, so a wrong webhook shows up before a
release does.

## `changelog_from` — where the TestFlight notes come from

| Value | Where |
|---|---|
| `git` (default) | commits since the last tag, via `changelog_from_git_commits` |
| `file` | `CHANGELOG_NEXT.md` at the project root |
| `prompt` | asked at the terminal |

Whichever is chosen, `changelog:` passed to the lane wins, and the value is
resolved **before** the build so a changelog that cannot be produced fails in
seconds rather than after the slowest part of the job.

Two cases are handled rather than left to bite:

- **A repository with no tags** — the first release — has nothing to describe,
  and the action raises rather than returning nothing. The lane uploads without
  a changelog instead of failing.
- **`prompt` on CI** refuses outright. A prompt on a runner is a hang, which
  burns the job timeout and reports nothing.

## `targets.firebase` — App Distribution

**Android only in this version.** There is no iOS App Distribution lane, and
`ios_app_id_ref` is accepted but read by nothing.

The lane is generated whenever `targets.firebase` is present. Which Firebase app
a flavor uploads to is decided in this order:

1. `app_id:` passed to the lane — `shipway release` passes the id it checked
   and printed, so the plan shows what is used.
2. The variable `android_app_id_ref` names, when it is set in the config. It is
   then **required**: an unset variable fails, rather than quietly falling back
   to a file that may belong to a different app.
3. The flavor's `google-services.json` (`flavors.<name>.firebase.android`),
   matched on the flavor's application id. One file often lists every Android
   app in the Firebase project, so the first entry is never assumed.

`shipway setup firebase` finds the `google-services.json` files and records
their paths.

`groups` lists tester groups by alias. With none, the build is uploaded but not
distributed — shipway no longer invents a `testers` group, which App
Distribution rejects in any project without one. `changelog_from` works as it
does for TestFlight; with no notes, the flavor and commit are used.

**Credentials per flavor.** Flavors in separate Firebase projects need separate
service accounts, because one project's account is refused by the other. Set
`flavors.<name>.firebase.distribution.service_account_ref` to the variable
holding that flavor's service-account *path*; flavors without one use
`FIREBASE_SERVICE_ACCOUNT_JSON_PATH`. `distribution.android_app_id_ref` does the
same for the app id, and wins over the target's. The pre-flight asks only for the
flavor being shipped, and `shipway secrets export` names a content secret for
each account (`FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH` →
`FIREBASE_DEV_SERVICE_ACCOUNT_JSON`), which the generated workflow writes to a
file.

**Checked before building.** `shipway release` prints the account's email and the
app's project, warns when the service account belongs to a different project
than the `google-services.json`, and asks App Distribution — one read-only call,
from the project's bundle — whether the account can reach the app. A refusal
stops the release before the build and names the account, the project and the
role it needs (Firebase App Distribution Admin). `--no-access-check` skips the
call.

## `ios.export` — who exports the `.ipa`

`flutter build ipa` always produces the `.xcarchive`; only the export leg is in
question, and both answers are verified working.

`gym` (the default) has Flutter archive with `--no-codesign` and then
`build_app(skip_build_archive: true)` export it. The provisioning profile name
is read from match's `MATCH_PROVISIONING_PROFILE_MAPPING` at lane runtime, so it
cannot go stale, and gym also writes a dSYM zip.

`flutter` has `flutter build ipa --export-options-plist=<generated>` do both
legs in one command, with no gym in the build lane. It needs the profile name
written into `ios/ExportOptions-<flavor>.plist` ahead of time, which shipway
generates only under this setting — a stale plist sitting beside a gym export
would be a trap.

Two consequences worth knowing:

- The exported filename differs. Flutter names it after `CFBundleDisplayName`
  (`Acme Dev.ipa`), gym after the product target (`Runner.ipa`). Generated lanes
  glob `build/ios/ipa/*.ipa` rather than predict it.
- Under `gym`, the lane must pass `export_team_id`. An archive built with
  `--no-codesign` records an empty `Team`, so export has none to infer and fails
  with `exportArchive No Team Found in Archive`.

## How `display_name` reaches each platform

On Android it becomes a `resValue("string", "app_name", …)` per flavor, and the
generated block enables `buildFeatures { resValues = true }` because AGP 8+
generates no resource values without it.

On iOS it becomes an `APP_DISPLAY_NAME` build setting per configuration, and
`ios/Runner/Info.plist` is pointed at `$(APP_DISPLAY_NAME)` — Xcode expands
build-setting references in the plist at build time, which is the only mechanism
that varies the home-screen name per configuration.

That plist rewrite has a trap worth knowing about: once the literal is replaced,
any configuration that does **not** define `APP_DISPLAY_NAME` produces an app
with an empty name. shipway therefore seeds the unflavored `Debug`, `Release`
and `Profile` configurations with whatever the plist said before — once, as a
migration. It does not re-derive that value on later runs, both because the
package name is not the display name and because you may have changed it since.
