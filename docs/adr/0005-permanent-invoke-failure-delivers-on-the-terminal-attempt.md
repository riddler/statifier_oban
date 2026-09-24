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

## Note (2026-09-05): a fourth failure class, for a fan-out refused before it starts

Decision 3 above says:

> **3. Two failure classes: `"run_failed"` and `"run_crashed"`.** The
> vocabulary is this package's, per st-ADR-0068.

and the 2026-08-29 amendment added a third, `"undecodable"`, for a row that
cancels rather than retrying. `sob-q3y` adds a fourth for the same structural
reason the third exists: a new way for an invocation to be permanently over
that decision 3's two classes do not name, reported through the door this
record already built. As with the amendment, **no new event name, function or
error family is created** - the event is still
`error.communication.invoke.<invoke_id>`, the door is still
`deliver_failure/3`, and `:detail` is still a string (decision 4). This Note
adds to decision 3 and revises nothing else in this record.

**The class is `"fan_out_refused"`.** ADR-0007 decision 8 says a fan-out
exceeding a host's cap is "a **failure of the invocation**, carried on
`error.communication.invoke.<block id>` with `st-ADR-0068`'s payload, not a
compile finding and not a validation finding", and that record's 2026-09-05
Note gives the cap a number (`StatifierOban.Config`'s `:max_fan_out`). A
handler that returns `{:fan_out, items}` and is refused therefore needs a
`"reason"`, and reusing `"run_failed"` would be wrong twice over: `run/1` did
not fail, it succeeded and asked to fan out, and decision 3 pins that class to
a terminal attempt returning `{:error, reason}`.

**`:detail` carries counts and constants only.** It is the refusal inspected -
`%{reason: :cap_exceeded, count: N, cap: C}` when the list is longer than
`:max_fan_out`, `%{reason: :empty_items}` when it is empty, and
`%{reason: :invalid_items}` when the handler returned something that is not a
list. The two integers are what ADR-0007's Note requires the chart to be told;
what the list *holds* is host data and never travels, for the reason ADR-0006
decision 9 gives about putting unvalidated host state on an event.

**`:attempts` is that attempt, not `max_attempts`**, exactly as the
2026-08-29 amendment ruled for `"undecodable"` and for its reason. A refusal
is decided **before the first child start**, from the list alone, so no number
of retries makes it come out differently: the attempt that discovers it *is*
the invocation's last one, and the job cancels rather than retrying. Delivering
the count the job actually ran keeps `:attempts` meaning "how many attempts
this invocation got" on all four arms.

**This is not the terminal-attempt rule being widened.** `maybe_fail/6` still
delivers only at `attempt >= max_attempts`, and the two `run/1` classes still
reach the door only through it. The refusal takes the same shape the
undecodable arm takes - deliver on the way past, then return the cancel - and
decision 1's reading of the job row is untouched.

**Not decided here: the empty fan-out's semantics.** This Note records that an
empty `items` list is *refused* and how that refusal reaches the chart. Whether
an empty `core.map` ought instead to answer with an empty result is a question
for the record that owns what the block does with its answers, and is filed
there rather than settled here.

Recorded from the operator's ruling `RQ-031-1` option (a) (campaign 031,
2026-09-05), and implemented by `sob-q3y` in `StatifierOban.Invoke.Worker`.

## Note (2026-09-06): the empty fan-out is answered, not refused

The 2026-09-05 Note above closed with a question it declined to settle -
*"Whether an empty `core.map` ought instead to answer with an empty result is
a question for the record that owns what the block does with its answers, and
is filed there rather than settled here."* That record had in fact already
answered it. `sb-ADR-0009` decision 8, accepted 2026-09-01, says an `items`
list resolving to `[]` is **a successful fan-out over nothing**: zero children
start, the accumulated list is written as `[]`, and the block takes `done`
immediately. `sb-ADR-0011` recorded the disagreement between that record and
this package's shipped refusal as a deferred question, and the operator ruled
it on 2026-09-06 (campaign 033, `sob-as0` / `sb-xwhj`): the record wins and
the handler changes.

