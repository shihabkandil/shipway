# shipway command reference

Every command shipway currently ships. Phases 0, 1A, 1B and the first half of
Phase 2 are implemented; commands the plan describes but which do not exist yet
are listed under [Not built yet](#not-built-yet) rather than documented as if
they worked.

```
shipway <command> [arguments]
```

## The shape of the thing

shipway reads a project as readily as it writes one, and the two directions are
deliberately separate:

```
  read                                   write
  ────                                   ─────
  import  ──▶ shipway.yaml ──▶ generate ──▶ project files
  status  ──▶ what differs      adopt   ──▶ permission to write
  doctor  ──▶ can this machine ship it?
  build   ──▶ the artifact
```

`import` never modifies your project. `generate` never writes a file shipway
does not own — `adopt` is the only way to hand one over, and it shows you the
diff first.

## Global options

Accepted before any command.

| Option | Meaning |
|---|---|
| `-h, --help` | Usage for shipway or for one command. |
| `--version` | Print the version and exit. |
| `-v, --verbose` | Show every command shipway runs and its full output. |
| `--no-color` | Disable coloured output. |
| `-y, --yes` | Assume yes for every prompt. Implies non-interactive. |
| `--config=<path>` | Use this `shipway.yaml` instead of searching for one. |
| `--app=<id>` | Which app in a monorepo to act on. |
| `--env=<name>` | `workstation`, `ci` or `persistent`. Decides which sources secrets may come from and whether shipway may prompt. Detected when omitted; also settable as `SHIPWAY_ENV` or `ci.environment`. |

**Where the project is.** Without `--config`, shipway looks for `shipway.yaml`
in the current directory and then in each parent, stopping at the root of the
repository, and acts on the directory it finds. Running from `android/` or
`ios/` therefore acts on the project, not on a directory where every relative
path points somewhere else. `--verbose` says when it has moved.

## Exit codes

Coarse on purpose, so a CI script can tell the three kinds of failure apart
without parsing output.

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | You asked for something invalid — bad flags, bad config, a conflict needing a decision. |
| `2` | This machine cannot do it — a missing or too-old tool, a failing check, a failed build. |
| `70` | A bug in shipway. Worth reporting. |

---

## `shipway doctor`

> Check whether this machine can build and ship this app.

```
shipway doctor [--json] [--only <id>]
```

Runs every environment check and prints a checklist with a fix hint for
anything wrong. Works **before** `init` does — its whole job is telling you why
nothing else will, so it never requires a `shipway.yaml`.

| Option | Meaning |
|---|---|
| `--json` | Emit the report as JSON, for CI. |
| `--only=<id>` | Run only the named checks. Repeatable. |

Check ids: `flutter`, `dart`, `xcode`, `cocoapods`, `ruby`, `bundler`,
`fastlane`, `xcodeproj_gem`, `pbxproj_object_version`, `jdk`, `gradle_dsl`,
`gradle_wrapper`, `play_target_sdk`, `firebase`, `flutterfire`, `keychain`,
`fastlane-shim`, `gemfile-pins`, `fastlane-lanes`, `gem-lock`, `pipelines`.

`fastlane-lanes` fails when a target in `shipway.yaml` has no lane in its
platform's Fastfile, and says whether to regenerate the Fastfile or, if it was
your project's own, to add the lane or adopt the file.

A **warning** means it will work now and bite later — a Ruby near end of
support, a store deadline approaching. A **failure** blocks shipping.

**Off macOS** the Apple checks — `xcode`, `cocoapods`, `xcodeproj_gem`,
`pbxproj_object_version`, `keychain` — are **skipped with a reason** rather than
failed, and are not run at all: there is no `xcodebuild` to find, and reporting
its absence as a failure would say a machine cannot ship an app it ships fine.
The summary line says `Ready to ship Android` there, because a bare "ready to
ship" would be true of half an app. `gemfile-pins` and `fastlane-shim` read
`android/Gemfile` instead of `ios/Gemfile`, since that is the bundle a lane on
that machine would actually install. `--json` carries `host` and `canBuildIos`
so a CI job can tell what a pass covered.

Two checks are worth knowing about because their symptoms are misleading:

- `fastlane-shim` catches a Homebrew `fastlane`, which is a shell script that
  overrides `GEM_HOME` and `GEM_PATH`. `bundle exec fastlane` then silently runs
  a different fastlane against different gems, and fails with
  `Could not find <gem> in locally installed gems` — which reads like a broken
  bundle rather than a hijacked one. The fix is a binstub.
- `gemfile-pins` checks that the pins in the generated Gemfile can actually be
  solved on your Ruby. `bundle install` does not degrade when they cannot; it
  installs nothing.
- `gem-lock` reads `android/Gemfile.lock` for `google-apis-core` 1.x beside the
  Firebase plugin, which crashed uploads partway through. It fails when
  `targets.firebase` is configured and warns otherwise. See
  [`troubleshooting.md`](troubleshooting.md).

## `shipway init`

> Set up shipway in this project.

```
shipway init [--force]
```

The front door. Looks at the project, then writes a `shipway.yaml` describing
what is already there. **No project file is modified.**

| Option | Meaning |
|---|---|
| `--force` | Overwrite an existing `shipway.yaml`. |

## `shipway import`

> Read this project and write a shipway.yaml describing it.

```
shipway import [--deep] [--dry-run] [--out <path>] [--force]
```

The read direction, in full. Derives a config from the Gradle files, the Xcode
project, the Dart entrypoints, the Firebase config and any existing fastlane
setup. Writes exactly two things — `shipway.yaml` and `.shipway/lock.json` —
and nothing else.

Anything the readers could not determine is **left out** rather than guessed.

| Option | Meaning |
|---|---|
| `--deep` | Ask Gradle for the resolved build model. Slower, but reads values the fast parser cannot — computed application ids, values from `ext` blocks. |
| `--dry-run` | Print the derived config without writing. |
| `--out=<path>` | Where to write it. Defaults to `shipway.yaml`. |
| `--force` | Overwrite an existing config. |

`--deep` runs a real Gradle build model, so it needs a project whose wrapper
Gradle version satisfies Flutter's floor. `doctor`'s `gradle_wrapper` check
tells you if it does not.

## `shipway status`

> Show how this project differs from shipway.yaml.

```
shipway status [--json]
```

Re-reads the project and compares it to the config. On a freshly imported
project this reports no drift — that round trip is a correctness gate, not a
nicety.

| Option | Meaning |
|---|---|
| `--json` | Emit the drift report as JSON. |

## `shipway generate`

> Write the files shipway.yaml describes.

```
shipway generate [flavors|fastlane|all] [--dry-run] [--force] [--no-prune]
```

The write direction. Defaults to `all`.

| Option | Meaning |
|---|---|
| `--dry-run` | Show what would change, write nothing. |
| `--force` | Overwrite content you have edited *inside a shipway block*. Never overrides an unadopted file. |
| `--no-prune` | Keep files shipway generated that the config no longer describes. |

**Groups**

| Group | Produces |
|---|---|
| `flavors` | Android product flavors, shared Xcode schemes, Dart entrypoints, dart-define files |
| `fastlane` | Gemfiles, Pluginfiles, Appfiles, Matchfile, ExportOptions plists, the iOS Fastfile |
| `ci` | A GitHub Actions release workflow |
| `all` | All of the above, plus the `.gitignore` block |

Individual generators can also be named: `android-flavors`, `ios-schemes`,
`entrypoints`, `dart-defines`, `gemfiles`, `pluginfiles`, `appfiles`,
`matchfile`, `export-options`, `ios-fastfile`, `gitignore`.

**What it refuses to do.** A file that existed before shipway is reported as
`conflict` and left alone. That refusal is the feature: on a real project the
Gradle build file and the Xcode project were there first, and generating over
them would replace a working build. Run `shipway adopt` to hand one over.

Re-running is a byte-identical no-op.

**Cleaning up after a config change.** Rename a flavor from `dev` to `staging`
and the files derived from the old name are removed:

```
  removed  lib/main_dev.dart
           no longer described by shipway.yaml
  release  dart_defines/dev.json
           no longer described by shipway.yaml, but you have edited it —
           left in place and no longer managed
```

A file is only deleted when shipway wrote it *and* its content is still exactly
what shipway wrote, so nothing you authored is ever removed. One you have edited
is left alone and handed back to you — reported once, then never again.

Cleanup is scoped to the generators that ran, so `shipway generate flavors`
cannot touch the fastlane files, and a generator that could not run (no readable
`Runner.xcscheme` to derive schemes from) sweeps nothing, because producing
nothing is not the same as no longer being asked to. See
[`orphan-cleanup.md`](orphan-cleanup.md).

Cleanup is skipped, with a note, when the config declares more than one app:
generated paths are not app-scoped yet.

Besides files, `generate` also mutates `ios/Runner.xcodeproj/project.pbxproj`
and `ios/Runner/Info.plist` through adapters that back up, verify and restore on
failure.

## `shipway adopt`

> Let shipway write to a file that was here before it.

```
shipway adopt <path|all> [--dry-run]
```

Shows the difference adopting would make, then records the file as shipway's to
write. Ownership lives in `.shipway/lock.json`, which is committed on purpose —
it is a team-wide fact, and a teammate who pulls the repo inherits the same
permissions.

| Option | Meaning |
|---|---|
| `--dry-run` | Show what adopting would change without recording anything. |

**Flavors the project already declares.** shipway's managed block *creates*
each flavor, so a project that creates them too declares each one twice, and
Gradle fails because the flavor already exists. When shipway writes the block it
rewrites the project's own declarations to *configure* those flavors instead:
`create("dev")` becomes `getByName("dev")`; the properties the block sets —
`dimension`, `applicationIdSuffix`, `versionNameSuffix`, the `app_name` resource
— are removed; a declaration left empty is removed, and so is a
`flavorDimensions` line naming only shipway's dimensions. What is yours —
`manifestPlaceholders`, `buildConfigField`, signing — stays. The block goes first
inside `android { }`, so `getByName` finds the flavor it created, and `adopt`
shows all of this in its diff before asking.

In your own section, then, *configure* flavors with `getByName("<flavor>")`;
never `create` one shipway manages. A declaration shipway cannot rewrite with
confidence — flavors created in a loop, or `productFlavors.create(...)` outside a
`productFlavors { }` block — stops `adopt` and `generate`, naming the line.

**Entrypoints that would not compile.** Each generated `lib/main_<flavor>.dart`
calls `bootstrap({required String flavor})` in `lib/main_common.dart`. shipway
creates that file when it is missing. When the project already has one with no
`bootstrap`, `adopt` and `generate` refuse the entrypoints and print a
declaration to add, rather than writing code that fails in the middle of a
build.

### `ios-signing`

Adopts a certificates repository rather than initialising one. It clones the
repo, lists which bundle ids have an App Store profile, compares that against
the flavors in your config, and records the repository in `shipway.yaml`.

```
$ shipway setup ios-signing

  appstore     com.acme.app
  appstore     com.acme.app.dev
  development  com.acme.app

1 bundle id has no appstore profile: com.acme.app.staging
Re-run with --create to be told how to fill them, or add them with match yourself.
```

Exits `2` when a bundle id is uncovered, so it works as a pre-flight.

**It never decrypts anything.** match encrypts each file in place and leaves the
*name* alone, so which bundle ids are covered is answerable from the layout —
no `MATCH_PASSWORD`, no Apple credentials, and shipway never handles a
certificate, only the question of whether one exists. The only command it runs
is `git clone`.

**It never creates.** A certificates repository is shared: reshaping one breaks
signing for everyone using it, and every certificate spends one of a team's
limited Apple allowance. `--create` changes the *advice* — it tells you the
`fastlane match` command to run — not the safety.

### `firebase`

Correlates the config files already in the project with your flavors, reads the
app id out of each, records the paths in `shipway.yaml`, and puts the app ids
where the resolver looks.

```
$ shipway setup firebase

  android  dev
           android/app/src/dev/google-services.json
           app id 1:111:android:aaa
  ios      dev
           ios/config/dev/GoogleService-Info.plist
           app id 1:111:ios:bbb

[WARN] flavor `prod` has no google-services.json, but `dev` does.
  Add the missing google-services.json, or confirm those flavors are meant
  to share one Firebase project.
```

That warning is the point of the command. A project with a config file for one
flavor and not another builds fine and fails at runtime — or worse, reports to
the wrong Firebase project.

**It never downloads anything.** A `google-services.json` belongs to one
specific Firebase app; a tool that fetched one would have to guess which, and
guessing wrong surfaces as an app reporting to somebody else's analytics.

## `shipway disown`

> Stop shipway writing to a file, and keep it exactly as it is.

```
shipway disown <path> [--dry-run]
```

The inverse of `adopt`, and how to keep an edit to a file shipway generated —
a lane added to a generated Fastfile, say. The file is left exactly as it is,
recorded as yours in `.shipway/lock.json`, and `generate` reports it as `yours`
rather than blocking on it. `shipway adopt <path>` hands it back.

When `generate` finds a generated file you have edited, it says both ways out:
`--force` replaces your edit, `disown` keeps it.

There is no "accept this edit" command, on purpose. Recording an edited file as
shipway's own would make the next `generate` see no edit at all, and overwrite
it without warning the moment `shipway.yaml` changed.

## `shipway build`

> Build a flavor for one platform.

```
shipway build ios|android --flavor <flavor> [options]
```

Constructs the `flutter build` invocation from the same resolved config the
generators used. This exists because the command is easy to get wrong in ways
that **do not fail**:

- omit `--target` and Flutter compiles `lib/main.dart` under the flavor's bundle
  id — the wrong app, built successfully;
- omit `--dart-define-from-file` and it builds against the wrong backend.

Neither produces an error, so shipway assembles the command rather than leaving
it to memory.

**Stale generated code is pointed out.** When `build_runner` is a dev
dependency, a `part 'x.g.dart';` whose file is missing, or older than the
library declaring it, is warned about before building, with the command that
regenerates it. It never stops the build: whether generated code is committed is
the project's decision.

**The entrypoint is analysed first.** A release build compiles Dart minutes in,
behind Gradle or Xcode. `dart analyze` on the flavor's entrypoint takes seconds,
so `build` and `release` run it first and stop on an error — warnings never
stop anything. It is skipped when packages are not resolved yet, since then
every import looks broken. `--no-analyze` skips it.

| Option | Meaning |
|---|---|
| `-f, --flavor <name>` | Which flavor. Required when the config declares any. |
| `--artifact appbundle\|apk` | Android only. Defaults to `appbundle`. |
| `--debug` | Build debug instead of release. |
| `--no-codesign` | iOS only: archive without signing, which is what the generated fastlane lane uses because gym signs on export. |
| `--dry-run` | Print the command that would run, and stop. |
| `--no-analyze` | Skip analysing the flavor's entrypoint before building. |

`shipway build ios` off macOS exits `2` immediately, naming the host and
pointing at `shipway build android`. `shipway build android` works anywhere
Flutter and a JDK do.

**It reads successful builds too.** `flutter build` exits `0` on an archive
whose `Info.plist` lost its version keys, and App Store Connect then rejects the
upload. A zero exit code is not evidence an artifact can be shipped, so the
output of a *successful* build is classified as well, and anything recognised is
reported as a warning with its remedy.

For iOS the reported artifact is the `.xcarchive`, not an `.ipa`: the export
names the `.ipa` after `CFBundleName` under Flutter and after the product target
under gym, so it can only be found by globbing `build/ios/ipa/*.ipa`. Since
shipway varies only `CFBundleDisplayName` per flavor, every flavor exports to
the same filename — which is why the generated lanes accept only an `.ipa`
written after their own build began.

## `shipway secrets`

> Show which credentials this project needs, put them somewhere, and say what
> a CI repository has to be given.

```
shipway secrets list|check|set|import|export
```

`list` reports; `check` exits `2` when a required credential is missing. Run
`check` as the first step of a CI job and a twenty-minute build that dies at the
upload becomes a five-second failure that names the variable.

**Neither ever prints a value.** That is a property of the types rather than of
care: the resolver returns a status carrying a *source*, and is never handed a
secret to leak.

```
$ shipway secrets check --env ci

Environment: ci (from --env). Looking in: environment.

  missing ASC_KEY_P8_BASE64
          signing.ios.api_key.p8_ref
  no file PLAY_SERVICE_ACCOUNT_JSON_PATH
          the play lane
          names play.json, which does not exist
       ok MATCH_PASSWORD
          the certificates lane — found in environment

1 of 3 resolved.
```

A variable naming a file that is not there is reported as missing, because it
is the same failure as being unset — only found twenty minutes later.

The list is derived from `shipway.yaml`: every `*_ref` field names a credential,
so the config is the single source of truth for what a project needs. A test
asserts the names checked here are the ones the generated lanes actually read —
a pre-flight that checks a different name than the lane reads is worse than
none, because it reports green and the build still fails.

### Where secrets are looked for

The chain depends on `--env`, because a prompt on a build machine is a hang, and
a hang is worse than a failure:

| Environment | Chain |
|---|---|
| `workstation` | environment → `.env` → keychain → prompt |
| `ci` (hosted runner) | environment |
| `persistent` (self-hosted, Mac mini) | environment → `.env` |

The login keychain is deliberately absent off the workstation: on a headless Mac
it may not be unlocked after a reboot, and depending on it is what makes
self-hosted builders fail in ways that look like signing problems. It is absent
off macOS for a blunter reason — there is no such keychain — and since the chain
is printed, listing it would be advice to put a value somewhere nothing will
ever read it.

See [`execution-environments.md`](execution-environments.md).

### `shipway secrets set <NAME>`

> Put one credential in the login keychain.

```
shipway secrets set <NAME> [--from-file <path>] [--stdin] [--base64]
```

Prompts, hidden, when given neither `--from-file` nor `--stdin` — and refuses
rather than prompting anywhere a prompt would hang.

| Option | Meaning |
|---|---|
| `--from-file=<path>` | Read the value from a file. |
| `--stdin` | Read the value from standard input. |
| `--base64` | Encode before storing. What `ASC_KEY_P8_BASE64` and the Android keystore need. |

`--base64` exists rather than a line in a README because the obvious command is
wrong on half of the machines that run it: GNU `base64` wraps at 76 columns by
default and the wrapped form does not decode. shipway encodes the bytes itself.

**The value never reaches a command line.** `security add-generic-password -w`
with no argument reads it from stdin, so it is not in `ps` and not in your shell
history. Nothing is read back afterwards, not even to check the write landed —
the check asks whether the item exists, which hands no secret back.

That check matters: given a value and a confirmation that differ, `security`
prints `passwords don't match`, stores nothing, and **exits 0**. A zero exit
code is not evidence anything was written.

The login keychain cannot hold a multi-line value, and shipway says so instead
of storing the first line. Encode it, or — for `MATCH_GIT_PRIVATE_KEY`, which
only a runner reads — set it as a repository secret, where multi-line values are
fine.

Off macOS there is no login keychain, and `set` fails saying to use `.env`.

### `shipway secrets import`

> Move a `.env` file into the login keychain.

```
shipway secrets import [--from <path>] [--force] [--flavor <f>]
```

Reads every assignment and stores it. Names already in the keychain are **kept**
and reported, not overwritten — the point of moving values off disk is not to
lose the ones already moved. `--force` replaces them.

The file is left exactly as it was, and the report says so: this is a copy, not
a move, and deleting it is your call once `shipway secrets check` reports green.

### `shipway secrets export`

> Say what a CI repository has to be given.

```
shipway secrets export [--format gh|actions|env]
```

Emits the **names** — never a value, because it never reads one.

| Format | Produces |
|---|---|
| `gh` | A `gh secret set` script. Each line prompts, so no value reaches your shell history. |
| `actions` | An `env:` block, for a workflow shipway did not write. |
| `env` | A `.env` template with empty values. |

The list is derived for the **`ci`** environment whatever machine you run it on,
because the thing being wired up is the runner. A workstation's list would omit
the match credential a runner cannot clone without and add an interactive Apple
ID nobody should put in a repository.

Two names are swapped on the way out. `PLAY_SERVICE_ACCOUNT_JSON_PATH` and
`FIREBASE_SERVICE_ACCOUNT_JSON_PATH` are *paths*, and you cannot put a path in
GitHub — the workflow writes the file from a secret and points the variable at
it. So what is named is `PLAY_SERVICE_ACCOUNT_JSON` and
`FIREBASE_SERVICE_ACCOUNT_JSON`, which is not something anybody works out from
the failure.

A team id already in `shipway.yaml` is **not** on the list: it appears in every
build log, so the workflow writes it plainly rather than pretending it is a
secret.

A test asserts that what `export` names is exactly the set of secrets the
generated workflow reads — in both directions. A name here the workflow never
reads is a value someone typed into GitHub for nothing; one the workflow reads
that is missing here is a build that fails at the step this was supposed to
cover.

## `shipway setup`

> Create the credentials a project needs, once, and record their names.

```
shipway setup android-signing [--alias <name>] [--keystore <path>]
                              [--password-stdin]
shipway setup ios-signing [--match-url <url>] [--branch <name>] [--create]
shipway setup firebase
```

Deliberately not part of `generate`. `generate` is idempotent and derivable —
run it twice and nothing changes, delete the output and it comes back. Setup is
neither: it creates things that cannot be recreated, so it refuses to overwrite,
says what it did, and stops.

### `android-signing`

Generates an upload keystore with `keytool`, puts its password in the login
keychain, writes `android/key.properties`, and records the *names* in
`shipway.yaml`.

| Option | Meaning |
|---|---|
| `--alias=<name>` | Key alias. Defaults to `upload`. |
| `--keystore=<path>` | Where to write it. Defaults to `android/upload-keystore.jks`. |
| `--password-stdin` | Use the password on standard input instead of generating one. |

The password is generated by default — it is typed once and read by a machine
forever after, so a memorable one buys nothing and costs entropy — and it
reaches `keytool` on **stdin**, never as `-storepass`, which would put it in
`ps` for as long as key generation takes.

Modern `keytool` writes **PKCS12**, where the store and the key share one
password. shipway uses one for both rather than writing a `key.properties` that
only appears to have two.

**An existing keystore is never overwritten**, with or without a flag. An upload
key is the only proof that an update comes from the same publisher; an app
already on Play cannot be updated without it. Back the file up somewhere that is
not the repository — the command says so on the way out.

`storeFile` in the generated `key.properties` is relative to `android/app`,
because that is where Gradle resolves it from. A path relative to the repository
root fails by silently resolving to a file that is not there, and an absolute one
works on exactly one machine.

**What it does not do:** wire Gradle up to read `key.properties`. That file is
the one that decides how your app is signed, and shipway does not edit it. If
your build does not already read it, the command says so — because a release
signed with the debug key installs, uploads, and is rejected by Play, which is a
long way to travel to find out.

Names already in `shipway.yaml` are kept rather than renamed: a team that
chose its own variable names keeps them, and the wizard fills the gap.

Off macOS there is no login keychain, so it refuses before creating anything.

## Generated fastlane lanes

`shipway generate fastlane` writes lanes you run yourself, always through
the bundle:

```
cd ios && bundle install && bundle binstubs fastlane
./bin/fastlane ios beta flavor:prod
```

**iOS** — `cd ios && bundle exec fastlane ios <lane>`

| Lane | Does |
|---|---|
| `certificates` | Syncs signing via `match`, readonly unless asked otherwise. |
| `build_ipa` | Builds and signs an `.ipa` for one flavor. |
| `beta` | `certificates` → `build_ipa` → upload to TestFlight. Takes `dry_run: true`. |

**Android** — `cd android && bundle exec fastlane android <lane>`

| Lane | Does |
|---|---|
| `build` | Builds a release artifact. `type: "appbundle"` (default) or `"apk"`. |
| `play` | `build` → `upload_to_play_store`, on the configured track. Takes `dry_run: true`. |
| `firebase` | `build` → Firebase App Distribution. Generated whenever `targets.firebase` is set. `type: "appbundle"` uploads an AAB; the default is an APK. Takes `dry_run: true`, `changelog:` and `app_id:`. |
| `promote` | Moves a build already on Play to another track. Uploads nothing. |

The Firebase lane finds its app in the flavor's `google-services.json`
(`flavors.<name>.firebase.android`), matched on the flavor's package name — one
file often lists every app in the Firebase project, so the first entry is not
the answer. `targets.firebase.android_app_id_ref` overrides that when set, and
is then authoritative: an unset variable fails rather than quietly falling back
to the file.

**Firebase App Distribution is Android-only in this version.** There is no iOS
lane, and `ios_app_id_ref` is accepted but read by nothing yet.

Every lane takes `flavor:`, and refuses with the list of valid flavors without
it. The Play lane never touches the store listing — metadata belongs to whoever
writes it, not to a build.

Every credential reaches a lane through `ENV`; nothing that could be a secret is
written into a generated file, and a test greps all fastlane output to keep it
that way.

> **Run lanes through the bundle, not through `PATH`.** `bundle exec fastlane`
> looks `fastlane` up on `PATH`, and a Homebrew fastlane ahead of your
> project's Ruby replaces the bundle entirely: the Gemfile's pins and the
> Pluginfile's plugins are not loaded, and the lane fails with
> `Could not find <gem>` or runs against the wrong gems. A binstub cannot be
> shadowed: `cd android && bundle binstubs fastlane`, then
> `./bin/fastlane android firebase flavor:dev`. `shipway release` does the
> equivalent itself, and `shipway doctor` warns when the shim is there.

## `shipway release`

> Build a flavor and send it somewhere.

```
shipway release ios     --flavor <f> --target testflight|appstore [options]
shipway release android --flavor <f> --target play|firebase       [options]
```

A front door, not a second implementation: it validates, prints the plan, then
runs the same generated lane you could run by hand.

| Option | Meaning |
|---|---|
| `-f, --flavor <name>` | Which flavor to ship. |
| `-t, --target <name>` | `testflight`, `appstore`, `play` or `firebase`. |
| `--track <name>` | Play only: override the configured track. |
| `--rollout <fraction>` | Play only: user fraction, e.g. `0.1`. |
| `--build-number <n>` | Use this instead of what `versioning.strategy` resolves. |
| `--version-name <v>` | Use this instead of `pubspec.yaml`. |
| `--dry-run` | Validate and print the plan, upload nothing. |
| `--no-notify` | Post nothing to Slack for this release. |
| `--no-analyze` | Skip analysing the flavor's entrypoint before building. |
| `--no-access-check` | Firebase only: skip asking App Distribution whether the service account can reach the app. |

Everything cheap happens first. A target the config never configured, a flag
belonging to another target, a rollout out of range, a credential that is not
set — all are caught in under a second, because finding them after a
twenty-minute build is what makes releasing feel dangerous.

```
$ shipway release android --flavor dev --target play --rollout 0.1 --dry-run

  flavor      dev
  identifier  com.acme.app.dev
  target      play
  track       internal
  rollout     0.1 → status inProgress
  version     pubspec+versioning.strategy: remote
  ruby        3.3.6  /Users/you/.rbenv/versions/3.3.6/bin/ruby
  bundler     2.6.3
  fastlane    2.238.0
  gems        /Users/you/.rbenv/versions/3.3.6/lib/ruby/gems/3.3.0

Nothing was uploaded.
```

The plan prints on a real run too, because the first question about a broken
release is always which build went where — and, for a lane that fails, which
Ruby and which fastlane it ran on.

The lane's own output then streams as it runs, each line marked with its
platform (`android │ …`), so a long build does not look like a hang and the two
lanes of a parallel pipeline stay readable. When it fails, shipway names the
lane and its exit code and says what the output meant, without printing it a
second time.

**fastlane runs from the project's bundle.** shipway runs
`bundle exec ruby -e 'load Gem.bin_path("fastlane", "fastlane")' -- <lane>` in
the platform directory, which is what a binstub does. `bundle exec fastlane`
would look `fastlane` up on `PATH`, where a Homebrew fastlane replaces the
bundle's gems and plugins. The bundle is asked what it holds before the plan,
so one that was never installed — or was installed for a different Ruby — stops
the release in a second rather than after the build.

**The credential check is scoped to the destination.** Releasing to Play does
not ask for an App Store Connect key — noise in a pre-flight is how people
learn to ignore it. It is scoped to the flavor too: shipping `dev` does not ask
for the production Firebase account.

**The lane gets what the pre-flight found.** A credential found in `.env`,
`.env.<flavor>` or the keychain is passed to the lane's environment, with paths
made absolute. The lane is a separate process: before this, the pre-flight could
report a variable present that the lane then could not see.

**A Firebase release checks who is uploading.** The plan shows the service
account's email, the variable it came from and the app's project; a service
account from a different project than the `google-services.json` is warned
about; and a read-only App Distribution call confirms the account may reach the
app. A 403 stops the release before anything is built:

```
  account     uploader@acme-dev.iam.gserviceaccount.com  from $FIREBASE_SERVICE_ACCOUNT_JSON_PATH
  access      refused

uploader@acme-dev.iam.gserviceaccount.com cannot reach 1:111:android:abc (HTTP 403).
  Grant it the Firebase App Distribution Admin role (roles/firebaseappdistro.admin)
  in project acme-app, under IAM in the Google Cloud console — or point
  FIREBASE_SERVICE_ACCOUNT_JSON_PATH at a service account from that project.
```

### Build numbers

`versioning.strategy` decides what a release claims, resolved *before* the
build so the artifact carries the number the store is told about:

| Strategy | Build number |
|---|---|
| `increment` (default) | what `pubspec.yaml` says |
| `timestamp` | `yyMMddHHmm`, monotonic without asking anything |
| `remote` | `latest_testflight_build_number + 1`, or the highest Play version code + 1 |

`--build-number` overrides all three, which is how a re-run reuses a number
rather than minting one the store has never heard of.

### Promoting on Play

Moving a build between tracks uploads nothing, so it is its own lane rather
than a flag:

```
cd android && bundle exec fastlane android promote flavor:prod to:beta rollout:0.1
```

You do not pass a release status alongside a rollout: `supply` derives one from
the fraction — `inProgress` below 1, `completed` at 1 — and passing both only
lets them disagree.

## `shipway run`

> Run a named pipeline from shipway.yaml.

```
shipway run <pipeline> [--dry-run] [--resume] [--no-notify]
```

A pipeline adds no shipping ability — every step can be run by hand. What it
owns is the seams: ordering, running iOS and Android at once, and knowing what
not to repeat after a failure.

```yaml
pipelines:
  beta:
    - analyze
    - test
    - parallel:
        - release: { flavor: prod, target: testflight }
        - release: { flavor: prod, target: play }
```

Steps are `analyze`, `test`, `build`, `release` and `run` (an arbitrary
command). Every flavor and target they name is checked before the first step
runs, with a "did you mean" when a name is close. Steps run in order; a `parallel:` block runs its steps together.
There are no inferred dependencies — the order in the file is the order of
execution, always.

```
$ shipway run beta --dry-run

Pipeline beta:
    • analyze
    • test
  ┌ • release prod → testflight
  └ • release prod → play
```

### When something fails

The pipeline stops. There is no continue-on-error: a pipeline that carries on
past a failure is one whose result means nothing. Inside a `parallel` block the
others are allowed to **finish** rather than being cancelled — killing a
half-finished upload is worse than waiting for it.

Each run writes `.shipway/runs/<pipeline>.json` (git-ignored) with every step's
status, duration and exit code. That is what `--resume` reads, and what answers
"what actually happened" once the terminal is gone.

```
$ shipway run beta --resume
```

re-runs from the first step that did not succeed. Everything before it is
skipped.

**`--resume` asks before repeating a step that may not be safe to repeat.** A
`release` that failed might have failed *after* the upload landed — a dropped
connection, a cancelled job — and shipway cannot tell. Re-running risks a
duplicate build number; skipping risks a release everyone believes shipped and
did not. So it says so, and `--yes` is how you say you have checked.

| Step | Safe to repeat |
|---|---|
| `analyze`, `test` | yes — they only read |
| `build` | yes — rebuilding overwrites the artifact |
| `release` | **no** |
| `run` | **unknown** — shipway has no idea what your command does |

See [`pipelines.md`](pipelines.md).

## `shipway notify`

> Send a test Slack message.

```
shipway notify test [--event started|success|failure] [--dry-run]
```

Sends one sample message through whatever `notify` in `shipway.yaml` sets up,
so a revoked webhook or a typo in a message shows up now instead of after a
release. The sample uses the config's first pipeline and is marked `(test)`,
because a red "failed" in a release channel scares people even when it is fake.

`--event` defaults to the first event in `notify.on`. `--dry-run` prints the
JSON Slack would receive and sends nothing, which is the quick way to work on
your message text.

`release` and `run` post on their own when `notify` is configured. A pipeline
sends one report for the whole run, not one for each release step inside it.
See [`config-schema.md`](config-schema.md#notify--telling-a-channel-how-a-release-went).

## Continuous integration

`shipway generate ci` writes `.github/workflows/release.yml` — created once,
then yours. It calls the same lanes you run locally, so green there and green
here mean the same thing.

What it handles that a hand-written workflow usually forgets:

- **Match repository access.** A runner has no SSH agent and no credential
  helper, so a private certificates repo needs an explicit credential. shipway
  picks `MATCH_GIT_PRIVATE_KEY` or `MATCH_GIT_BASIC_AUTHORIZATION` from the URL
  scheme in your config — match treats them as mutually exclusive and silently
  ignores the wrong one.
- **The Android keystore.** A checkout has neither the keystore (binary,
  git-ignored) nor `key.properties` (passwords). The workflow rebuilds both from
  secrets, with an absolute `storeFile` because Gradle resolves it relative to
  `android/app`.
- **Path-valued service accounts.** Play and Firebase want a *file*, so the
  workflow writes one before the lane runs.
- **`secrets check` as the first step**, so a missing variable fails in seconds.
- **Installing shipway itself**, pinned to the tag matching the version that
  generated the workflow. A job that installs whatever the default branch holds
  can break on a morning nobody touched the repository, and the failure arrives
  looking like the app's. Generated by a `-dev` build, it says so and tracks the
  branch rather than naming a tag that does not resolve. A beta is tagged, so
  it pins like a release.

A test asserts the workflow provides everything the pre-flight requires — a
workflow whose own check step fails is worse than none, since it looks
configured and refuses to run.

Supported CI target is **GitHub-hosted runners**. Self-hosted runners are
detected correctly but not yet supported; see
[`execution-environments.md`](execution-environments.md).

## Not built yet

Planned, and deliberately absent rather than half-present:

| Command | Phase |
|---|---|
| `shipway upgrade`, `shipway completion install` | 6 |

The generated lanes stop at TestFlight, the Play internal track and Firebase
App Distribution. Promotion between tracks, App Store submission and staged
rollout management are Phase 4.

## See also

- [`config-schema.md`](config-schema.md) — every `shipway.yaml` field.
- [`ios-build-division.md`](ios-build-division.md) — who builds the iOS archive,
  and why gym must not.
- [`execution-environments.md`](execution-environments.md) — how Phase 3 is
  designed to run on a laptop, a hosted runner and a self-hosted Mac alike.
- [`orphan-cleanup.md`](orphan-cleanup.md) — how files the config no longer
  describes are removed without deleting anybody's work.
- [`notifications.md`](notifications.md) — why Slack has two transports, and why
  a failure is broadcast when a success is not.
- [`deviations.md`](deviations.md) — where the built thing differs from the plan,
  and why.
- [`troubleshooting.md`](troubleshooting.md) — failures seen in the field, how
  to recognise them, and what fixes them.
