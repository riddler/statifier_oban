# ADR-0006: Telemetry events for the durable seams

Status: accepted (2026-09-01, sob-43q; unqualified direction-agent verdict, campaign-025) - amended 2026-09-06 (sob-28m, PR 72: the fan-out seam mints three events, count eleven to fourteen)

## Context

statifier-ex records the family's observability design in
`st-ADR-0062` (the OpenTelemetry bridge is one separate package,
`opentelemetry_statifier`, consuming public `:telemetry` events only) and in
`docs/opentelemetry.md`, whose "What lands where" table assigns
*sibling-package telemetry surfaces and their bridge halves* to "each sibling
repo's own ADR, bridged in `opentelemetry_statifier`". This is that ADR for
this package. The full contract - every event, its measurements, its metadata,
and what the bridge does with it - is `docs/telemetry.md`; this record fixes
the decisions that document rests on.

Today this package emits no `:telemetry` events at all. Two other surfaces
already report on its work, and the design question is what is left over:

- **Oban instruments the job.** `[:oban, :job, :start | :stop | :exception]`
  carry the whole `%Oban.Job{}` - `worker`, `queue`, `args`, `attempt`,
  `max_attempts`, `meta`, `id`, `state`, `scheduled_at`, `errors` - plus
  `:duration`, `:queue_time`, `:memory` and `:reductions`. The engine family
  covers the writes, `[:oban, :engine, :insert_job]` and
  `[:oban, :engine, :cancel_all_jobs]` included.
- **statifier-ex instruments the effect.**
  `[:statifier, :session, :effect, :send_delayed]` already fires when the
  chart decides to arm a delayed send, carrying `delay_ms`, `ordinal`,
  `send_id`, `target`, `caller_context` and the position triple;
  `[..., :effect, :cancel]` and `[..., :effect, :invoke]` do the same for the
  other two.

What neither can say is anything about the *durable* step between them:
whether the effect became a row, whether the insert conflicted with a
replayed one, which statechart identity a given opaque row belongs to, and
how a job ended in the vocabulary the SCXML spec uses rather than the one
Oban uses. The last is the sharpest gap: a fired timer whose run is no longer
live is discarded per spec 6.2, and the worker returns
`{:cancel, {:discarded, reason}}`, which Oban reports as
`[:oban, :job, :stop]` with `state: :cancelled` - a *stop*, with the reason
buried inside `:result`. The spec-mandated drop of an event nobody will ever
see is the single most useful thing in this package to be able to count, and
today it is indistinguishable from an operator cancelling a job by hand.

Two constraints bound any answer. `st-ADR-0062` and the bridge's own
`ots-ADR-0002` require that a data gap be fixed by the emitting package
gaining a field, never by the bridge reaching into internals; and
`st-ADR-0062` bridges siblings as separate per-library `setup` calls in the
one bridge package, which `ots-ADR-0003` implements by attaching one handler
per event name. A sibling whose event list cannot be read off a function is
therefore a list the bridge has to hand-copy and keep in sync by hand.

## Decision

**1. This package emits `:telemetry` events and never touches an
OpenTelemetry API.** Span creation, handler attachment, context restoration
and the span table are `opentelemetry_statifier`'s, per `st-ADR-0062`. This
package takes no `opentelemetry_api` dependency in any environment. Its half
of the bridge is a specification obligation - that the events carry
everything the bridge needs - discharged by `docs/telemetry.md`.

**2. The event contract covers three things and nothing else: the durable
write and whether it was new, the statechart identity behind an opaque job
row, and the spec-level verdicts.** Concretely: the scheduling seam
(`Timer.schedule/3`, `Timer.cancel/3`, `Invoke.Handler.perform_start/3`,
`Invoke.Handler.perform_cancel/3`) and the delivery seam
(`Timer.Worker.perform/1`, `Invoke.Worker.perform/1`, including the
terminal-attempt failure path). Eleven events, listed with their
measurements and metadata in `docs/telemetry.md`.

Duration, attempts, retries, snoozes, queue latency and exceptions are
Oban's and are not re-emitted. The chart's decision to arm, cancel or invoke
is statifier-ex's and is not re-emitted. The host's own `run/1` or `run/2` is
the host's and is not wrapped: the enclosing job span already bounds it, and
this package knows nothing about what happens inside it.

