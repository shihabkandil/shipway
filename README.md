# shipway

Ship Flutter apps from your own machine.

shipway reads one file, `shipway.yaml`, and takes care of the tedious parts of
releasing a Flutter app: flavors, fastlane lanes, signing, and uploads to
TestFlight, the App Store, Google Play and Firebase App Distribution. It runs
on your laptop, or on a CI runner if you want it to.

It also works on projects that already have flavors and fastlane set up. You
don't have to start over. `shipway import` reads what you have, and shipway
only writes to files you hand over to it.

> shipway is in beta. It works, but expect rough edges and some breaking
> changes before 1.0. Bug reports are very welcome.

## Install

```sh
dart pub global activate shipway
```

Or straight from GitHub:

```sh
dart pub global activate --source git https://github.com/shihabkandil/shipway --git-ref v0.1.0-beta.1
```

Make sure `~/.pub-cache/bin` is on your `PATH`.

You also need Flutter. For iOS you need macOS, Xcode, Ruby 3 with Bundler, and
the `xcodeproj` gem. For Android you need a JDK. Run `shipway doctor` and it
will tell you what is missing and how to fix it.

## Quick start

In an existing Flutter project:

```sh
shipway doctor       # can this machine build and ship the app?
shipway import       # write shipway.yaml from what the project already has
shipway status       # see what shipway would change
shipway generate     # write the flavors and fastlane lanes
shipway release ios --flavor prod --target testflight --dry-run
```

Starting fresh? Use `shipway init` instead of `shipway import`.

`import` never changes your project files. `generate` only writes files that
shipway created, or files you gave it with `shipway adopt <path>`, which shows
you a diff first.

## Configuration

A typical `shipway.yaml`:

```yaml
version: 1
project:
  name: acme_app

apps:
  main:
    ios:
      bundle_id: com.acme.app
    android:
      application_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
      prod:
        suffix: ""
    signing:
      ios:
        team_id: ABCDE12345
        match_git_url: git@github.com:acme/certificates.git
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
    targets:
      testflight:
        groups: [internal]
      play:
        track: internal

pipelines:
  beta:
    - analyze
    - test
    - parallel:
        - release: { flavor: prod, target: testflight }
        - release: { flavor: prod, target: play }
```

Fields ending in `_ref` hold the name of an environment variable or keychain
entry, never the secret itself. shipway refuses to load a config with a real
key pasted into it, because that file gets committed.

Every field is described in [doc/config-schema.md](doc/config-schema.md).

## Commands

| Command | What it does |
|---|---|
| `doctor` | Checks Flutter, Xcode, Ruby, the JDK, CocoaPods and fastlane. |
| `init` | Creates a new `shipway.yaml`. |
| `import` | Reads an existing project and writes `shipway.yaml` for it. |
| `status` | Shows how the project differs from `shipway.yaml`. |
| `generate` | Writes flavors, Xcode schemes and fastlane lanes. |
| `adopt` | Lets shipway manage a file that existed before it. |
| `build` | Builds one flavor for one platform. |
| `release` | Builds a flavor and uploads it to a store or to Firebase. |
| `run` | Runs a pipeline from `shipway.yaml`. |
| `secrets` | Lists, checks and stores the credentials the project needs. |
| `setup` | Sets up Android signing, iOS signing with match, and Firebase. |
| `notify` | Sends a test Slack message. |

Run `shipway help <command>` for the options, or read
[doc/commands.md](doc/commands.md).

If a pipeline fails halfway, `shipway run beta --resume` starts again from the
step that failed. It asks before repeating an upload that may already have
gone through.

## Slack notifications

```yaml
notify:
  slack_webhook_ref: SLACK_WEBHOOK
  on: [started, failure]
  messages:
    failure: "<!here> {name} failed at {failed_step} on {branch}"
```

`on` picks the events that send a message: `started`, `success`, `failure`, or
`always`. The default is `failure` only. Each message is optional and can use
placeholders like `{name}`, `{duration}`, `{branch}` and `{run_url}`.

If you add a bot token (`slack_bot_token_ref` and `slack_channel`) and keep
`started` in `on`, shipway posts one message when the run starts and updates it
as each step finishes, instead of posting a new one each time.

Try your setup with `shipway notify test`. A Slack problem is only ever a
warning, so it never fails a release.

## How it works

- fastlane does the signing and uploading. shipway writes the lanes and runs
  them from your project's bundle, so you can always run a lane yourself. It
  loads fastlane the way a `bundle binstubs fastlane` binstub does, so a
  Homebrew fastlane on your `PATH` cannot stand in for the pinned one.
- On iOS, `flutter build ipa` builds the archive and fastlane exports and
  uploads it. Letting fastlane build a Flutter app can quietly ship the wrong
  flavor's code.
- In files you share with shipway, it only edits a marked block. Everything
  outside that block stays yours.

## Contributing

```sh
dart pub get
dart test             # unit tests, no Xcode or Ruby needed
dart test -P full     # also runs the Ruby and Xcode integration tests
```

The `full` run needs `SHIPWAY_FIXTURE_APP` set to the path of any Flutter app
with an `ios` folder.

Something failing in a way shipway does not explain? See
[doc/troubleshooting.md](doc/troubleshooting.md).

Please open an issue before starting on a big change. The design notes in
[doc/](doc/) explain most of the decisions.

## License

MIT. See [LICENSE](LICENSE).
