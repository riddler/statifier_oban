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