**3. The prefix is `[:statifier_oban, ...]`, fixed and not configurable.**
Upstream reserves its second segment (`:session`) for the logical SCXML
session, and nothing here is scoped to one: a scheduling call runs on the
caller, a worker runs days later on another node, and the scope may not be a
session id at all. A per-package prefix is also what a separate per-library
bridge `setup` call implies, the way `opentelemetry_ecto` and
`opentelemetry_oban` compose. It is not configurable because the bridge must
name the events at compile time; a per-host prefix would make its attach list
depend on host configuration it cannot see.

**4. `StatifierOban.Telemetry` owns the names, built from literal atoms, with
`events/0` returning all of them.** One definition site, module attributes
holding literal atoms, and no name segment ever derived from a module name at
runtime. This is what makes the list enumerable ahead of a call, which is
what `ots-ADR-0003`'s attach-per-event-name mechanism needs and what
`Statifier.Telemetry.events/0` already sets as the family's precedent;
Credo's `UnsafeToAtom` rules out the runtime-derived alternative
independently. The family's `Statifier.Telemetry` conventions are adopted
with it: measurements are numbers and metadata is everything else
(integer-valued indexes included), and the moduledoc carries a table per
event family. To those this ADR adds an explicit amendment discipline,
modeled on how
`st-ADR-0040` is actually kept - a long list of dated in-place amendments
rather than successor records: adding a measurement or metadata key to an
existing event is an amendment and is fine; renaming or removing one, or
renaming an event, is breaking and needs a new ADR.

**5. Every event is a single point-in-time event; there are no `:start` /
`:stop` pairs.** This package owns no interval that Oban does not already
own. The schedule and cancel calls are single writes; the fire and run
intervals are the job's, already spanned by `[:oban, :job, :start | :stop]`
and, for a host running `opentelemetry_oban`, already a span. Bracketing them
again would produce two timings for one interval. Every event therefore
measures `system_time`, plus whatever numbers are genuinely its own -
`delay_ms`, `count`, `attempt` and `attempts`.

In particular there is **no lateness measurement**, though how far past its
due time a timer actually fired is the number a durable timer most wants to
make answerable. Oban already publishes it: `:queue_time` on
`[:oban, :job, :stop]` is `attempted_at - scheduled_at` in nanoseconds
(`Oban.Queue.Executor`), the same subtraction against the same two
timestamps this package would perform. Adding it here would be precisely the
duplication decision 2 rules out. Its one limitation is Oban's either way -
a retry rewrites `scheduled_at`, so past the first attempt neither number is
lateness any more, and the original due time is not on the row to recover.

**6. The identity key is `scope`, not `session_id`; the bridge maps it.**
`StatifierOban.Timer.Key` is explicit that the scope is `ctx.session_id` for
a live session *or the host's own durable run id* for a process-less host,
and calling a run id `session_id` would be a lie on exactly the hosts this
package exists for. The bridge maps `scope` onto `statifier.session_id`,
because that is the attribute it keys per-session correlation on and a
durable timer it could not stitch to the run's macrostep spans would be
useless. The rename happens once, in the bridge, where the mapping is
visible.

**7. `caller_context` rides on the scheduling and delivery events as opaque
row data, and this package never reads it.** `st-ADR-0063` makes it an opaque
host slot; the library carries it, this package already round-trips it
through the job args and back onto the fired effect, and the OTel-shaped
reading of it is the bridge's. Its presence on the delivery-seam events is
what lets a timer firing hours later **link** back to the trace that
scheduled it rather than being parented by it - a three-day span held open
under a request is not a trace anyone wants. `nil` means no context was
attached and the fire is simply unlinked.

The mechanics of restoring an OTel context from it are deliberately out of
scope here and belong to `sob-v28` (mirroring the closed `st-yoi0`). This ADR
fixes the seam - the field is on the effect, it round-trips, it is on the
event - and leaves what travels through it to that bead.

**8. There is no configuration knob, and no sampling knob.** Emission is
unconditional: `:telemetry.execute/3` on an event with no handlers is a
lookup and a return, so the cost of nobody listening is already nil. There is
no `StatifierOban.Config` option to disable it, consistent with ADR-0002's
rule that every option this package carries is a seam a host must state
explicitly - and a switch that only makes a cheap thing cheaper is not a
seam. Upstream's `trace: true` gate has no counterpart because none of these
events scale with microstep count.

**9. Nothing host-opaque and nothing from the datamodel is ever on an
event.** The effect's `data`, `params` and `content` are never emitted - not
truncated, not hashed, not "just the keys." Upstream's
`record_datamodel_values` opt-in has no counterpart here, because with a
codec configured this package cannot read those fields even in principle.
`caller_context` is the single unbounded value, present for the bridge alone,
and no consumer may fold it into a metric dimension.

