# Deviations from the implementation plan

Each entry records a place where the built thing differs from
`doc/research.md` and the Phases 0–3 plan, and why. Kept so a reader of the
plan is not surprised by the code, and so a deviation is a decision rather than
a drift.

## Dart SDK floor is 3.8, not 3.6

The plan sets Dart ≥ 3.6 and separately pins `json_serializable` 6.14.1. Those
are inconsistent: 6.14.1 requires SDK `^3.8.0`. Taking the pinned dependency
versions, the package declares `sdk: ^3.8.0` and `doctor`'s Dart check uses the
same floor, in one place.

The alternative — an older `json_serializable` — would have meant unpinning a
version the plan states explicitly.

## The Gradle init script is Groovy, not Kotlin DSL

The plan names `tool/gradle/shipway_dump.gradle.kts`. It is
`tool/gradle/shipway_dump.gradle`, written in Groovy.

The script reads AGP's `android` extension **reflectively**, after the project
has been evaluated. Groovy's dynamic property access does this with no AGP types
on its own classpath, so one script works identically against a Kotlin-DSL or a
Groovy-DSL build. A Kotlin init script would need compile-time types it cannot
have — it would have to declare a dependency on AGP, pinned to a version, and
would then break on projects using a different one.

## `--deep` does not pass `--offline`

An early version did, reasoning that a read should not touch the network. That
was wrong: a Flutter Android build resolves the Kotlin and Flutter Gradle
plugins from the network, and `--offline` turns a working project into a failed
deep read for anyone without a fully warm cache. Verified against a real
project, where it failed to resolve `org.jetbrains.kotlin.jvm`.

`--no-daemon` is still passed: a read must not leave a daemon running against a
project it only meant to look at.

## The dependency-direction test encodes a DAG, not a chain

The plan states the direction as
`cli → core → {inspect, generators} → platform → secrets`. Read literally as
"each layer may only import to its right", that is not satisfiable — every
reader needs `core`'s `ProcessRunner` and `ProjectModel`.

`test/unit/architecture/dependency_direction_test.dart` encodes the DAG the
arrow describes instead: `core` is the shared base that imports nothing
internal, `cli` is the outermost layer, and each layer in between names exactly
what it may import. The plan's one hard rule — nothing in `core` imports `cli` —
is asserted separately.

## Config fields added beyond the plan's schema

Four, each forced by a real project failing the import-fidelity gate. They are
documented with their reasons in [`config-schema.md`](config-schema.md).

## `doctor` gained a Gradle wrapper check

Not in the plan's check table. Added because a real project failed to build and
to deep-read for exactly this reason: its wrapper was Gradle 8.12 against
Flutter's 8.14 minimum. Flutter's own error names a Gradle version and nothing a
user would think to search for, and the same condition silently disables
`shipway import --deep`.

The floor lives in `platform_deadlines.dart` with the other facts about the
world that go stale, so it carries a `lastVerified` date like the rest.

## No per-flavor `ios/Flutter/<flavor>.xcconfig` is generated

The plan's artifact inventory lists one, and shipway wrote one and attached it
to each `<BuildType>-<flavor>` configuration as its base configuration. That is
wrong, and the way it is wrong is silent.

A build configuration has exactly one base configuration. Attaching shipway's
displaces the stock `ios/Flutter/Debug.xcconfig` / `Release.xcconfig`, and those
are the files that `#include "Generated.xcconfig"` — the file `flutter build`
writes, carrying `FLUTTER_TARGET`, `DART_DEFINES`, `FLUTTER_BUILD_NAME` and
`FLUTTER_BUILD_NUMBER`. A flavored build therefore:

- compiled `lib/main.dart` no matter what `-t` said, so `main_<flavor>.dart` was
  generated and then ignored — the wrong app under the right bundle id;
- dropped every `--dart-define`;
- produced an `Info.plist` with **no** `CFBundleShortVersionString` and no
  `CFBundleVersion`, because Xcode drops a key whose value expands to empty.
  App Store Connect rejects that upload.

None of it is visible in a build log: `flutter build ipa` prints
`Version Number: Missing` in its App Settings Validation block and exits 0.

