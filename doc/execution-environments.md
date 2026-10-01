# Design: making Phase 3 work off the laptop

## The problem

Phase 3 is the secrets and signing wizard. As planned it assumes one
environment: a developer sitting at an unlocked macOS laptop, able to answer a
prompt and with a login keychain the OS has already unlocked for them.

That assumption is baked into every part of it — the resolution chain ends in
`prompt`, signing material goes into the login keychain, and `match` is invoked
as if a human is watching. None of that survives contact with a build machine.

Four environments matter, and they differ in ways that change the design rather
than just the configuration:

| | Interactive | Keychain | Secrets from | Lifetime |
|---|---|---|---|---|
| **Workstation** (dev laptop) | yes | login, already unlocked | keychain, `.env`, prompt | permanent |
| **Ephemeral CI** (GitHub-hosted runner) | no | none; fresh VM | injected env vars | minutes |
| **Persistent runner** (Mac mini M2, self-hosted) | no | **may not be unlocked at all** | env vars, `.env` | months, shared |
| **Linux VPS** | no | none | env vars | months |

The persistent Mac mini is the hard one, and it is also the one most teams
actually reach for — it is the cheapest way to get a real iOS builder. Two
things make it painful, and both have bitten this project already:

- **After a reboot with no GUI login, the login keychain is not unlocked.**
  Anything that depends on it works over SSH right up until the machine
  restarts, then fails in a way that looks like a signing problem.
- **A private key with no partition list refuses to sign non-interactively.**
  This is the `errSecInternalComponent` hit during the Phase 2 spike: the
  keychain was unlocked, the identity was valid, and `codesign` still failed
  because nothing had granted a headless process permission to use that key.

And the standard remedy makes the persistent case worse. `setup_ci` creates a
temporary keychain, makes it the **default**, and does not reliably clean up —
which on a shared, long-lived machine leaves a lingering default keychain
pointing at a directory that no longer exists.

## The core abstraction

One value, resolved once per run, that every other decision keys off:

```dart
enum RunEnvironment { workstation, ephemeralCi, persistentRunner }
```

Resolution order, most explicit first:

1. `--env` flag
2. `SHIPWAY_ENV` environment variable
3. `ci.environment` in `shipway.yaml`
4. detection

Detection is a *convenience*, never the only path, because getting it wrong is
expensive in both directions — prompting on a runner hangs the job, and
creating throwaway keychains on a laptop is rude. The explicit override is the
supported answer for anything unusual.

Detection uses, in order: `CI` / `GITHUB_ACTIONS` to decide it is not a
workstation, then `RUNNER_ENVIRONMENT` (`github-hosted` vs `self-hosted`) to
choose between ephemeral and persistent. **That last variable is documented by
GitHub but has not been verified here** — no runner was available — so the
implementation must treat an unrecognised value as `persistentRunner`, which is
the conservative choice: it cleans up after itself and never assumes a fresh
machine.

On Linux the answer is never `workstation` for iOS purposes, because there are
no iOS purposes.

## Secret resolution, per environment

The plan's chain is `flag → env → .env.<flavor> → keychain → prompt`. That is
right for a workstation and wrong everywhere else. The chain becomes a property
of the environment:

| Environment | Chain |
|---|---|
| Workstation | flag → env → `.env.<flavor>` → keychain → **prompt** |
| Ephemeral CI | flag → env → **fail, naming what is missing** |
| Persistent runner | flag → env → `.env.<flavor>` → dedicated keychain → **fail** |
| Linux VPS | flag → env → `.env.<flavor>` → **fail** |

Two rules hold everywhere:

- **Prompting happens only on a workstation.** Anywhere else a prompt is a hang,
  which is strictly worse than a failure, because a hung job burns the timeout
  and reports nothing useful.
- **Failure names the missing variable.** `MATCH_PASSWORD is not set` is
  actionable; `could not decrypt` is a support ticket.

On a persistent runner the login keychain is deliberately **not** in the chain.
It may not be unlocked, and depending on it is what makes self-hosted macOS
builders fragile after a reboot.

## Keychain strategy

Validated on this machine end to end, including teardown.

| Environment | Strategy |
|---|---|
| Workstation | Use the login keychain. Create nothing. This is what a developer expects, and what Xcode will show them. |
| Ephemeral CI | Create a run-scoped keychain, use it, let the VM evaporate. Clean up anyway — it costs nothing and makes the code path identical to the persistent one. |
| Persistent runner | Create a **named** keychain, add it to the search list, never touch the default, and remove it again afterwards. |