**`:empty_items` is gone from `:detail`.** Of the three reasons this Note's
parent lists, two remain - `%{reason: :cap_exceeded, count: N, cap: C}` and
`%{reason: :invalid_items}` - and an empty list reaches neither. A third
reason the parent does not list, `%{reason: :invalid_policy}` for an `on`
that is neither `"all"` nor `"first_error"`, also reaches the class; it
arrived with the aggregation policy and this record neither decided it nor
decides it now. `StatifierOban.Invoke.FanOut.start/5` returns `{:empty, []}`
for an empty list and `StatifierOban.Invoke.Worker` delivers that list on the
invocation's ordinary `done.invoke` door, the same door and the same shape a
`run/1` answer takes.

**Nothing else in this record moves.** The `"fan_out_refused"` class stays,
carrying every refusal that still exists; `:attempts` is still the attempt
that found the fault; the terminal-attempt rule of decision 1 is untouched;
and no new event name, function or error family is created. An empty fan-out
is a success, so it never reaches the failure door at all.

**Why answering it here is not this package minting an answer.** For N
children the answer is assembled from N answers only the settlement side
holds, which is why this package does not mint it. For N = 0 there is no
settlement to run and nothing to assemble: `[]` is the whole of the
index-ordered list. Refusing instead left a chart that mapped over a list
which happened to be empty this time failing on
`error.communication.invoke.<invoke_id>`, which is the outcome
`sb-ADR-0009` decision 8 exists to rule out.

Recorded from the operator's ruling on `sob-as0` (campaign 033, 2026-09-06),
and implemented by `sob-as0` in `StatifierOban.Invoke.FanOut` and
`StatifierOban.Invoke.Worker`.

## Note (2026-09-12): the failure lands on an execution

`statifier_persistence` ADR-0011 (proposed, campaign SF041) names the durable
record a chart's progress is persisted against an **execution**. This package's
prose moved to that word in `sob-mh3`; this record's Decision, its 2026-08-29
Amendment and both later Notes stand as written.

Where decision 5 has a host answering "is this run live?", where the
Consequences say the failure event fires and "the run leaves the invoking state
instead of hanging in it", and where the Amendment's consequences say "the run
can still be told", read *execution*. The rule is the same one: the terminal
attempt delivers `error.communication.invoke.<invoke_id>` behind the liveness
check the seam owes, and a chart that never hears about failed work is the
outcome this record exists to prevent.

Nothing in the failure vocabulary moves. The three classes and the
undecodable-payload arm are still what `StatifierOban.Invoke.Worker` maps onto,
and `c:StatifierOban.Invoke.Delivery.deliver_failure/3` keeps its shape
(`lib/statifier_oban/invoke/worker.ex` and
`lib/statifier_oban/invoke/delivery.ex`, read at `2ffc3b7`); the
`[:statifier_oban, :invoke, :failed]` event keeps its name and its `reason`,
`detail` and `attempts` keys (`lib/statifier_oban/telemetry.ex`,
`invoke_failed/7`, read at `2ffc3b7`).

`ADR-0011` is proposed and is not yet on `statifier_persistence`'s `main`, so
no line of it is cited here. Recorded by `sob-mh3` (campaign SF041).

## Note (2026-09-13): `telemetry.ex` moved after the cite above was read

The rule this line records: a read-at label on a merged record is never edited
in place. When a later commit touches a cited file, the record says so by
addition, names the commit, and reports whether the cite's anchor still
resolves at today's `main`.

The Note of 2026-09-12 above labels its `lib/statifier_oban/telemetry.ex` cite
"read at `2ffc3b7`". `sob-mh3`'s own PR (79) then changed that file at
`557ddf3`. The `2ffc3b7` label stays as written; what follows is the check.

The anchor still resolves. At `e3422bb`, `invoke_failed/7` is still defined in
`lib/statifier_oban/telemetry.ex`, still emits
`[:statifier_oban, :invoke, :failed]`, and still carries `reason`, `detail` and
`attempts` - `attempts` as a measurement, `reason` and `detail` as metadata
(`lib/statifier_oban/telemetry.ex`, `invoke_failed/7`, read at `e3422bb`).
`557ddf3` rewrote `@doc` and `@moduledoc` prose only, "run" to "execution",
and changed no event name, no measurement, no metadata key and no `@spec` in
that file. The claim the 2026-09-12 Note rests on therefore holds at
`2ffc3b7` and at `e3422bb` alike.