In a CocoaPods project the same displacement also drops the
`#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.<config>.xcconfig"`
line, along with anything the project itself keeps in those files.

So flavor configurations now inherit the base configuration of the build type
they derive from, which is what a hand-made flavor setup does — verified against
a real two-flavor project, where `Release-development` points at the stock
`Release.xcconfig` and every per-flavor value lives in the configuration's own
`buildSettings`. shipway does the same: bundle id, `APP_DISPLAY_NAME` and
`DEVELOPMENT_TEAM` are written onto the configuration, which is also where they
have to be for a target's own settings to win.

The inherited reference is read from the project rather than assumed, so a
project that points `Profile` somewhere other than `Release.xcconfig` keeps
doing so.

Projects generated by the earlier behaviour are repaired in place: the bridge
re-asserts the inherited base configuration on every run, and
`LegacyXcconfigCleanup` deletes the orphaned `<flavor>.xcconfig` — but only when
shipway wrote it and it is still byte-for-byte what shipway wrote. One that has
been edited is left alone and reported, because deleting somebody's build
settings is worse than leaving a file nothing references.

## The error classifier is seeded from reproduced failures, not only the catalog

The plan supplies an error-classifier table. Roughly half of it is reproduced in
`classifier.dart` unchanged; the rest of the entries were added because the
Phase 2 spike hit them, and two of the plan's own entries turned out to be
wrong or incomplete for a current Flutter.

Each signature is marked `verified` or `catalog` in the source, so a reader can
tell which ones have been seen fail and which are taken on trust.

The notable additions:

| Signature | Why it is not in the plan |
|---|---|
| `Could not resolve package dependencies` + `Flutter/ephemeral` | The modern form of "fastlane archived a Flutter app". Since Flutter resolves through Swift Package Manager, this fails long before the plan's `exportArchive` message, which no longer appears. |
| `exportArchive No Team Found in Archive` | Only happens under the `gym` export shape, because a `--no-codesign` archive records an empty `Team`. |
| `Ambiguous choice. Please choose one of` | Not an error: gym prompting for a scheme, which makes a non-interactive run hang forever rather than fail. Costly precisely because nothing is reported. |
| `errSecInternalComponent` | A per-key keychain ACL. The message names nothing searchable, and it is what a developer hits the first time they build from a script rather than from Xcode. |
| `Could not find <gem> in locally installed gems` | A Homebrew fastlane displacing bundler's `GEM_HOME`. Reads like a corrupt bundle, so people reinstall gems instead of fixing the shim. |
| `version solving has failed` | Pins that are not mutually satisfiable on the running Ruby. `bundle install` does not degrade here; it installs nothing. |
| `Version Number: Missing` | Not a failure at all — `flutter build` exits zero. It is the only outward sign of the flavored-xcconfig defect, and App Store Connect rejects the resulting upload. |

That last one is why `shipway build` classifies the output of *successful*
builds as well as failed ones. An exit code of zero is not evidence that the
artifact can be shipped.

## `bundle exec fastlane` is not sufficient on its own

The plan's rule — always `bundle exec fastlane`, never bare — is right and is
what the generated Gemfile says. It is also not enough.

Homebrew installs `fastlane` as a bash script that sets `GEM_HOME` and
`GEM_PATH` to its own directories and prepends its own Ruby to `PATH` before
exec'ing the real binary. It therefore discards everything bundler arranged, and
`bundle exec fastlane` runs a different fastlane against a different gem set.
The symptom is `Could not find <gem> in locally installed gems`, which looks
like a broken bundle rather than a hijacked one.

`doctor` now reads the `fastlane` on `PATH` and warns when it is a wrapper of
this shape, recommending a binstub — `bundle binstubs fastlane`, then
`./bin/fastlane` — which cannot be shadowed. Reproduced on this machine.