The sequence, which was run against this machine and left `default-keychain` and
`list-keychains` byte-identical to how it found them:

```sh
security create-keychain -p "$PW" shipway.keychain-db
security set-keychain-settings -lut 3600 shipway.keychain-db   # no auto-lock mid-build
security unlock-keychain -p "$PW" shipway.keychain-db

# Append to the search list. Note the default is NOT changed — this is exactly
# what `setup_ci` gets wrong, and why it pollutes a shared machine.
security list-keychains -d user -s $(security list-keychains -d user) shipway.keychain-db

# ... import identities ...

# The step that prevents errSecInternalComponent. Without it a headless
# codesign fails even though the keychain is unlocked and the identity valid.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" shipway.keychain-db

# Teardown restores the search list, then deletes.
security list-keychains -d user -s <the original list>
security delete-keychain shipway.keychain-db
```

Three properties this must guarantee:

- **The default keychain is never changed.** Verified.
- **Teardown runs even on failure**, including on `SIGINT`/`SIGTERM`. A build
  cancelled from the GitHub UI must not leave a keychain behind.
- **Two runs cannot share one.** `.shipway/run.lock` guards it; keychains and
  build directories are not safe to share, and a Mac mini will be asked to.

`doctor` already warns about a leftover `shipway.keychain` in the search list,
which is the symptom of a crashed run. That check becomes load-bearing here.

## Non-interactivity as a mode, not a flag

`--yes` exists, but "assume yes" is not the same as "never ask". Outside a
workstation the wizard must have a complete non-interactive path, which means
every question it would ask needs an answer available from config or
environment. Where one is not available it must fail *before* doing any work,
not halfway through.

This is what the pre-flight below is for.

## What makes this easy rather than merely possible

The leverage is that **`shipway.yaml` already names every secret**. Every
`*_ref` field is the name of an environment variable, and nothing else in the
file is a credential. So one source of truth can drive:

### `shipway secrets check`

The pre-flight. Resolves every `*_ref` the config references and reports which
are missing, exiting non-zero if any are. Run as the first step of a CI job it
turns a twenty-minute build that fails at the upload into a five-second failure
that names `ASC_KEY_P8_BASE64`.

### `shipway secrets list`

What the config needs, where each one resolves from, and whether it is present.
**Never prints a value** — presence and source only.

### `shipway secrets export --format github|env|shell`

Emits the *names* — a `gh secret set` script, or an Actions `env:` block — so
wiring up a repository is mechanical rather than archaeological.

### `shipway generate ci`

