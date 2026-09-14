# Design: Phase 4, the deployment targets

Shipping to TestFlight, the App Store, Google Play and Firebase App
Distribution — and choosing the build number that goes with each.

Researched against the pinned toolchain (fastlane 2.238.0, `supply`,
`deliver`, `pilot`, `firebase_app_distribution` 0.10.x) by reading the gems
rather than the documentation, because three of the findings below contradict
what the plan assumed.

## What the research changed

### 1. `supply` sets the release status itself — shipway was wrong to refuse

The plan, the config schema and a comment in `shipway_config.dart` all say a
staged `rollout` requires `release_status: inProgress`, and that "supply rejects
the combination otherwise". **That is false**, and `config_loader.dart` rejects
a config that would work.

`supply` corrects the pair on both code paths it can take:

```ruby
# uploader.rb, update_track — the upload path
if rollout > 0 && rollout < 1
  track_release.status = Supply::ReleaseStatus::IN_PROGRESS
  track_release.user_fraction = rollout

# uploader.rb, update_rollout — the promote path
status = IN_PROGRESS if status == COMPLETED && rollout.to_f < 1
status = COMPLETED   if status == IN_PROGRESS && rollout.to_f == 1
```

So `rollout: 0.1` with the default status is valid and does the obvious thing,
and `release_status: inProgress` with `rollout: 1` completes the rollout rather
than failing.

**Decision:** stop rejecting it. Keep the range check — `(0, 1]`, which mirrors
supply's own `verify_block` exactly — and *derive* the effective status the way
supply does, so `--dry-run` can show what will actually happen. Refusing a
working config is a worse failure than an unclear one.

### 2. `distribute_external` requires `groups`, and nothing checks it

`pilot`'s own description: *"If set to true, use of `groups` option is
required"*. A config with `distribute_external: true` and no `groups` uploads
the build, then fails at the distribution step — after the slowest part.

**Decision:** a pre-flight rejects it before the build starts.

### 3. Remote build numbers need no plugin

The plan's actions both exist in core fastlane:
`latest_testflight_build_number` and `google_play_track_version_codes`. No extra
gem to pin, which matters because every pin is another thing that can stop being
satisfiable on the Ruby floor.

`google_play_track_version_codes` returns a **list of integers**. The plan says
`[0] + 1`; this uses `.max + 1`, because the API does not promise an order and
picking the wrong element produces a version code Play rejects as non-increasing
— the exact failure the classifier already has an entry for.

## Where a version is decided

Two contexts need a build number and they cannot share one implementation:

| Context | Decided by | Why |
|---|---|---|
| `shipway build` | pubspec, or `--build-number` | No credentials, no network, and no store to ask. |
| a release lane | the generated Ruby | `remote` means asking App Store Connect or Play, which only fastlane can do. |

So `VersionResolver` **renders Ruby** rather than computing a number in Dart.
One implementation, in the place that can actually reach a store — a Dart copy
would be a second answer that drifts, and the failure when two answers disagree
is a duplicate build number nobody can explain.

The three strategies:

| `versioning.strategy` | Build number |
|---|---|
| `increment` (default) | what `pubspec.yaml` says |
| `timestamp` | `yyMMddHHmm` — monotonic without asking anything |
| `remote` | `latest_testflight_build_number + 1`; for Play, the highest version code on any standard track + 1; for Firebase, the app's latest App Distribution release + 1 |

`sync_ios_android` keeps `CFBundleVersion` equal to `versionCode` by resolving
once per release rather than once per platform.

## Command surface

```
shipway release ios     --flavor <f> --target testflight|appstore [options]
shipway release android --flavor <f> --target play|firebase       [options]
```

It is a *front door*, not a second implementation: it validates, shows the plan,
then runs the same generated lane a person could run by hand. Nothing it does is
unavailable to someone who prefers `bundle exec fastlane`.

The order matters for the experience:

1. **Resolve** the target from the config, and refuse clearly when it is not
   configured — naming the `shipway.yaml` key that would configure it.
2. **Pre-flight**: every credential the target needs, plus the target's own
   rules (`distribute_external` without `groups`; `rollout` out of range). All
   before anything slow.
3. **Plan**: what is going where, with which version and status. `--dry-run`
   stops here, and the plan is printed either way so a failure is legible
   afterwards.
4. **Run** the lane, streaming output.
5. **Classify** the failure, successes included — a store upload can "succeed"
   and still be rejected in processing.

## Error handling

The rule from Phase 2 holds: **failure names the thing to change.** A store's
own errors are unusually bad at this — `The provided entity includes an
attribute with a value that has already been used` is a duplicate build number —
so every one that has a known cause gets a classifier entry with the config key
or command that fixes it.

New signatures, from reading the gems and the stores' documented errors:

| Signature | Means |
|---|---|
| `Version code has already been used` | Play rejects a non-increasing version code. Already catalogued; now with `versioning.strategy: remote` as the fix. |
| `has already been used` + `entity` | Duplicate `CFBundleVersion` on App Store Connect. |
| `distribute_external` + `groups` | External distribution with no group to distribute to. Caught by pre-flight, kept for the hand-run case. |
| `Google Api Error: applicationNotFound` | The package name is not on Play, or the service account cannot see it. |
| `is not a valid track` | A track name Play does not know. |
| `Cannot rollout a release with status` | A rollout on a status that cannot take one. |
| `App Store Connect API key` + `403` / `401` | The key is wrong, expired, or lacks the role. |

## What this does not do

- **No live upload is verified here.** This machine has no distribution
  certificate, no App Store Connect key and no Play service account, so the
  lanes are verified by construction and by running them to the point where
  they ask for credentials. That boundary is stated rather than implied, the
  same way `setup ios-signing --create` states it.
- **No metadata management.** `deliver` can upload screenshots, descriptions and
  release notes; shipway sets `skip_metadata` and `skip_screenshots` unless a
  `metadata_path` is configured. Store listings belong to whoever writes them,
  not to a build.
- **No automatic submission for review.** `submit_for_review` defaults to false
  and stays there unless the config says otherwise. Submitting is not something
  a tool should do because it could.
