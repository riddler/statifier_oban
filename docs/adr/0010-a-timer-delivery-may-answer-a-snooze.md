# ADR-0010: A timer delivery may answer a snooze, so a parked timer spends no retries

Status: proposed (2026-09-27, sob-46l)

## Context

A fired timer job hands its stored effect to the host's
`StatifierOban.Timer.Delivery` implementation. At 835ad52 the callback
`c:StatifierOban.Timer.Delivery.deliver/2` (`lib/statifier_oban/timer/delivery.ex`)
answers `:delivered` or `{:discarded, reason}` and nothing else, and
`StatifierOban.Timer.Worker.perform/1` (`lib/statifier_oban/timer/worker.ex`)
maps the first to `:ok` and the second to `{:cancel, {:discarded, reason}}`.
The shape of the callback comes from statifier-ex's `st-ADR-0054` decision 4:
before feeding a fired event back, the host establishes that the execution is
still live, and discards the message otherwise.

One execution state fits neither answer. An execution parked by a chart
migration - statifier_persistence's `:needs_migration` status, which its
`step/5` answers with `{:error, {:needs_migration, execution}}` - is not
finished, takes no event while it is parked, and takes events again once it is
unparked. The behaviour's moduledoc section "A parked execution retries; it is
never discarded" (at 835ad52) already rules what a timer firing into it does:
it is retried, never discarded, and the only retry the seam admits is a raise.
The README's "Delivering timers to a durable execution" teaches the same raise
in its `{:error, {:needs_migration, _execution}}` arm.

A raise spends an attempt. `StatifierOban.Timer.Worker` sets no
`max_attempts`, so Oban's default of 20 applies, and Oban's default backoff
spreads them over about twelve days (the moduledoc section above). A park that
outlasts them ends the job `discarded` by Oban, and the timer does not fire on
its own after the unpark. Take a loan execution in `due_soon`, with its
due-date reminder scheduled: the operator ships a chart migration, the loan is
parked for review, and the reminder fires into the parked loan. Each firing
raises, each raise spends one of the twenty attempts, and a review that takes
two weeks costs the loan its reminder. The host has no way to say "not now,
ask again later" without spending the budget that exists for environment
failures.

Oban already has that answer. A worker's `perform/1` may return
`{:snooze, seconds}`, and Oban reschedules the job for at least that many
seconds later without counting the run against its retries. The seam does not
pass it through: the callback's return type has no such arm, and the worker's
`case` over the answer has no clause for one, so an answer outside the two
raises a `CaseClauseError` and retries like any other raise.

Widening the callback's return is a change to a public callback a host codes
against. The operator ruled on 2026-09-27 that it is recorded first, in this
record, and that the code follows only once the record is accepted.

## Decision

**1. `deliver/2` gains a third answer, `{:snooze, seconds}`.** `seconds` is a
positive integer. It means: the execution is not finished and cannot take the
event now; ask again after at least `seconds`. It is neither a delivery nor a
discard, and it is optional: an implementation that never returns it behaves
exactly as it does today. The callback's return type gains the arm, and the
behaviour gains a type for it beside `t:StatifierOban.Timer.Delivery.discard_reason/0`.

**2. The worker hands the snooze to Oban unchanged.**
`StatifierOban.Timer.Worker.perform/1` returns `{:snooze, seconds}` for the
job. Oban reschedules it: the row goes to `scheduled` with `scheduled_at` at
least `seconds` from now. A snooze spends no retry: the number of attempts the
job has left, `max_attempts` minus `attempt`, is the same after the snooze as
before the run that answered it. How Oban keeps that number whole is Oban's and
varies by version: in the 2.23.1 that `mix.lock` resolves,
`Oban.Engines.Basic.snooze_job/3` (which `Oban.Engines.Lite` delegates to)
raises `max_attempts` by one and leaves the run counted in `attempt`; from
2.24 it gives the run back from `attempt` instead and counts the snooze in the
job's `meta`. Either way the park no longer eats the budget a raise draws on.

**3. A snooze is not a discard, and a finished execution is still discarded.**
`st-ADR-0054` decision 4 is unchanged: an execution that is finished answers
`{:discarded, reason}`, and an environment failure - a store the host cannot
reach - still raises. A snooze is for the execution that is neither: the
parked execution this record was written for, or any other state a host's
store has in which the execution is not finished and will take events again.
The rule of the moduledoc section "A parked execution retries; it is never
discarded" stands; a snooze is the cheaper way to retry it. The default
`StatifierOban.Timer.Delivery.Session` never answers a snooze: a session
process is running, halted or gone, and none of those is a park.

**4. A snoozed timer is still a pending timer.** The snoozed row is
`scheduled`, a state `StatifierOban.Timer.cancel/3` reaches and
`StatifierOban.Timer.pending_for/2` counts, so a spec 6.3 cancel of the send
id still stops it and the execution's pending count still includes it. The
dedup guard is unchanged: `StatifierOban.Timer.Worker`'s uniqueness covers
every job state over an infinite period on the `{scope, ordinal}` args, and a
snooze changes neither the args nor the state set.

