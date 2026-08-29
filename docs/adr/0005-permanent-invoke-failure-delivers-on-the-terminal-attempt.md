# ADR-0005: Permanent invoke failure delivers on the terminal attempt

Status: accepted (2026-08-27, sob-nnh) - amended 2026-08-29 (sob-aty, PR 40: decision 6 narrowed, undecodable-payload arm delivers)

## Context

`StatifierOban.Invoke.Worker` maps a handler's `run/1` failure onto an Oban
retry: the work is idempotent on `invoke_id` by contract, so retrying is what
at-least-once means. When the retries run out, Oban discards the job - and
until now nothing reached the chart. The failure was observable on the job row
(`discarded`, with `{:run_failed, reason}` in the errors) and nowhere else, so
a chart that parks failed work in a recovery state never left the invoking
state. `StatifierOban.Invoke.Handler` carried that gap as an explicit open
question, because the event vocabulary is statifier-ex's to decide, not this
package's.

statifier-ex has now decided it (st-ADR-0068):

- the event is `error.communication.invoke.<invoke_id>`, an `:external` event
  carrying `invokeid`/`origin`/`origintype` exactly as `done.invoke.<invoke_id>`
  does, and a spec 3.12.1 suffix extension of the `error.communication` that
  st-ADR-0051 decision 1 already assigns to a handler failing to reach its
  service - so a chart transitioning on the bare `error.communication` catches
  it unedited;
- the payload is `%{"reason" => String.t(), "attempts" => integer | :undefined,
  "detail" => term | :undefined}`, none of which statifier-ex interprets;
- the door is `Statifier.Session.failed_invocation/3`, called by the **host's
  retry layer** on permanent exhaustion and never by a handler callback, using
  `done_invocation/3`'s own delivery path.

This package is that host's retry layer. What remains is entirely local: how to
recognize exhaustion, what the failure classes are, and what the seam looks
like.

One structural fact bounds the design. **Oban has no discard callback.**
`Oban.Worker` gives `perform/1`, `backoff/1` and `timeout/1`; nothing is
invoked when a job's errors turn it from `retryable` into `discarded`. The
alternatives are to recognize the terminal attempt from inside `perform/1`, or
to attach a global telemetry handler on `[:oban, :job, :exception]` and filter
for the discard.

## Decision

**1. The terminal attempt is recognized from the job row, inside `perform/1`.**
Oban stamps `attempt` before the attempt runs, and `attempt >= max_attempts` is
precisely the condition that turns the coming error into a discard rather than
a retry. The failure is delivered on the way past, and the worker then returns
the same value it always returned, so the job outcome, its state and its
recorded error are byte-for-byte what they were before this ADR.

Telemetry was rejected. A global handler is process-wide state belonging to
whoever attaches it, it fires for every worker in the host's Oban instance and
must filter, it cannot see the decoded effect or the job's resolved delivery
module without redoing the worker's own decode, and a detached or crashed
handler fails silently and invisibly. Delivery from the attempt that is failing
is local, testable by draining a queue, and needs no host wiring at all.

**2. Non-terminal failures deliver nothing.** A retry that will be tried again
is not a fact the chart should hear about; only exhaustion is. This keeps the
event's meaning "this invocation is over" rather than "something went wrong
once", which is what a chart parking work for operator recovery needs it to
mean.

**3. Two failure classes: `"run_failed"` and `"run_crashed"`.** The vocabulary
is this package's, per st-ADR-0068. `"run_failed"` is the terminal attempt
returning `{:error, reason}`, with `:detail` the inspected reason;
`"run_crashed"` is the terminal attempt raising or exiting, with `:detail` the
exception message or the inspected exit reason. `:attempts` is the terminal
`attempt`.

Covering crashes matters as much as covering returned errors: a handler that
raises exhausts its retries just as permanently, and it is the commonest
failure of all. The rescue and catch arms re-raise the original with its own
stacktrace, so they change nothing about the job - they only let the run be
told before the exception continues on its way.

**4. `:detail` is always a string**, where st-ADR-0068 permits any term. The
value travels into chart data, where a raw term carrying pids, refs or
closures is a serialization hazard for any host persisting a run, and where a
string is what an expression can usefully read.

**5. `deliver_failure/3` is a required callback on
`StatifierOban.Invoke.Delivery`, and a delivery module lacking it is
unresolvable.** The two doors are one seam: a host answering "is this run
live?" for a completion answers it identically for a failure, and the default
implementation runs one liveness check for both, because st-ADR-0068 makes the
failure event travel `done_invocation/3`'s own path upstream. A check that
diverged here would be this package contradicting the contract it implements.

Resolving a `deliver/3`-only module and discovering the gap at exhaustion was
rejected: it would trade a retry the host can fix by deploying for a failure
event it silently loses. `:invalid_delivery` already means "an environment fact
about the host's code, fixable by a deploy", which is exactly what a delivery
module predating st-ADR-0068 is.

**6. Only `run/1`'s own exhaustion delivers.** The environment errors -
`:invalid_handler`, `:invalid_delivery`, `:invalid_codec`, `:codec_failed` -
retry and can in principle exhaust too, but they say nothing about the
invocation; they say the deploy is wrong. `:invalid_delivery` has by definition
no seam to deliver through. Codec decode failure that *cancels* rather than
retries is a separate question tracked upstream as st-uumw, and is deliberately
not wired into this door here.

