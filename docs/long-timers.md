# Long timers: what a timer days out survives

A `<send delay="7d">` becomes one Oban job. `StatifierOban.Timer.schedule/3`
computes the fire time once, at insert (now plus `delay_ms`), and stores it as
the job's `scheduled_at`; nothing re-derives it later. From then until it fires,
the timer is that row and nothing else: no process holds it.

This page says what such a timer survives while it waits, what it does not, and
which Oban settings a host must keep for the answer to hold. The Oban facts
below were read at Oban 2.23.1, the version this package's `mix.lock`
resolves. `mix.exs` accepts `~> 2.19`, so a host on another Oban version
re-checks the Oban cites against the version it runs.

## The guard is the row

`StatifierOban.Timer.Worker` declares the timer job unique on the
`{scope, ordinal}` pair in its args, over `period: :infinity` and every job
state (`use Oban.Worker, unique: [...]` in `lib/statifier_oban/timer/worker.ex`).
Re-executing a drive after a crash rebuilds the same pair, so the replayed
insert conflicts with the stored row and becomes a no-op, whether that row is
still waiting, already fired, or cancelled.

Oban enforces uniqueness by looking for a matching row at insert time
(`Oban.Engines.Basic` `insert_unique/3` and `unique_query/1`,
`Oban.Engines.Lite` `fetch_unique/2`). There is no separate record of past
inserts: the guard lasts exactly as long as the row does.

These unique options are compile-time options of the worker. No
`StatifierOban.Config` option reaches them, and `Timer.schedule/3` passes no
`:unique` override when it builds the job.

## What a waiting timer survives

**A node restart or a deploy.** The row outlives every process. A new Oban
instance over the same table finds it `scheduled`, with the fire time it was
given, and fires it when it falls due. The host resumes the execution under the
same scope; a replayed drive conflicts with the stored row. When nobody resumes
the execution, the default delivery (`StatifierOban.Timer.Delivery.Session`)
finds no live session at fire time and the job cancels with the discard
recorded on the row, per SCXML 6.2. `test/statifier_oban/restart_round_trip_test.exs`
covers both paths, including a timer scheduled three days out that is still
unique after the restart, fires nothing before its time and fires once after
it.

**A paused queue.** `Oban.pause_queue/2` stops the queue's producers from
fetching; the rows stay where they are. A timer that falls due during the pause
fires once, late, when the queue resumes. Pausing changes when the event
arrives, not whether it does or how many times.

**A leader change.** Oban moves due `scheduled` rows to `available` only on the
leader node (`Oban.Stager`, which checks `Oban.Peer.leader?/1` before staging),
and prunes only on the leader too (`Oban.Plugins.Pruner`). Both work from the
table, so a new leader stages the same rows the old one would have. A gap with
no leader delays the fire; it loses nothing.

**A deploy that briefly breaks delivery.** A delivery module this node cannot
resolve, or a codec that cannot decode the row right now, returns an error and
the job retries (`StatifierOban.Timer.Worker` moduledoc). The worker sets no
`max_attempts`, so Oban's default of 20 applies (`Oban.Worker`); a fix deployed
inside that retry window delivers the timer.

## What it does not survive

**Pruning of its row after it fired or was cancelled.** `Oban.Plugins.Pruner`
deletes only `completed`, `cancelled` and `discarded` jobs older than its
`:max_age` (60 seconds by default), and never a `scheduled`, `available` or
`retryable` one: a waiting timer is not pruned. But once a timer has fired or
been cancelled and its row is pruned, the guard for that scope and ordinal is
gone. A drive replayed after that inserts a fresh job, so a fired timer fires
again and a cancelled one comes back. The age is counted from `completed_at`
on the Lite engine and from `scheduled_at` on the Basic engine for a completed
job, and from `cancelled_at` or `discarded_at` on both
(`prune_jobs/3` in `Oban.Engines.Lite` and `Oban.Engines.Basic`).

**A changed scope.** The dedup key is `{scope, ordinal}`, and the ordinal is a
per-execution counter, so the scope is what makes the pair unique across
executions. A host that resumes an execution under a different scope than it
armed the timer with gets no dedup on replay, and the stored job still names
the old scope: the default delivery finds no session registered under it and
discards the fire.

**A moved timers queue, if the old one stops running.** Dedup and cancellation
both ignore the queue, so a replay or a cancel still finds a row stored under
the old queue name. Firing does not: a row fires only on a node running its
queue. A host that renames `:timers_queue` keeps the old queue running until no
timer job remains in it.

**Node death in the middle of a delivery.** A job that was `executing` when its
node died stays `executing`. Nothing in this package moves it; Oban's
`Oban.Plugins.Lifeline` rescues it back to `available` after `:rescue_after`
(60 minutes by default), and the rescued attempt delivers again. Oban's own
docs warn that the rescue can duplicate a genuinely running job. Without a
rescue, that timer never completes.

**Exhausted retries.** After the last attempt, Oban discards the job; the row
is then pruned like any other terminal row.

## The Oban settings a host must keep

| Setting | Keep it so | Why |
|---|---|---|
| `queues:` | the `:timers_queue` runs on at least one node, and a renamed queue's old name keeps running until it is empty | a row fires only where its queue runs |
| `Oban.Plugins.Pruner` `:max_age` | longer than the longest window in which the host can replay a drive for an execution it has armed timers in | the row is the dedup guard; a replay after the prune inserts a second timer |
| `Oban.Plugins.Lifeline` (or an equivalent rescue) | running, with `:rescue_after` above the longest delivery the host expects | a delivery cut off by node death is otherwise never retried |
| `peer:` and `plugins:` | at least one node can lead: not `peer: false` or `plugins: false` on every node | staging runs only on the leader (`Oban.Config` maps both to a non-leading peer) |
| `repo:` and `prefix:` | the same table across deploys | the rows are the timers |

None of these is set by this package: the Oban instance is the host's
(ADR-0002).