The same Note's other two cites,
`c:StatifierOban.Invoke.Delivery.deliver_failure/3`
(`lib/statifier_oban/invoke/delivery.ex`) and the failure-class mapping in
`lib/statifier_oban/invoke/worker.ex`, were not touched between `2ffc3b7` and
`e3422bb`; both anchors resolve unchanged (read at `e3422bb`).

The premise surface is `lib/statifier_oban/telemetry.ex` at `e3422bb`; the
event set itself is fixed by ADR-0006 and enumerated by that record's suite,
not here. Recorded by `sob-v9s` (campaign SF044).

## Note (2026-09-24): a timed-out attempt fails inside the worker, and its terminal attempt delivers `"run_crashed"`

`StatifierOban.Config` now takes a per-attempt run-time bound for each job
kind - `:invoke_timeout`, `:child_start_timeout` and `:timer_timeout`, in
milliseconds or `:infinity`, each defaulting to `:infinity` (`fetch_timeout/2`
in `lib/statifier_oban/config.ex`). `Oban.Worker.timeout/1` is handed only the
`%Oban.Job{}`, so the bound travels the way the delivery module already does:
the enqueue site writes it into the job's meta and the worker reads it back
off the row, and a row without it - every job stored before the option
existed - reads as `:infinity` (`StatifierOban.JobTimeout.bound/1`). This
Note records what a timed-out invoke attempt does, because the answer is not
the one Oban gives by itself.

**Why the bound is enforced inside the worker.** Oban enforces `timeout/1` by
killing the job process from outside (`Oban.Queue.Executor.start_timeout/1`
arms `:timer.exit_after/2`, in Oban 2.23). A killed process runs none of its
own code, so the rescue and catch arms decision 3 relies on never run, and
neither does `maybe_fail/7`: a terminal attempt killed that way would deliver
nothing, and a chart parked on `error.communication` would hang on it - the
outcome this record exists to prevent. So `StatifierOban.Invoke.Worker` runs
the handler's `run/1` (or `run/2`) under the bound itself: in a task linked
to the job process, waited on for at most the bound
(`call_bounded/4` in `lib/statifier_oban/invoke/worker.ex`). A call that
outlives it is killed and the attempt raises `Oban.TimeoutError` from inside
`perform/1`.

**What a timed-out attempt does.** It fails like a handler that raised. A
non-terminal attempt delivers nothing and retries (decision 2). The terminal
attempt delivers `error.communication.invoke.<invoke_id>` through the same
door with `"reason"` `"run_crashed"`, `:detail` the `Oban.TimeoutError`
message (which names the bound in milliseconds), and `:attempts` the terminal
attempt (decision 1), and the job is discarded with that error recorded.
**No new failure class, event name, function or error family is created**:
decision 3's `"run_crashed"` - "the terminal attempt raising or exiting" - now
also covers the terminal attempt running past its bound, because that is how
the attempt ends. A raise, exit or throw inside the task reaches the job
process unchanged, so a bounded handler that fails on its own still reports
exactly what it reported before.

**The backstop, and its limit.** The invoke worker's `timeout/1` returns the
bound plus 5000 ms (`timeout/1` in `lib/statifier_oban/invoke/worker.ex`), so
Oban's own kill still bounds the work around the call - the decode before it
and the delivery or fan-out enqueue after it - without firing before the
bound inside the worker does. An attempt the backstop kills delivers nothing,
for the reason above; that is a limit of this Note, not an oversight, and the
reopen trigger is a host whose delivery seam routinely outlives the margin.

**The other two bounds do not touch this record.** A child start job and a
fired-timer job have no failure door here, so `timeout/1` on those workers
returns the bound itself and Oban's kill is the whole enforcement: the
attempt fails with `Oban.TimeoutError` and retries, exactly as a raise out of
the seam it calls does.

**Nothing else in this record moves.** The terminal-attempt rule of decision
1, the non-terminal silence of decision 2, the string `:detail` of decision 4,
the seam of decision 5 and the environment-error limit of decision 6 are
unchanged, and so is the retry an unresolvable handler gets. With the
`:infinity` default no task is started and the handler runs in the job
process, as before. The code this Note describes arrives in the same change
as the Note, `sob-eh8`.