## Consequences

- A host gets, for the first time, a countable answer to "how many timers
  fired into a dead run" and "how many replayed inserts conflicted" - the two
  numbers that say whether the durable-timer design is working. Both are
  plain `:telemetry`, so `Telemetry.Metrics` reaches them with no
  OpenTelemetry anywhere.
- The bridge stays a translator. Every field it needs is on an event, so the
  rule that it never reads `oban_jobs.args` or `StatifierOban.Timer.JobArgs`
  is enforceable rather than aspirational; and if a gap is found, the fix is
  an amendment here, which decision 4's discipline already covers.
- A host running both `opentelemetry_oban` and this bridge gets the intended
  nesting for free: the delivery-seam events land inside the Oban job span
  already open in the same process, by ordinary ambient context, and the link
  to the scheduling trace comes from `caller_context`. Nothing in either
  package has to know about the other.
- `StatifierOban.Telemetry` becomes public API: its event names,
  measurements and metadata keys are as public as a function signature and
  are frozen under decision 4's amendment discipline. That is a real cost -
  eleven more names this package cannot rename freely - and it is the cost of
  a bridge that can attach without hand-copying.
- Going first sets a precedent. `statifier_persistence` has not yet landed
  its half (`sp-i21`), so the per-package prefix in decision 3 and the
  `Telemetry.events/0` shape in decision 4 will be what the next sibling
  reads as the family pattern. That is intended, but it means a sibling with
  a genuinely different shape should say so rather than copying this one out
  of deference.
- Risk accepted: the discard reason vocabulary is open. The delivery seams'
  `t:discard_reason/0` is `term()` because a host answering liveness from its
  own run store names the not-live case whatever it likes, so `reason` on the
  two `:discarded` events is bounded only by host convention. A host that
  returns a per-run struct there will blow up the cardinality of any metric
  dimensioned on it. Narrowing the type is a change to the delivery
  behaviour, not to this contract, and this ADR does not make it.
- Rejected alternative: emitting nothing and letting the bridge read
  `%Oban.Job{}` metadata off Oban's own events. It would need no new surface
  at all - the job row is in `[:oban, :job, :stop]`'s metadata - but it would
  make the bridge a parser of `StatifierOban.Timer.JobArgs`, decode
  codec-encoded fields it has no key for, and still not answer `conflict?` or
  the discard reason, neither of which is on the row. `st-ADR-0062` decision
  4 forbids the approach independently of whether it would have worked.
- Rejected alternative: bracketing `handler.run/1` with a `:start` / `:stop`
  pair to give host work a span. It is the one interval here that is neither
  Oban's nor trivial, but it is also entirely the host's code, and a host
  that wants it can instrument its own handler with better names than this
  package could invent. `[:oban, :job, :stop]` already bounds it.

## Note (2026-09-01): `:queue_time` is delivered in native time units

Decision 5 describes Oban's `:queue_time` on `[:oban, :job, :stop]` as
"`attempted_at - scheduled_at` in nanoseconds (`Oban.Queue.Executor`)", and
`docs/telemetry.md` said the same. That is the computation, not the unit a
handler receives. `Oban.Queue.Executor.record_finished/1` (Oban 2.23.1) takes
that difference with `DateTime.diff/3` at `:nanosecond`, floors it at zero,
and then passes it through `System.convert_time_unit(:nanosecond, :native)`
before the measurement is put on the event - so `:queue_time` arrives in
`:native` time units, exactly as `:duration` does. Oban's own default logger
converts both back
(`System.convert_time_unit(value, :native, :microsecond)`) before printing
them, which is the tell.

A consumer that reads the raw measurement as nanoseconds is right only by
accident of the BEAM's native time unit being one nanosecond on the platforms
this package is developed on. It is not guaranteed, and any host converting
`:queue_time` for a metric should name `:native` as the source unit.

Nothing above moves. Decision 5's reason for having no lateness measurement
is that Oban performs the same subtraction against the same two timestamps,
which is unaffected by the unit the result is reported in, as is the caveat
that a retry rewrites `scheduled_at`. `docs/telemetry.md` has been given the
matching one-word precision in the same change; no event, measurement, or
metadata key in this record changes, so this is a precision Note rather than
an amendment under decision 4.

## Amendment (2026-09-06): the fan-out seam mints three events

Status: accepted (2026-09-06, sob-28m; see the Note below)

