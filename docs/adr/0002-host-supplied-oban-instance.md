# ADR-0002: Host-supplied Oban instance; SQLite-backed test harness

Status: accepted (2026-08-22)

## Context

Two linked choices shape every public function signature in this package:
whether it owns an Oban instance or borrows the host's, and what its test
suite runs Oban against.

Oban supports multiple named instances in one VM, each with its own repo,
queues, and plugins. A library that starts its own instance forces a second
Oban supervision tree, a second notifier, and a second set of plugins into
every host - and forces its configuration model (repo, engine, prefix) onto
hosts that already made those choices.

The deciding input is concrete: the first production embedder ships its
engine integration as a separate release owning its own named Oban instance
and queues (one queue for step execution, one for timers). That host cannot
adopt a package-owned Oban instance at all. A package-owned instance would
therefore fail its first real deployment; a host-supplied one costs other
hosts nothing, since a host without Oban configured must add it either way.

For the harness: Oban's job execution needs an Ecto repo, and this package
had none. The realistic options were a Postgres test repo (matching the
likely production engine) or Oban's SQLite-backed Lite engine, which needs
no database service on any machine that runs the suite.

## Decision

**This package never owns, starts, or names an Oban instance.** Every public
entry point takes the host's instance, carried in `StatifierOban.Config`:

- `Config.new/1` requires `:oban` - the host's instance name, anything
  `Oban.name()` allows. There is no default, not even Oban's own default
  name `Oban`: a missing instance is a loud configuration error at the call
  site, never a silent fallback into whatever instance happens to be running.
- The package's application supervision tree stays empty. Nothing here
  starts Oban, a repo, or a notifier.
- Queues are the host's as well. This ADR fixes only instance ownership;
  which queue each job kind targets travels with the beads that introduce
  those jobs (sob-2hx.3 and after), as further `Config` fields.
- Migrations are the host's: the host runs `Oban.Migration` against its own
  repo. This package ships no migrations.

**Tests run against Oban's Lite engine on SQLite** (`ecto_sqlite3`,
test-only dependency): a repo module and migration under `test/support/`,
started from `test/test_helper.exs` with runtime options - no `config/`
directory. Tests start Oban instances under their own supervisors with
non-default names, which exercises the host-supplied shape on every run.
If a future feature depends on engine-specific behavior the Lite engine
cannot represent, that feature's bead adds the Postgres harness alongside -
it does not replace this one.

## Consequences

- Public functions follow the family convention: the `Config` (or the
  instance it carries) is the first argument, threading like a session.
- The suite and CI need no database service; `mix quality` is self-contained.
- Hosts keep a single Oban dashboard/telemetry surface; this package's jobs
  are visible in the host's own tooling rather than a parallel instance's.
- The dedup-key work (sob-2hx.1 and the ordinal-key follow-ups) is
  unaffected: keys scope by chart run, not by instance identity.
- Risk accepted: the Lite engine is not byte-for-byte the Basic (Postgres)
  engine. Both are Oban's own engines behind one contract, and the behaviors
  this package relies on (insert, uniqueness, draining, cancellation) are
  supported by both; any divergence found gets a bead and, if needed, the
  side-by-side Postgres harness above.

## Note (2026-08-31): the first downstream host runs the Lite engine too

