# shipway

Ship Flutter apps from your own machine.

**New here?** [Ship your first release, step by step](#ship-your-first-release) ·
[Example config with every target](example/) ·
[Troubleshooting](doc/troubleshooting.md) ·
[Every command](doc/commands.md)

shipway reads one file, `shipway.yaml`, and takes care of the tedious parts of
releasing a Flutter app: flavors, fastlane lanes, signing, and uploads to
TestFlight, the App Store, Google Play and Firebase App Distribution. It runs
on your laptop, or on a CI runner if you want it to.

It also works on projects that already have flavors and fastlane set up. You
don't have to start over. `shipway init` reads what you have, and shipway only
writes to files you hand over to it.

> shipway is in beta. It works, but expect rough edges and some breaking
> changes before 1.0. Bug reports are very welcome.

## Install

```sh
dart pub global activate shipway
```

Or straight from GitHub:

```sh
dart pub global activate --source git https://github.com/shihabkandil/shipway --git-ref v0.1.0-beta.2
```

Make sure `~/.pub-cache/bin` is on your `PATH`.

## Ship your first release

The steps below take an existing Flutter app to a first upload on Firebase App
Distribution, Google Play or TestFlight. Do steps 1–5 once, then only the part of
step 6 for the destinations you want. Commands run from the root of your Flutter
project, where `pubspec.yaml` is.

The examples use two flavors, `development` and `production`. Use your own names.

### 1. Check your machine

| To ship | You need |
|---|---|
| Anything | Flutter |
| Android (Play, Firebase) | A JDK (17 or newer), Ruby 3 with Bundler |
| iOS (TestFlight, App Store) | macOS, Xcode 26 or newer, Ruby 3 with Bundler, CocoaPods, the `xcodeproj` gem (`gem install xcodeproj`) |

```sh
shipway doctor
```

Fix anything marked `fail`. A `warn` will not stop a release, but read it.

### 2. Describe your project

```sh
shipway init
```

This reads your Gradle files, Xcode project, Dart entrypoints and any fastlane
setup, and writes `shipway.yaml`. **It changes nothing else.** Open the file and
check what it found:

- `android.application_id` and `ios.bundle_id`. They are allowed to differ;
  `flutter create` often makes them `com.acme.acme_app` and `com.acme.acmeApp`.
- `signing.ios.team_id`, your Apple team.
- `flavors`, if your project already has them, with the entrypoint each one
  builds (`lib/main_dev.dart`, say).

### 3. Make sure there is at least one flavor

shipway releases a *flavor*: it builds with `--flavor` and the flavor's own
entrypoint, so a development build can never ship under the production id.

**If `init` found your flavors**, there is nothing to do here.

**If your app has no flavors yet**, add them to `shipway.yaml` under the app:

```yaml
apps:
  main:
    # ...what init wrote...
    flavors:
      development:
        suffix: .dev            # com.acme.app.dev — installs beside production
        display_name: Acme Dev
      production:
        suffix: ""              # the id you have today
        display_name: Acme
```

One flavor is fine too: `production` with `suffix: ""`.

For each flavor shipway will create `lib/main_<flavor>.dart`, which calls
`bootstrap(flavor: ...)` in `lib/main_common.dart`. It creates `main_common.dart`
once, with a placeholder app, and never touches it again. Move your app's
startup into it:

```dart
// lib/main_common.dart
Future<void> bootstrap({required String flavor}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pick this flavor's configuration here.
  runApp(const MyApp());
}
```

Leave `entrypoint` unset, or point it at a `main_<something>.dart`. Never point it
at `lib/main.dart`: shipway owns the entrypoint files it generates.

### 4. Choose where builds go

Add the destinations you want under the same app. Only configure what you use;
each target gets a lane.

```yaml
    targets:
      firebase:                 # Firebase App Distribution (Android)
        groups: [qa]            # tester group aliases
      play:
        track: internal         # internal | alpha | beta | production
      testflight:
        groups: [internal]
```

[`example/shipway.yaml`](example/shipway.yaml) shows every target and option, and
[doc/config-schema.md](doc/config-schema.md) describes each field.

### 5. Let shipway write the files

```sh
shipway generate --dry-run   # what it would create, and what is blocked
shipway adopt all            # shows the change to each file you already had, and asks
shipway generate             # writes them
shipway status               # should say "In sync."
```

`generate` writes the Android product flavors, the Xcode build configurations
and schemes, the flavor entrypoints, the fastlane lanes and pinned Gemfiles, a
GitHub Actions workflow, and a `.gitignore` block for credentials. In files that
were yours, such as `android/app/build.gradle.kts`, it only edits a marked block.
If your Gradle file already created the same flavors, `adopt` shows them being
rewritten to `getByName(...)` so they are not created twice.

Install the pinned fastlane once per platform, and commit the result:

```sh
(cd android && bundle install)
(cd ios && bundle install)     # iOS only
```

### 6. Set up each destination

Credentials are never written in `shipway.yaml`; it only names them. shipway looks
for each name in this order:

1. an environment variable,
2. `.env`, then `.env.<flavor>`, at the project root (both are git-ignored),
3. the macOS login keychain, set with `shipway secrets set NAME`.

Keep key files, such as service-account JSON, **outside** your repository and
point the variable at them with an absolute path. To see what is still missing:

```sh
shipway secrets list --flavor development
```

#### Firebase App Distribution (Android)

1. In the Firebase console, add an Android app for each flavor, using that
   flavor's application id (`com.acme.app.dev` for `development`). Download each
   `google-services.json` to `android/app/src/<flavor>/google-services.json`.
2. Record them:

   ```sh
   shipway setup firebase
   ```

   shipway reads each flavor's app id from its file, so there is no app id to
   copy anywhere.
3. Open **App Distribution** in the Firebase console, press **Get started**, and
   create your tester groups. `groups` in `shipway.yaml` takes their *aliases*.
4. In the Google Cloud console for that Firebase project, create a service
   account, give it the **Firebase App Distribution Admin** role, and download a
   JSON key. Then, in `.env`:

   ```sh
   FIREBASE_SERVICE_ACCOUNT_JSON_PATH=/Users/you/keys/acme-firebase.json
   ```

   Flavors in **different Firebase projects** need one account each. Name each
   flavor's variable in `shipway.yaml`:

   ```yaml
       flavors:
         development:
           firebase:
             android: android/app/src/development/google-services.json
             distribution:
               service_account_ref: FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH
   ```

Firebase App Distribution is Android-only in this version of shipway.

#### Google Play

1. Create an upload key:

   ```sh
   shipway setup android-signing
   ```

   This writes `android/upload-keystore.jks` and `android/key.properties`, and
   stores the password in your keychain. **Back the keystore up somewhere safe**:
   Play will not accept updates signed with a different key. shipway does not
   edit your signing setup, so make the release build use the key, in
   `android/app/build.gradle.kts`. The `import` goes at the very top of the
   file, above `plugins`:

   ```kotlin
   import java.util.Properties

   val keyProperties = Properties().apply {
       val file = rootProject.file("key.properties")
       if (file.exists()) file.inputStream().use { load(it) }
   }

   android {
       signingConfigs {
           create("release") {
               keyAlias = keyProperties["keyAlias"] as String?
               keyPassword = keyProperties["keyPassword"] as String?
               storeFile = (keyProperties["storeFile"] as String?)?.let { file(it) }
               storePassword = keyProperties["storePassword"] as String?
           }
       }
       buildTypes {
           release {
               signingConfig = signingConfigs.getByName("release")
           }
       }
   }
   ```

2. In the Play Console, create an app for each flavor you publish, using that
   flavor's application id. **Upload its first build by hand**: Play's API cannot
   create an app or take its very first bundle. Build it with:

   ```sh
   shipway build android --flavor production
   ```

3. Create a service account in the Google Cloud console, download a JSON key,
   and enable the **Google Play Android Developer API** for that project. In the
   Play Console, open **Users and permissions**, invite the service account's
   email, and give it release permissions for your app. Then, in `.env`:

   ```sh
   PLAY_SERVICE_ACCOUNT_JSON_PATH=/Users/you/keys/acme-play.json
   ```

#### TestFlight and the App Store

1. In your Apple Developer account, register an App ID for each flavor's bundle
   id (`com.acme.app` and `com.acme.app.dev`). In App Store Connect, create an app
   for each one you publish.
2. Create an App Store Connect API key: **Users and Access → Integrations → App
   Store Connect API**, with the **App Manager** role. Note the key id and issuer
   id, and download the `.p8` file. You can only download it once. Store all
   three:

   ```sh
   shipway secrets set ASC_KEY_ID
   shipway secrets set ASC_ISSUER_ID
   shipway secrets set ASC_KEY_P8_BASE64 --from-file ~/Downloads/AuthKey_ABC123.p8 --base64
   ```

   and name them in `shipway.yaml`:

   ```yaml
       signing:
         ios:
           team_id: ABCDE12345
           api_key:
             key_id_ref: ASC_KEY_ID
             issuer_id_ref: ASC_ISSUER_ID
             p8_ref: ASC_KEY_P8_BASE64
   ```

3. Signing uses fastlane `match`, which keeps certificates and profiles
   encrypted in a private git repository. Create an empty private repository,
   then:

   ```sh
   shipway setup ios-signing --match-url https://github.com/acme/certificates.git
   shipway secrets set MATCH_PASSWORD
   ```

   `setup ios-signing` records the repository and says which bundle ids have no
   App Store profile yet. For a new repository that is all of them. Add
   `--create` and it prints the `match` command that creates them; run it once.
   shipway never creates certificates on its own, because every certificate uses
   up one of your team's limited allowance.

Then run `shipway generate` again, so the lanes pick up the key and the match
repository.

### 7. Check, then release

```sh
shipway secrets check --flavor development
shipway release android --flavor development --target firebase --dry-run
```

A dry run checks everything it can without uploading. It checks the lane exists,
that the entrypoint compiles, that credentials are set, and that the bundle is
installed. For Firebase it also checks which app and project the build is for,
and whether the service account may upload to it. Then it prints the plan. When
it looks right, drop `--dry-run`:

```sh
shipway release android --flavor development --target firebase
shipway release android --flavor production --target play
shipway release ios --flavor production --target testflight
```

Each release builds the flavor, stamps it with a version, uploads it and shows
fastlane's output as it goes. The build number comes from `versioning.strategy`:
`increment` (the default) uses `pubspec.yaml`, `timestamp` uses the time, and
`remote` asks the store for the last build and adds one.

### 8. Afterwards

- **Pipelines.** Put a release sequence in `shipway.yaml` and run it with one
  command, both platforms at once:

  ```yaml
  pipelines:
    beta:
      - analyze
      - test
      - parallel:
          - release: { flavor: development, target: firebase }
          - release: { flavor: development, target: testflight }
  ```

  ```sh
  shipway run beta
  shipway run beta --resume    # after a failure, from the step that failed
  ```

- **CI.** `shipway generate` wrote `.github/workflows/release.yml`.
  `shipway secrets export` lists the repository secrets it needs, as a `gh`
  script.
- **Something failed?** [doc/troubleshooting.md](doc/troubleshooting.md) covers
  the failures seen in the field, and `shipway doctor` checks the setup again.

## Configuration

A complete `shipway.yaml`, with every target, credential reference and pipeline,
is in [example/shipway.yaml](example/shipway.yaml), beside the fastlane lanes
shipway generates from it. Every field is described in
[doc/config-schema.md](doc/config-schema.md).

Fields ending in `_ref` hold the name of an environment variable or keychain
entry, never the secret itself. shipway refuses to load a config with a real
key pasted into it, because that file gets committed.

## Commands

| Command | What it does |
|---|---|
| `doctor` | Checks Flutter, Xcode, Ruby, the JDK, CocoaPods, fastlane and your setup. |
| `init` | Creates `shipway.yaml` from what the project already has. |
| `import` | Like `init`, with more options (`--deep`, `--dry-run`). |
| `status` | Shows how the project differs from `shipway.yaml`. |
| `generate` | Writes flavors, Xcode schemes and fastlane lanes. |
| `adopt` | Lets shipway manage a file that existed before it. |
| `disown` | Hands a generated file back to you, keeping your edits. |
| `build` | Builds one flavor for one platform. |
| `release` | Builds a flavor and uploads it to a store or to Firebase. |
| `run` | Runs a pipeline from `shipway.yaml`. |
| `secrets` | Lists, checks and stores the credentials the project needs. |
| `setup` | Sets up Android signing, iOS signing with match, and Firebase. |
| `notify` | Sends a test Slack message. |

Run `shipway help <command>` for the options, or read
[doc/commands.md](doc/commands.md).

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

Please open an issue before starting on a big change. The design notes in
[doc/](doc/) explain most of the decisions.

## License

MIT. See [LICENSE](LICENSE).
