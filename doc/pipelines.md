# Design: Phase 5, declarative pipelines

A named sequence of steps in `shipway.yaml`, run with one command.

```yaml
pipelines:
  beta:
    - analyze
    - test
    - parallel:
        - release: { flavor: prod, target: testflight }
        - release: { flavor: prod, target: play }
```

```
shipway run beta
```

It adds no shipping ability: everything a pipeline does can already be done by
hand. What it adds is sequencing, parallelism, recoverability and a record of
what happened — the seams between commands, which is where releasing actually
goes wrong.

## Stages, not a DAG

The plan says "the DAG runner". This uses **sequential stages with an explicit
`parallel` block** instead.

A DAG is more expressive and, here, worse. Inferred dependencies mean a reader
has to reconstruct the execution order in their head, and a missing edge is a
race that shows up once in twenty runs. The only parallelism anyone actually
wants is *iOS and Android at the same time*, and writing that down is clearer
than deriving it:

- steps run in order;
- a `parallel:` block runs its steps together and waits for all of them;
- the order in the file is the order of execution, always.

If a real case turns up that stages cannot express, a DAG can be added later
without changing what is already written.

## Steps

| Step | Does |
|---|---|
| `analyze` | `flutter analyze` |
| `test` | `flutter test` |
| `build` | `shipway build <platform> --flavor <f>` |
| `release` | `shipway release <platform> --flavor <f> --target <t>` |
| `run` | an arbitrary command, for whatever this list does not cover |

`build` and `release` invoke shipway's own commands **in process**, through the
same command runner the CLI uses. Not by shelling out to `shipway`: that would
require it on `PATH` inside its own pipeline, and would lose the exit codes and
classified errors those commands already produce.

`notify` is deliberately **not** a step. Posting to Slack brings a whole
category of failure — retries, timeouts, a webhook that 404s — that has nothing
to do with shipping, so it lives beside the runner instead of inside it: the
run reports to Slack as it goes, and a Slack failure is a warning rather than a
failed step. See [`notifications.md`](notifications.md).

## Checked before anything runs

Every flavor and target a `build` or `release` step names is checked before the
first step, with a suggestion when a name is close to one the config has:

```
Pipeline `beta` releases flavor `prod`, which this config does not declare. Did you mean `production`?
  Flavors: development, production.
```

Found at the release step instead, a typo costs every step before it. `shipway
doctor` runs the same check across all pipelines (`pipelines`).

It is **not** done when the config loads, deliberately: a mistake in one pipeline
must not stop `shipway release` or any other command that never runs that
pipeline. Pipelines are still parsed on use for the same reason.

## Resume, and why it is the hard part

The failure that matters: a `beta` pipeline uploads to TestFlight, then fails
on Play. Re-running the whole thing re-uploads the iOS build, and App Store
Connect rejects it as a duplicate build number — the exact error already in the
classifier.

So a run writes a manifest to `.shipway/runs/<id>.json` recording each step's
outcome, and:

```
shipway run beta --resume
```

**re-runs from the first step that did not succeed.** Everything before is
skipped. That rule is simple enough to hold in your head, which matters more
here than cleverness — a resume that does something subtle is one nobody will
trust with a release.

### Repeatability is a property of the step

Each step declares whether running it twice is safe:

| Step | Repeatable | Why |
|---|---|---|
| `analyze`, `test` | yes | They only read. |
| `build` | yes | Rebuilding overwrites an artifact. |
| `run` | **unknown** | shipway has no idea what the command does. |
| `release` | **no** | The upload may have landed before the failure. |

This matters in one specific case: the step being resumed *into* is the one
that failed, and for a `release` that failure might have come **after** a
successful upload — a network drop while waiting for a response, a cancelled
job. shipway cannot tell the difference, so it does not pretend to: `--resume`
into a non-repeatable step **says so and asks**, and `--yes` is how you say you
have checked.

Not asking would be worse in both directions. Silently re-running risks a
duplicate upload; silently skipping risks a release everyone believes shipped
and did not.

## Failure semantics

- A failed step stops the pipeline. There is no `continue-on-error`: a pipeline
  that carries on past a failure is a pipeline whose result means nothing.
- Inside a `parallel` block, a failure lets the others **finish** rather than
  cancelling them. Killing a half-finished upload is worse than waiting for it,
  and a cancelled build leaves a partial artifact that the next run may pick up.
- The exit code is the first failing step's, so a caller can tell a bad config
  from a bad machine using the codes shipway already defines.

## What a run leaves behind

`.shipway/runs/<id>.json` — already in the generated `.gitignore` — holding each
step's status, duration and exit code, plus the resolved environment with
secrets redacted. It is what `--resume` reads, and what answers "what actually
happened" after the terminal is gone.

A summary table prints at the end either way, because scrollback is not a
report.

## Layering

`lib/src/pipeline/` holds the definitions, the plan and the manifest, and
imports only `core`. It cannot reach the CLI, so the executor takes the
command invoker as a function and `cli` supplies one. That keeps the dependency
direction intact and makes the runner testable without running anything.