**5. No new telemetry event.** `ADR-0006` decision 2 leaves snoozes to Oban
and does not re-emit them; a snooze is not a spec-level verdict. Oban's own
job `:stop` event reports the run with the state `:snoozed`, and the job it
carries holds the scope and ordinal in its args. Neither
`[:statifier_oban, :timer, :fired]` nor `[:statifier_oban, :timer, :discarded]`
fires for a snoozed run; whichever of them fires, fires for the run that
finally delivers or discards. The `attempt` measurement those two events carry is the job's
`attempt`, so on an Oban that counts a snoozed run in `attempt` (decision 2)
it includes the snoozed runs. A later record adds an event if a host needs the
snooze under this package's prefix.

**6. Any other answer is handled as it is today.** An answer that is not
`:delivered`, `{:discarded, reason}` or `{:snooze, seconds}` with a positive
integer - `{:snooze, 0}`, a negative count, an Oban period tuple - matches no
clause, raises, and retries, exactly as an unrecognised answer does at
835ad52. A zero snooze would re-run the job at once and hold a queue slot in a
loop; a period tuple is Oban's spelling, not this seam's.

**7. The bound on a snooze is the host's.** This package counts no snoozes
and caps none. A host that snoozes a timer for as long as its execution stays
parked keeps the row `scheduled` for that long; a park that never ends keeps
the timer pending for good, which is the correct answer for an execution that
is not finished. A host that wants a ceiling keeps its own (a park the host
gives up on is finished, and then it discards).

## Consequences

- A host holding a parked execution's timer answers
  `{:snooze, seconds}` instead of raising, and the timer survives a park of
  any length with its retries intact. In the loan example above, the reminder
  waits out the review and fires on the first run after the unpark.
- The behaviour's moduledoc section "A parked execution retries; it is never
  discarded" and the README's `{:error, {:needs_migration, _execution}}` arm
  change with the code: they teach the snooze, and keep the raise for the
  environment failures it is for. The moduledoc's sentence "an Oban snooze is
  not available from inside it" is true at 835ad52 and stops being true with
  the code.
- The period is the host's choice and is a trade: a short one re-reads the
  store often while the park lasts, a long one delays the event after the
  unpark by up to the period.
- On an Oban that counts a snoozed run in `attempt` (2.23.1, decision 2), a
  later raise backs off from the higher attempt count, so the first
  environment-failure retry after many snoozes waits longer than it would on
  a fresh job.
- The return set of `deliver/2` grows, so the change ships in a minor release
  with a changelog fragment. A delivery module that answers a snooze against a
  release of this package without the code falls into decision 6's clause:
  it raises and retries, which is what the same module did before by raising
  itself.
- The code - the callback type, the worker's clause, a test that a snoozing
  delivery reschedules the job with its retries intact, the moduledoc and the
  README - follows this record once it is accepted, and the record stays
  proposed until that code ships in a published version.

## Note (2026-09-28): the retry window as the code documents it, and the code landed at proposed

Two statements above are read here against the code that landed for
this record. Every claim below was read at `05d461f`. This Note decides
nothing and changes no Status.

- The retry window. The Context says Oban's default backoff spreads the
  timer job's retries "over about twelve days". The
  `StatifierOban.Timer.Delivery` moduledoc section "A parked execution
  retries; it is never discarded" (`lib/statifier_oban/timer/delivery.ex`)
  now gives the range: with no `max_attempts` set on the timer worker,
  Oban's default of 20 attempts spreads over **twelve to thirteen and a
  half days**, since the wait after attempt `n` is `15 + 2^n` seconds
  plus a random 0-10% jitter, which sums over the 19 retries to about
  12.1 days with no jitter and about 13.4 with the most. "About twelve
  days" is the no-jitter floor of that range. The README's "Delivering
  timers to a durable execution" gives the same range.
- The code landed while this record is at proposed. The Context's last
  paragraph and the last Consequences bullet say the code follows this
  record "once the record is accepted" and "once it is accepted". The
  operator ruled on 2026-09-28 that the code ships while the record is
  at proposed, and it has: `05d461f` adds the `{:snooze, seconds}` arm to
  `c:StatifierOban.Timer.Delivery.deliver/2` with `t:StatifierOban.Timer.Delivery.snooze/0`,
  the clause in `StatifierOban.Timer.Worker.perform/1`
  (`lib/statifier_oban/timer/worker.ex`), the tests, the moduledoc and
  the README. That code is not yet in a published version (`mix.exs`
  reads `@version "0.16.0"`, and the change waits in
  `changelog.d/sob-46l.md`). The record stays proposed, as the same
  Consequences bullet says, until that code ships in a published
  version, and flips then.