Decision 2 above scopes the contract to two seams and counts the result:

> Eleven events, listed with their measurements and metadata in
> `docs/telemetry.md`.

There is a third durable seam it does not name, because it did not exist when
this record was written. ADR-0007 added the fan-out: a `core.map`-shaped
invocation becomes one fan-out job, N child start jobs under it, and - under
`first_error` - a cancel of the starts that have not run. Its decision 9
deliberately minted no event name, and left the question to "the campaign that
implements it, against working code". The code now exists, and this amendment
is that answer.

Each of the three is a durable write or a durable verdict this package makes
and nothing else reports:

- the fan-out arm of `StatifierOban.Invoke.Worker` completes **without
  delivering** (ADR-0007), so `[:statifier_oban, :invoke, :delivered]` never
  fires for it. The largest thing this package does for an invocation - storing
  N rows - is the one thing its event stream is silent about;
- `StatifierOban.Invoke.ChildStartWorker` runs later, usually on another node,
  and emits nothing, so the bridge has no per-child event to open a linked root
  on and a child run's own spans have nothing to nest under;
- `StatifierOban.Invoke.FanOut.cancel_unstarted/3` cancels the unstarted half of
  `sb-ADR-0009` decision 6's `first_error` sweep and emits nothing, so a trace
  reports no cancelled siblings at all while the run's datamodel holds one
  cancelled entry per cancelled index. The two numbers disagree, and only one of
  them is wrong.

**This record therefore adds three event names, and decision 2's count moves
from eleven to fourteen.** Adding a name is additive under decision 4's
discipline - nothing is renamed, nothing is removed, no existing event changes
its measurements or its metadata - so it is an amendment rather than a successor
record, and `StatifierOban.Telemetry.events/0` remains the single enumerable
definition site the bridge attaches from.

| Event | Emitted from | Measurements | Metadata |
|---|---|---|---|
| `[:statifier_oban, :invoke, :fan_out]` | `Invoke.Worker`'s fan-out arm, after every start is enqueued | `system_time`, `count` | `scope`, `invoke_id`, `handler`, `policy`, `queue`, `job_id`, `caller_context` |
| `[:statifier_oban, :invoke, :child_started]` | `Invoke.ChildStartWorker.perform/1`, after the `ChildStarter` seam returns `:ok` | `system_time`, `attempt` | `scope`, `invoke_id`, `index`, `count`, `job_id`, `caller_context` |
| `[:statifier_oban, :invoke, :unstarted_cancelled]` | `Invoke.FanOut.cancel_unstarted/3`, after the sweep | `system_time`, `count` | `scope`, `invoke_id` |

**They are `:invoke` events, not a fourth `[:statifier_oban, :fan_out, ...]`
family.** Decision 3 fixes the prefix at two segments and leaves the third to
name the kind; a fan-out is one invocation, answered once, and splitting its
events across two families would make a bridge attach twice and correlate what
it already had under one `invoke_id`.

**`count` is a measurement on two of them and metadata on the third, and the
split is decision 4's, not an inconsistency.** On `:fan_out` and
`:unstarted_cancelled` the count is the number the call itself produced - N
starts enqueued, N starts cancelled - which is exactly the status `count` has on
`[:statifier_oban, :timer, :cancelled]` and `[:statifier_oban, :invoke,
:cancelled]` today, and `0` is data there for the same reason. On
`:child_started` the pair `index` and `count` is the child's **position** in its
fan-out rather than a quantity that event produced, and decision 4 adopts
upstream's convention of carrying integer-valued positions as metadata -
`ordinal` already rides that way on every timer event.

**`handler` is on `:fan_out` alone.** Not out of thrift: neither of the other
two has one to report. `ChildStartWorker` reads the handler *name* off the job
row and never resolves it to a module - resolution is the answering worker's,
and a start job has no reason to load it - and `cancel_unstarted/3` is handed
the config, a scope and an invoke id, and no handler at all. Putting a string
where every other event's `handler` is a module would be worse than the
absence. The bridge already has the module from
`[:statifier_oban, :invoke, :enqueued]` and from `:fan_out`, both keyed by the
same `invoke_id`.

**`:child_started` is delivery-shaped though it delivers nothing.** It is
emitted inside the job, on the node that ran it, and carries the job's own
`attempt` exactly as `:fired` and `:delivered` do - a start that succeeded on
its third attempt is a different fact from one that succeeded on its first. What
it is not is an answer: ADR-0007 is explicit that a child start never delivers
into the run, and this event does not make it look as though it did. It carries
`caller_context` for decision 7's reason and no other: it is what lets the
bridge open a **linked** root per child, so the child's own creation is reachable
from the trace that armed the fan-out without hanging under it for the fan-out's
whole life.