## Consequences

Charts get the recovery-parking pattern they were missing: a transition on
`error.communication`, or on the fully qualified
`error.communication.invoke.<invoke_id>`, fires when an async invocation gives
up for good, and the run leaves the invoking state instead of hanging in it.

`StatifierOban.Invoke.Handler`'s open question is closed, and its moduledoc now
documents the behavior rather than the gap.

**This is a breaking change for a host that implements
`StatifierOban.Invoke.Delivery` itself.** A custom delivery module must add
`deliver_failure/3`; until it does, its jobs retry with
`{:error, {:invalid_delivery, name}}` rather than delivering. Hosts on the
default `StatifierOban.Invoke.Delivery.Session` are unaffected.

The package now requires `Statifier.Session.failed_invocation/3`, which raises
this package's floor on statifier to the release carrying st-ADR-0068.

Decision 1 reads two fields of `%Oban.Job{}` that Oban documents but does not
version, and it assumes `max_attempts` is not raised after a job is stored. A
host that bumps `max_attempts` on a discarded job to revive it would have
already delivered a failure event for an invocation that then succeeds; the
chart would see the error event and, later, the completion. That is a
deliberate limit rather than an oversight, and the reopen trigger for this ADR
is a host that needs to revive discarded invoke jobs that way.

## Amendment (2026-08-29): the undecodable-payload arm delivers through the door

Status: accepted (2026-08-29, unqualified direction-agent verdict under the operator campaign-015 grant, sob-aty, PR 40)

Decision 6 above says:

> **6. Only `run/1`'s own exhaustion delivers.**

and, of the remaining case:

> Codec decode failure that *cancels* rather than retries is a separate
> question tracked upstream as st-uumw, and is deliberately not wired into
> this door here.

st-uumw has since been decided. statifier-ex's st-ADR-0068 carries a dated
decision note (2026-08-29, PR 238) ruling that a permanently undecodable stored
payload is that record's own failure family rather than a new one: the host's
retry layer reports it through `Statifier.Session.failed_invocation/3` with
`"reason"` spelled `"undecodable"`, and no new event name, function or error
family is created. The note names `StatifierOban.Invoke.Worker` as the first
caller. That code has landed here, so decision 6's text is now narrower than
what this package does. This amendment records the difference; it adds to
decision 6 and revises nothing else in this record.

### Decision

**The undecodable-invoke-payload arm delivers through the door, on the
attempt that finds it.** When `JobArgs.to_invoke/1` fails in a way that
cancels the job rather than retrying it, `perform/1` calls
`deliver_failure/3` through the private `fail_undecodable/2` before returning
the cancel, with `reason` `"undecodable"` (the spelling st-ADR-0068's note
pins), `attempts` the job's own `attempt`, and `detail` the inspected decode
error. The cancel the worker returns is unchanged, so the job's state and
recorded error stay what they were; the delivery happens on the way past,
exactly as decision 1 describes for the terminal attempt.

**`attempts` is that attempt, not `max_attempts`.** Decision 1 recognizes the
terminal attempt as `attempt >= max_attempts`, and `maybe_fail/6` still
delivers only there. An undecodable row never reaches that condition and
should not: no number of retries makes a corrupt row decodable, so the attempt
that discovers it *is* the invocation's last one. Delivering the count the job
actually ran keeps `attempts` meaning "how many attempts this invocation got",
which is what it means on the `"run_failed"` and `"run_crashed"` arms too.

**Two arms remain bare cancels, and for the same reason decision 6 gives.**
A row whose `scope` or `invoke_id` are themselves undecodable names nobody to
tell: there is no run and no invocation to address the event to, so it cancels
without the door, unchanged. On such a row, an unresolvable delivery module -
decision 5's `:invalid_delivery`, by definition no seam to deliver through -
leaves the cancel standing with no delivery; on a decodable row it still
retries as decision 6 says. The environment errors decision 6 lists
(`:invalid_handler`, `:invalid_delivery`, `:invalid_codec`, `:codec_failed`)
still retry and still deliver nothing: they say the deploy is wrong, not that
the invocation is over.

**Not decided here: the timer half.** Whether an undecodable *delayed-send*
payload has an analogous report is untouched by this amendment.
`StatifierOban.Timer.Worker`'s equivalent arm is unchanged, and st-ADR-0068's
note leaves the same question open upstream (filed there as st-i7y8). Nothing
above should be read as deciding it.

### Consequences of the amendment

A chart parked on `error.communication` no longer hangs on an invocation whose
stored payload rotted: the corruption of an opaque `params` blob does not
touch the two plain-string identity fields, so the run can still be told. That
is the only behavior this amendment adds.

`:detail` stays a string (decision 4), here the inspected decode error rather
than the typed term, for the serialization reason decision 4 already gives.

The reopen trigger is a host that needs an undecodable row to retry rather
than cancel - that would put the arm back under `maybe_fail/6`'s terminal-
attempt rule and make this amendment wrong.