A working `.github/workflows/release.yml` with the `env:` block generated from
the config's `*_ref` fields. Each job runs `shipway release`, not fastlane, so
the pre-flight, the failure summary and everything under "What `shipway
release` does on a build machine" below apply in CI as they do locally — and
fastlane is still loaded through the bundle rather than found on `PATH`,
because a Homebrew fastlane on a self-hosted runner overrides `GEM_HOME` and
silently uses the wrong gems, which Phase 2 already ran into.

`ci.runner` in `shipway.yaml` picks one of two shapes:

| | `hosted` (default) | `self-hosted` |
|---|---|---|
| `runs-on` | `macos-15`, `ubuntu-latest` | `[self-hosted, macOS]`, `[self-hosted]` — edit to your labels |
| Toolchain | `flutter-action`, `setup-ruby` (Ruby 3.3), `setup-java` | none: the machine has its own |
| Caches | `cache: true`, `bundler-cache: true` | none |
| Gems | installed by `bundler-cache` | `shipway release` runs `bundle install` when `bundle check` fails |
| Tells shipway | `--env ci` | `--env persistent` |
| `known_hosts` for an SSH match repo | appended by a step | trusted once, by hand, on the runner |
| Last step | — | `shipway cleanup`, under `if: always()` |

Both have `ios` and `android` boolean inputs, on by default, each gating its
job — so an Android fix does not cost an iOS build. Both check credentials per
platform (`shipway secrets check --platform ios`), so a job is not failed for a
secret only the other one needs.

The hosted assumptions are each harmless on a machine that is destroyed and a
leftover on one that is not: a tool cache that fills the disk, an
`ios/.bundle/config` pointing every later `bundle` at `vendor/bundle`, a
`known_hosts` that grows by a line per job. A team that moved the hosted
workflow to a self-hosted Mac undid them by hand, one failed run at a time.
That is what the second shape is for.

`ci.runner` is deliberately not `ci.environment`. The latter is read by every
machine that loads the config, a laptop included; the former only chooses a
workflow, and the workflow then passes `--env`.

### What `shipway release` does on a build machine

Off the workstation — `ci` and `persistent` alike, so the persistent path is
exercised by every hosted run — `shipway release` does what the workflow used
to do in YAML, and undoes it:

1. **Credential files.** A service account and a keystore are files on a
   laptop and repository secrets on a runner. Each path-valued variable the
   release needs (`PLAY_SERVICE_ACCOUNT_JSON_PATH`, a flavor's Firebase
   account) is written from the secret holding its content
   (`PLAY_SERVICE_ACCOUNT_JSON`) into a directory made for the run, and the
   lane is pointed at it. For Android the keystore is decoded from
   `keystore_ref` and `android/key.properties` is built from the two password
   variables. The directory is under `RUNNER_TEMP` when the runner provides
   one, otherwise the system's temporary directory — never the checkout.
2. **Gems.** `bundle check` in the platform directory, then `bundle install`
   only when that fails.
3. **Gradle** (Android). See below.
4. **Removal.** Everything from step 1 is deleted when the command returns,
   whichever way it returns, and on `SIGINT`/`SIGTERM`, which is what a job
   cancelled from the GitHub UI receives.

Three things are left alone on purpose. A path variable that already names a
real file is not shadowed: a self-hosted machine may keep its service account
on disk. A `key.properties` that shipway did not write is never replaced or
removed: the one it writes begins with a marker line, and that is how the two
are told apart. And nothing is done on a workstation at all.

`shipway cleanup` removes the same files for a run that was killed too hard to
do it itself. It removes only run directories named for this checkout and a
`key.properties` carrying the marker, so two runners sharing a machine cannot
clean up each other's releases, and it succeeds when there is nothing to do.

`shipway secrets check` agrees with all this: off the workstation a path-valued
requirement is satisfied by its content secret, since that is what will be
turned into the file.

### Gradle limits

A project's `gradle.properties` commonly asks for an 8 GB heap — a number
chosen on a laptop. On a 16 GB runner the operating system kills the build and
the only report is exit 143. Off the workstation, an Android release sets
`GRADLE_OPTS` in the lane's environment:

```
-Dorg.gradle.jvmargs="-Xmx4096m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8"
-Dorg.gradle.workers.max=4
-Dorg.gradle.daemon=false
```

| Machine | Heap | Workers |
|---|---|---|
| unknown | 2 GB | 2 |
| 4–8 GB | 2 GB | 1–2 |
| 16 GB | 4 GB | 4 |
| 32 GB or more | 8 GB | 4 |

The heap is a quarter of physical memory, in whole gigabytes, between 2 and 8;
workers are one per 4 GB, at most four. Memory is read with
`sysctl -n hw.memsize` on macOS and from `/proc/meminfo` on Linux.

Nothing is written to `~/.gradle`. On a self-hosted runner that directory is
every project's, and a heap chosen for this one would become everybody's.
Whatever `GRADLE_OPTS` already holds is kept and placed last, so a value set on
the runner deliberately still wins.

**Verified** on this machine against Gradle 8.14 (JDK 18), with a project whose
`gradle.properties` asks for `-Xmx8G -XX:MaxMetaspaceSize=4G` and
`org.gradle.daemon=true`:

- The string above produced a build JVM reporting a 4096 MB heap, a 1024 MB
  metaspace and 4 workers, in a single-use process that exited with the build.
  So a `-D` property in `GRADLE_OPTS` outranks the project's `gradle.properties`
  for `org.gradle.jvmargs`, `org.gradle.workers.max` and `org.gradle.daemon`.
- A bare `-Xmx2g` in `GRADLE_OPTS` did **not**: the build JVM still had 8192 MB.
  It sizes the small client JVM only, which is why the limit has to go through
  `org.gradle.jvmargs`.
- With `-Dorg.gradle.workers.max` given twice, the later one was used.

**Not verified:** the same variable arriving through `flutter build` and a
project's own `gradlew` rather than the distribution's launcher script; older
wrapper scripts, which parse the quotes differently; the Kotlin daemon, which
inherits Gradle's arguments unless `kotlin.daemon.jvmargs` says otherwise; and
whether these sizes are enough for any particular app. `org.gradle.jvmargs`
replaces the project's value rather than adding to it, so other flags the
project put there are not passed.

### `shipway doctor --env <name>`

Runs the checks that matter for a *target* environment rather than the current
one, so a Mac mini can be validated as a builder before anything is wired to it.
On Linux the iOS checks skip with a reason rather than failing, and the ones
that would have shelled out to `xcodebuild` or `security` are not run at all —
a skip that still spends the time and can still fail is a skip in the report
only.

## New classifier signatures

Environment-specific failures found while validating this design, plus the ones
the environments make likely:

| Signature | Means |
|---|---|
| `MAC verification failed during PKCS12 import` | A `.p12` made by OpenSSL 3, which macOS `security` cannot read. Re-export with `-legacy -macalg sha1`. Hit while building this design. |
| `User interaction is not allowed` | Keychain locked, or the key has no partition list. The headless-signing failure. |
| `errSecInternalComponent` | Already catalogued; now with the environment context that makes it actionable. |
| `security: SecKeychainDelete` … `could not be found` | Teardown running against a keychain a previous crashed run already removed. Must not fail the build. |
| `Could not create another Certificate` | Apple's certificate limit reached — the classic symptom of a runner minting a new certificate every build instead of using `match` in readonly mode. |

## Current support

| Environment | Status |
|---|---|
| **Workstation** | Supported. Login keychain, prompts allowed, nothing created. |
| **Ephemeral CI** (GitHub-hosted) | Supported. Generated workflow, pre-flight, keychain session. |
| **Persistent runner** | **Built, not proven.** `ci.runner: self-hosted` generates a workflow with no setup actions and no caches; `shipway release` installs gems, writes and removes credential files and limits Gradle; `shipway cleanup` covers a killed run. All of it is unit-tested and none of it has run on a real self-hosted machine. |
| **Linux VPS** | Android only, and it says so. Every Apple check skips with a reason rather than failing, `shipway build ios` refuses and names `build android`, the keychain is not offered as a place a secret could be, and `doctor` reports "Ready to ship Android" rather than implying more. Not validated against a real Linux builder end to end. |

Detection still resolves `persistentRunner` — misclassifying a self-hosted
runner as disposable would be worse than naming it. What remains before that
row can say "supported" is evidence rather than code: teardown observed against
a job cancelled from the GitHub UI, the Gradle limits observed through
`flutter build` on a runner that was previously killed, and the run lock
exercised under real concurrency.

## Order of work

Sequenced so each step is independently useful, rather than one XL landing:

1. **`RunEnvironment` + environment-aware secret resolution.** Everything else
   depends on it, and it is what makes the rest testable without a runner.
2. **`shipway secrets list` / `check`.** Immediately useful on a laptop, and the
   thing that makes CI failures cheap.
3. **The keychain manager**, with guaranteed teardown and the run lock.
4. **`shipway setup ios-signing` / `android-signing`**, the wizard proper — by
   which point it is filling in a model that already works headlessly.
5. **`shipway generate ci`** and `secrets export`. *Done.* `export` derives its
   list for `ci` whatever machine it runs on, and a test asserts it names
   exactly the secrets the generated workflow reads.
6. **Linux/Android-only support** in `doctor` and `build`. *Done.* The host OS
   is a value (`HostPlatform`) threaded through `RunContext`, so the Linux
   answer is testable from a Mac — which is the only place it was ever going to
   be tested.

## What this deliberately does not do

- **No hosted secret backends.** No Vault, no AWS Secrets Manager, no 1Password.
  The `*_ref` indirection means someone can wire one up by exporting variables
  before invoking shipway, which is the integration point that already exists
  and does not need code.
- **No CI providers beyond GitHub Actions initially.** The generated workflow is
  a convenience; the lanes are the product, and they run anywhere. GitLab and
  Bitbucket templates are cheap to add later precisely because nothing else
  depends on them.
- **No Windows.** Android-only builds would work, but nothing here has been
  tested there and claiming support without evidence is worse than not claiming
  it.
- **No attempt to unlock the login keychain on a headless Mac.** The design
  routes around it rather than trying to defeat it, because a tool that
  automates unlocking a user's personal keychain on a shared machine is a
  liability, not a feature.