**Decision 9 holds unchanged.** Nothing host-opaque reaches these events. The
handler's `items` list is never read here - `count` is its length and `index` is
a position in it - `policy` is the two-word vocabulary `:all | :first_error`
read off the invocation's `on` parameter, and the effect's `data`, `params` and
`content` are as absent as they are everywhere else in this contract.

**Cardinality.** `count` and `index` are bounded by `StatifierOban.Config`'s
`:max_fan_out` (ADR-0007's second Note), which is a deployment's number rather
than traffic; `policy` has two values. `index` is nonetheless a **position, not
a dimension**: a host that folds it into a metric label gets one series per
child of every fan-out, which is precisely the unboundedness the rest of this
contract avoids. `job_id` and `caller_context` keep the status the Cardinality
section already gives them.

**Still deliberately absent.** A child *settling* is not this package's fact -
the settlement side owns it, and `sb-ADR-0009` decision 6 is where its
vocabulary lives. A start job's `{:error, _}` retry is Oban's
`[:oban, :job, :exception]`, under decision 2's rule that retries are not
re-emitted. A fan-out **refused** before it starts already fires
`[:statifier_oban, :invoke, :failed]` with the `"fan_out_refused"` reason
ADR-0005's 2026-09-05 Note added, so no fourth name is needed for it; an empty
fan-out answers through the ordinary done door and fires `:delivered`, per
ADR-0005's 2026-09-06 Note. In both cases the existing event is the right one
and a second would double-count.

**How `:fan_out` gets its numbers.** `count`, `policy` and `queue` are all
decided inside `StatifierOban.Invoke.FanOut.start/5` - the cap is applied there,
the `on` parameter is read there, the queue comes off the config there - while
`job_id` and `caller_context` exist only on the worker, which is where decision
2's seam rule puts the emission. Re-deriving the first three at the call site
would mean reading the `on` parameter a second time, and a second reading is a
second thing that can drift from the policy the child jobs were actually
enqueued under. So `start/5`'s success return carries them instead: `:ok` becomes
`{:ok, %{count: n, policy: p, queue: q}}`. That is a breaking change to one
public return in a 0.x minor, and it is recorded here because this event is its
only cause. `{:empty, []}`, `{:refused, _}` and `{:error, _}` are untouched, and
ADR-0005's Note naming `{:empty, []}` still reads true.

**Reopen trigger.** A fan-out whose children are scheduled in slices rather
than all up front - ADR-0007 decision 2's batching, which the shipped code does
not do - would make "the fan-out was dispatched" a repeated fact rather than a
single one, and `:fan_out` would need either an occurrence per slice or a
companion name. Nothing here anticipates that shape; the campaign that ships it
amends this table again.

## Note (2026-09-06): the amendment above is accepted

The fan-out amendment merged at `proposed` in PR 72, rebased onto main as
`3652db8` and `c9046ed`, because a status claim cannot precede the verdict
that justifies it. This Note records that verdict and the flip, taken by
the separate gated PR consent clause 11 asks a flip to take.

The direction review ran two cold passes. Pass 1 returned QUALIFIED with
three findings, all record-prose and none blocking; the cure `d1c7f38`
answered them in-branch; the scope-frozen pass 2, a fresh cold agent,
returned UNQUALIFIED with zero findings.

Every claim the amendment makes was re-verified against `main` at
`c9046ed` before this flip, not against the code as it stood when the
amendment was written: `StatifierOban.Telemetry` defines the three names
with exactly the measurements and metadata the amendment's table gives
them; `events/0` returns fourteen names, five `:timer` and nine
`:invoke`; the three emission sites are the ones the table names
(`Invoke.Worker`'s fan-out arm, `Invoke.ChildStartWorker.perform/1` after
the `ChildStarter` seam returns, and `Invoke.FanOut.cancel_unstarted/3`
after the sweep); `FanOut.start/5` returns `{:ok, %{count: n, policy: p,
queue: q}}` on success with `{:empty, []}`, `{:refused, _}` and
`{:error, _}` untouched; and `docs/telemetry.md` carries the matching
fan-out section and its own count of fourteen. Nothing above moves.

The head Status line gains the `- amended 2026-09-06 (...)` suffix in the
same change, in the shape ADR-0005's head line already carries.