The harness choice in the Decision above was made with no host to check it
against. There is one now:
[statifier_examples](https://github.com/riddler/statifier_examples), a public
example application, runs an abandoned-signup reminder on this package over
`Oban.Engines.Lite` and `ecto_sqlite3` - arming a delayed send, cancelling
it, letting it fire, and delivering the fired event into a run that is
rebuilt from storage rather than held in a process - with no host-side
workarounds.

It supplies exactly what the Decision says a host supplies: its own named
Oban instance on the Lite engine (with a matching notifier, since SQLite has
no `LISTEN/NOTIFY` for the default one), Oban's migration against its own
repo, and - having no session process to look up - its own
`StatifierOban.Timer.Delivery` implementation, answering liveness from the
stored run.

This retires nothing above it. The risk recorded under Consequences stands
unchanged: the Lite engine is still not byte-for-byte the Basic (Postgres)
engine, and no side-by-side comparison has been run. What the evidence adds
is narrower and worth having anyway - the behaviors this package relies on
(insert, uniqueness, draining, cancellation, and a fired job delivering
into a run reconstructed from storage) hold on Lite outside this repo's own
suite as well as inside it.

## Note (2026-09-12): the durable record this record calls a "run" is an execution

`statifier_persistence` ADR-0011 (proposed) names the durable
record a chart's progress is persisted against an **execution**, retiring
"run" as the family's word for it. This package's prose moved to that word in
`sob-mh3`. This record did not: nothing above moves, and nothing observable
changes.

Two readings shift in word only. Where the Note of 2026-08-31 says the
downstream host's harness answers liveness "from the stored run", and where it
lists "a fired job delivering into a run reconstructed from storage", read
*execution* - the same durable record under its new name. The Decision stands
as written: the host supplies its own named Oban instance, and this repo's
suite runs against the Lite engine.

The rename reaches no callback shape and no stored byte. The scope a
host answers liveness for is still the plain string the job row carries,
described in `StatifierOban.Timer.Key`'s `@moduledoc` and typed there as
`t:scope/0`, both unchanged by `sob-mh3` (`lib/statifier_oban/timer/key.ex`,
read at `2ffc3b7`); the delivery seam this Note's harness implements is
`StatifierOban.Timer.Delivery`, whose `c:deliver/2` and `t:discard_reason/0`
are untouched (`lib/statifier_oban/timer/delivery.ex`, read at `2ffc3b7`).

`ADR-0011` is proposed and is not yet on `statifier_persistence`'s `main`, so
no line of it is cited here. Recorded by `sob-mh3`.

## Note (2026-09-23): a host's transaction around an insert, and Oban's retry

A Note, not an amendment: it decides nothing new and changes no code. It
records what happens when a host calls this package's inserts and cancels
inside a transaction of its own - the sending step's, when the host's
executor runs its effects inside one - and the one setting that governs
it. Every cite below was read at `09e36f7`, against oban 2.23.1 and
db_connection 2.10.2, the versions `mix.lock` resolves.

**The calls.** `StatifierOban.Timer.schedule/3` inserts a job with
`Oban.insert/2`, and so does `StatifierOban.Invoke.Handler.perform_start/3`,
in its private `enqueue/4`. `StatifierOban.Timer.cancel/3`,
`StatifierOban.Invoke.Handler.perform_cancel/3` and
`StatifierOban.Invoke.FanOut.cancel_unstarted/3` cancel with
`Oban.cancel_all_jobs/2`. `StatifierOban.Invoke.FanOut.start/5` inserts one
job per child in its private `enqueue_all/6`; this package calls it from a
fan-out job's perform, the private `fan_out/7` in
`StatifierOban.Invoke.Worker`, and Oban runs a perform in no transaction
(`Oban.Queue.Executor.perform/1`). A host that calls it inside a
transaction of its own meets the insert edge below.

**An insert runs in Oban's retrying transaction; a cancel does not.** On
the Basic engine, `Oban.Engines.Basic.insert_job/3` makes the insert
inside `Oban.Repo.transaction/3`, called with the config and the function
and no options. A cancel is one update in no transaction:
`Oban.Engines.Basic.cancel_all_jobs/2` calls `Oban.Repo.update_all/3`, and
the retry loop below lives only in `Oban.Repo.transaction/3`. A cancel
whose statement fails raises to its caller, unretried. On the Lite engine
this package's suite runs, `Oban.Engines.Lite.insert_job/3` opens no
transaction at all, so nothing below reaches the suite.

**What the retry does when it is nested.** `Oban.Repo.transaction/3`
rescues `DBConnection.ConnectionError`, `UndefinedFunctionError`, and
`Postgrex.Error` and `MyXQL.Error` when those are loaded (`Oban.Errors`),
and retries: up to `:retry` attempts (default 5), sleeping `:delay`
(default 500 ms) times the attempt, jittered; or, for a deadlock, a
lock-not-available or a serialization failure, up to `:expected_retry`
attempts (default 20) at `:expected_delay` (default 10 ms). Inside an
enclosing transaction an attempt gets no savepoint: the clause of
`DBConnection.transaction/3` for a connection already in a transaction
runs the function directly and, on a raise, marks the connection aborted
before re-raising. From then on every statement on that connection raises
`DBConnection.ConnectionError` with "transaction rolling back" (the
aborted-status clause of `DBConnection.Holder`'s private
`handle_or_cleanup/5`), which is itself retryable. So no retry can
succeed: each attempt fails the same way, and the sleeps between them hold
the enclosing transaction open until the budget is spent. What happens
then is `:on_exhausted`'s:

- `:raise`, the default, re-raises the last error - the "transaction
  rolling back" one, not the statement's error that aborted the
  transaction. This is the masking Oban's documentation of
  `Oban.Repo.transaction/3` warns of under "Nested Transactions", where it
  asks for `retry: false`.
- `:log` logs and returns `{:error, exception}`, which `Oban.insert/2`
  hands back unchanged; `Timer.schedule/3` and `perform_start/3` then
  answer `{:error, exception}` over a transaction already lost.

Either way the enclosing transaction does not commit: `DBConnection`'s
private `conclude/2` turns an aborted transaction into a rollback when its
outermost function returns.

**What a host sets.** The per-call `retry: false` Oban documents cannot be
given from here: `Oban.Engines.Basic.insert_job/3` passes no options to
its transaction, so an option on `Oban.insert/3` does not reach it. The
one setting that does is the host's compile-time
`config :oban, Oban.Repo, retry_opts: [...]` (`Oban.Repo`'s moduledoc,
"Retries"), which needs `:oban` recompiled and governs every
`Oban.Repo.transaction/3` the host's instance makes, Oban's own job
fetching included (`Oban.Engines.Basic.fetch_jobs/3`). A host whose
executor calls the functions above inside its step's transaction and
wants the statement's own error raised at once sets `retry: false` there
and keeps `on_exhausted: :raise`; a host that keeps the defaults gets a
raise after the budget, carrying the rolling-back error; a host that sets
`on_exhausted: :log` gets the value above.

**What this package does.** Nothing changes in `lib/`. It passes no retry
option, because at this version none reaches the transaction, and it sets
no Oban configuration, because the instance and its configuration are the
host's (the Decision above). The Lite harness cannot represent this edge
and no behaviour of this package depends on it, so the Decision's
Postgres-harness clause is not reached. The question is worth reopening
when an Oban version passes a per-call option through
`Oban.Engines.Basic.insert_job/3` to its transaction. Recorded by
`sob-i1e`.