A warning turned out not to be enough either: a field report hit exactly this
through `shipway release`, and had to put the project's Ruby first on `PATH` by
hand. So `shipway release` no longer runs `bundle exec fastlane` at all. It runs
`bundle exec ruby -e 'load Gem.bin_path("fastlane", "fastlane")' -- <lane>`,
which is what a binstub does, without writing one into the project. Before the
plan it asks the same bundle which Ruby, Bundler and fastlane it holds, prints
them, and stops when the bundle is not installed — in a second, rather than
after a release build. Verified with the Homebrew shim first on `PATH`: the old
command crashed inside Homebrew's Ruby 3.4, the new one ran a real lane on the
bundled fastlane 2.238.0 with its options intact.

`doctor` also recognises Homebrew by where the executable resolves to, not only
by the wrapper's contents, which a formula can change.

## No `Gymfile` is generated

The plan's artifact inventory lists one. shipway does not write it.

Every gym option shipway sets is either per-flavor — the scheme, the
provisioning-profile mapping — or load-bearing in a way that must be visible at
the call site: `skip_build_archive: true` is the single flag separating a
working export from the arrangement that fails, and `export_team_id` is what
stops a `--no-codesign` archive failing with `No Team Found in Archive`.

A `Gymfile` supplies defaults at lower precedence than the lane, so it cannot
break a correct lane. What it does do is give a reader a second place to look
before they can be sure what a build did, for settings that are all either
per-flavor or too important to be a default. Under `ios.export: flutter` gym is
not used at all, so a Gymfile would describe a tool the project never invokes.

## The `.ipa` filename follows `CFBundleName`, not the display name

Recorded because the first measurement was ambiguous and the wrong conclusion
was briefly written down. A real project exported `Lahent Dev.ipa` and set both
`CFBundleName` and `CFBundleDisplayName` from the same build setting, so it
could not distinguish them. A project where they differ settles it:
`CFBundleName = e2eapp` with `CFBundleDisplayName = E2E Staging` exports
`e2eapp.ipa`.

The consequence is sharper than the trivia. shipway varies only
`CFBundleDisplayName` per flavor, so **every flavor of a shipway project exports
to the same filename**, overwriting the previous one in `build/ios/ipa/`. A lane
that globbed and took any match would upload the last flavor built rather than
the one it just built. The generated lanes therefore accept only an `.ipa`
written after their own build began, and fail loudly when the export produced
nothing.


## A staged Play rollout no longer requires `release_status: inProgress`

The plan, this schema and a comment in `shipway_config.dart` all stated that a
`rollout` requires `release_status: inProgress`, and that `supply` rejects the
pair otherwise. Reading `supply`'s uploader shows the opposite: it derives the
status from the user fraction on **both** paths it can take, setting
`inProgress` when the fraction is below 1 and `completed` at 1.

shipway was therefore refusing a config that ships. The range check stays —
`(0, 1]`, which mirrors supply's own `verify_block` — and the effective status
is shown by `shipway release --dry-run` rather than demanded up front.

Recorded because the wrong version was asserted in three places, and somebody
reading the plan will meet it again.

## The project is called shipway

Renamed from `taxiway` on 2026-09-11, which was itself renamed from the working
name `shipyard` on 2026-09-08. The first rename was forced — `shipyard` is taken
on pub.dev. The second was a preference: both `shipway` and `taxiway` were free
when it was made.

The rename changes several things that are **on-disk contracts**, not just
identifiers:

| Was | Is |
|---|---|
| `taxiway.yaml` | `shipway.yaml` |
| `.taxiway/` | `.shipway/` |
| `BEGIN taxiway (managed)` | `BEGIN shipway (managed)` |
| `TAXIWAY_ENV`, `TAXIWAY_KEYCHAIN_PASSWORD` | `SHIPWAY_ENV`, `SHIPWAY_KEYCHAIN_PASSWORD` |
| keychain service `taxiway` | keychain service `shipway` |

There is **no migration**, and that is deliberate rather than an omission: the
package is `0.1.0-dev` and has never been published, so nothing exists to
migrate. A project that was set up under the old name is re-adopted by renaming
its config and running `shipway generate`, which is less code than a migration
path nobody would exercise.

A secret stored in the login keychain under the old service name is the one
thing a rename does not reach. `shipway secrets list` reports it missing rather
than finding it, which is the correct answer — it is a different service.
