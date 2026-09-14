# Troubleshooting

Failures seen in the field, how to recognise them, and what fixes them. Most of
them come from one field report of an app shipping two flavors to Firebase App
Distribution, and shipway now catches each of them earlier than it did — but
knowing the shape helps when a project is set up by hand.

## A Firebase upload crashes partway through the APK upload

**Recognise it.** The build finishes, `firebase_app_distribution` starts
uploading, and Ruby crashes during the upload rather than App Distribution
refusing it. Then check the lock file:

```sh
grep -E '^    (google-apis-core|net-http|faraday) ' android/Gemfile.lock
```

**Cause.** `google-apis-core` 1.x moved to Faraday. Neither fastlane 2.238.0 nor
`fastlane-plugin-firebase_app_distribution` caps it below 2.0, so a fresh
resolution picks 1.1.0 — which, alongside `net-http` 0.9.1, crashed the report's
upload. Pinning the plugin alone does not prevent it: shipway's own earlier
pins resolved exactly that combination.

**Known-good set** (last verified 2026-09-14):

| Gem | Version |
|---|---|
| fastlane | 2.238.0 |
| fastlane-plugin-firebase_app_distribution | 0.10.1 |
| google-apis-core | 0.18.0 (`>= 0.18, < 1`) |

**Fix.** Add the ceiling to `android/Gemfile` — the Gemfile shipway generates
already has it — and re-resolve that one gem:

```ruby
gem "google-apis-core", ">= 0.18", "< 1"
```

```sh
cd android && bundle update google-apis-core
```

`shipway doctor` reports this as `gem-lock`, and `shipway release --target
firebase` warns before building when the bundle holds a 1.x.

The report did not keep the crash's stack trace, so shipway recognises this by
the resolved versions, not by the error text.

## `bundle exec fastlane` runs the wrong gems

**Recognise it.** `Could not find <gem> in locally installed gems`, a plugin
reported missing, or a stack trace inside a Ruby you did not choose —
`/opt/homebrew/Cellar/...`.

**Cause.** A Homebrew `fastlane` ahead of your project's Ruby on `PATH`. It is a
shell script that resets `GEM_HOME`, so `bundle exec fastlane` throws the bundle
away.

**Fix.** `shipway release` is not affected: it loads fastlane from the bundle.
For lanes you run yourself, use a binstub — `bundle binstubs fastlane`, then
`./bin/fastlane <lane>` — or put your project's Ruby first on `PATH`. The release
plan prints the Ruby, Bundler and fastlane in use, and `shipway doctor` warns
(`fastlane-shim`).

## App Distribution answers 403

**Recognise it.** "The authenticated user does not have the required
permissions on the Firebase project", at the upload.

**Cause.** Usually a service account from a different Firebase project than the
app — common when flavors live in separate projects.

**Fix.** Give each flavor its account
(`flavors.<name>.firebase.distribution.service_account_ref`), or grant the
account the **Firebase App Distribution Admin** role in the app's project.
`shipway release` now checks this before building, names the account and the
project, and warns when the service account and the `google-services.json`
belong to different projects.

## Gradle: a ProductFlavor with that name already exists

**Recognise it.** `Cannot add a ProductFlavor with name 'dev' as a ProductFlavor
with that name already exists`, after `shipway adopt` and `generate`.

**Cause.** shipway's managed block *creates* each flavor, and so did the
project's own `productFlavors { create(...) }`.

**Fix.** Current shipway rewrites the project's declarations to
`getByName(...)` when it writes the block, and shows that in `adopt`'s diff. By
hand: in your own section, configure flavors with `getByName("<flavor>")` and
keep only what shipway does not set.

## The Dart build fails on `bootstrap`

**Recognise it.** `The function 'bootstrap' isn't defined`, partway through a
Gradle or Xcode build.

**Cause.** The generated `lib/main_<flavor>.dart` calls
`bootstrap({required String flavor})` in `lib/main_common.dart`, and the
project's own `main_common.dart` does not define it.

**Fix.** Add one — `shipway generate` now refuses to write the entrypoints
without it and prints an example — and `shipway build` and `release` analyse the
entrypoint before building.