## Amendment (2026-09-24): an unresolvable handler may cancel and deliver, under `:unresolved_handler` `:cancel`

Status: proposed (2026-09-24, sob-nnp)

Decision 6 above says:

> **6. Only `run/1`'s own exhaustion delivers.** The environment errors -
> `:invalid_handler`, `:invalid_delivery`, `:invalid_codec`, `:codec_failed` -
> retry and can in principle exhaust too, but they say nothing about the
> invocation; they say the deploy is wrong.

**This Amendment reverses decision 6 for the `:invalid_handler` arm only,
and only under the new `:unresolved_handler` `:cancel` policy.** The
default is `:unresolved_handler` `:retry`, unchanged: an unresolvable
handler still retries to exhaustion and delivers nothing under it, exactly
as decision 6 describes, and decision 6's rationale for that default
stands - an unresolvable handler says the deploy is wrong, and retrying
keeps the invocation alive across a deploy that fixes it.

`:cancel` exists for a host that deploys handler code in a separate
release from the one that enqueues invocations: that host would rather
park the job than have it fight a retry backoff waiting for a handler
that has not shipped yet, and a deploy that adds the handler can
re-enqueue the invocation once it lands. Retrying such a job to
exhaustion also leaves the chart hanging for as long as the backoff
schedule takes to exhaust; cancelling tells it at once.

### Decision

**A fifth failure class, `"invalid_handler"`, for an unresolvable handler
under `:unresolved_handler` `:cancel`.** `:detail` is the handler name
exactly as stored on the row, a string per decision 4. `:attempts` is the
attempt that found the fault, not `max_attempts` - the same rule the
2026-08-29 Amendment gives for `"undecodable"` and the 2026-09-05 Note
gives for `"fan_out_refused"`: the attempt that cancels is the
invocation's last one. The job cancels with `{:invalid_handler, name}`,
the same error tag the retrying arm records
(`cancel_unresolved_handler/5` in `lib/statifier_oban/invoke/worker.ex`).

**No new event name, function or error family is created.** The class
is delivered through `c:StatifierOban.Invoke.Delivery.deliver_failure/3`,
behind the same liveness check, as
`error.communication.invoke.<invoke_id>`, and it emits
`[:statifier_oban, :invoke, :failed]` with `handler` `nil`, as the
`"undecodable"` class does, because the handler never resolved
(`cancel_unresolved_handler/5` in `lib/statifier_oban/invoke/worker.ex`).

**The delivery module must resolve first, and an unresolvable delivery
module still retries.** Decisions 5 and 6 already say `:invalid_delivery`
has no seam to deliver through; under `:cancel` a job whose handler and
delivery module are both unresolvable retries with `:invalid_delivery`
(`unresolved_handler/5` in `lib/statifier_oban/invoke/worker.ex`). Under
the default a job whose handler is unresolvable retries with
`:invalid_handler` whatever its delivery module does, as before. The
other environment errors decision 6 lists, `:invalid_codec` and
`:codec_failed`, are untouched.

**The policy is fixed at enqueue time and reads as `:retry` when
absent.** The option is `StatifierOban.Config`'s `:unresolved_handler`,
`:retry` or `:cancel` (`fetch_unresolved_handler/1` in
`lib/statifier_oban/config.ex`). It travels on the job's meta, as the
run-time bound of the 2026-09-24 Note does: `:retry` writes nothing, and
only a stored `"cancel"` reads as `:cancel`
(`StatifierOban.UnresolvedHandler`, `lib/statifier_oban/unresolved_handler.ex`),
so a job stored before the option existed retries.

### Consequences

A host whose handler code deploys on a different schedule from its
enqueueing code can choose to have an unresolvable handler park rather
than retry, and the chart still hears about it. A host that sets nothing
keeps exactly the behavior decision 6 describes.

Under `:cancel` a handler that is missing only briefly - a rolling
deploy in which one node runs the job before the module reaches it -
cancels an invocation a retry would have completed. That is the trade
the option names, and it is why `:retry` stays the default.

The reopen trigger is a host that needs `:invalid_delivery`,
`:invalid_codec` or `:codec_failed` to cancel rather than retry; neither
decision 6 nor this Amendment settles that. The code this Amendment
describes arrives in the same change as the Amendment, `sob-nnp`.
