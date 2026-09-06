# ADR-0007: Fan-out child starts are batched, and the concurrency bound is the runtime's

Status: accepted (2026-09-01, sob-djz; unqualified direction-agent verdict on the first review, campaign-026)

## Context

`statifier_blocks`' ADR-0009 (accepted 2026-09-01, campaign-026) adds a
durable fan-out block type, `core.map`: one invocation whose handler starts
N children, one per item, with the answers accumulated into one datamodel
location in item-index order. That record fixes what an author writes and
what the compiler emits, and it stops at two places on purpose.

Its decision 9 stops at the first:

> **The batching contract is `sob-djz`'s record and is not restated here.**
> How child starts are batched onto the queue, how the bound is enforced
> across a batch, and what happens to a batch spanning a restart are
> `statifier_oban`'s to decide and to state.

Its decision 8 stops at the second, and names two owners rather than one:

> Whether creating children is all-or-nothing within a batch is `sob-djz`'s
> and `sp-ADR-0008`'s to say, not this record's; this record only fixes what
> the block does with either answer.

This record answers both. It is the third of three that have to be read
together: `sb-ADR-0009` says what the author writes, `sp-ADR-0008` (with the
ordered-set amendment tracked as bead `sp-3n2`, not yet landed) says how N
children are linked and stepped, and this one says how their starts are
batched and bounded.

Three things constrain the answer before any preference does.

**The operator's `R26-6` fixes the shape.** The concurrency bound is
runtime-owned with a block-level hint the runtime clamps - a deployment
property, host-wins logic - and this package **batches child starts rather
than firing N at once**. `sb-ADR-0009` decision 9 states the hint half; the
batching half is what is left.

**A child start is a multi-run operation, and this family has no global
transaction for one.** `sp-ADR-0008`'s consequences say so in as many words,
of cascade cancel: it is "written to be idempotent and resumable rather than
atomic ... which is the same shape as every other durable operation here and
the only shape available without cross-run locking, which this package does
not have and does not want." Starting N children is the same shape as
cancelling N: N separate run records, each written under its own run's
exclusion (`sp-ADR-0004` decision 5), through a storage-adapter behaviour
that is deliberately adapter-agnostic and therefore cannot be assumed to
share a repo, let alone a transaction, with the host's Oban instance
(`ADR-0002`).

**Oban's batch insert does not carry Oban's uniqueness.** `Oban.insert_all/3`
maps the changesets to rows and hands them to `Repo.insert_all` with
`on_conflict: :nothing`; the unique-query path that `Oban.insert/2` runs
under an advisory lock is not reached (`Oban.Engines.Basic.insert_all_jobs/3`,
oban 2.23.1). ADR-0003's dedup key is enforced by exactly that path. So the
one API call that would make a batch atomic at the queue is also the one that
silently drops the idempotency guarantee at-least-once delivery is built on.

## Decision

**1. The runtime bound is the queue's, and the hint is honoured by batch
size.** `sb-ADR-0009` decision 9's runtime bound is, in this package, the
Oban queue concurrency limit the host already declares in its own Oban config
for the queue fan-out children run on (`ADR-0002`: the instance is the
host's). Nothing new is configured to express it and nothing new enforces it.

The two directions of the clamp fall out of that:

- **A hint above the queue's limit is clamped by the queue itself**, silently
  and with no code. Jobs sit `available` and are fetched at the limit, which
  is precisely the "clamped down silently rather than refused" that
  `sb-ADR-0009` decision 9 requires.
- **A hint below the queue's limit is the only case needing enforcement
  here**, and it is enforced by the batch size: at most `max_concurrency`
  child starts are outstanding at once, the next slice going out as earlier
  children land. An absent hint means one slice sized at the queue's own
  limit and no further enforcement.

**The bound is per-deployment, not per-block, and this is worth stating out
loud.** Two fan-outs running at once on the same queue share it, as do
ordinary invoke jobs on that queue. An author who writes `max_concurrency: 4`
has expressed the shape of the work - these children are expensive - and has
not reserved four lanes. A host that wants a fan-out isolated from its other
async work gives it its own queue, which is a deployment change and not a
document change, which is the whole point of decision 9 upstream.

**2. A batch is a scheduling unit, not a transaction.** This answers the
first half of `sb-ADR-0009` decision 8's question, and `R26-6` answers it
before preference does: if starts are batched rather than fired at once, then
between slice k and slice k+1 there exists a durable, observable state in
which some children of an invocation have started and others have not. A
fan-out is therefore **never** all-or-nothing across its batches, by
construction.

That state is not a defect to be hidden. It is the state `sb-ADR-0009`
decision 8's partial-fan-out arm already specifies behaviour for - under
`all`, a child that could not be created occupies its index as an error and
the batch continues; under `first_error`, it cancels the live siblings - and
it is the state `DS-c`'s retained cancelled records exist to make legible.

**3. Nor is a single batch all-or-nothing, and the reason is idempotency
rather than convenience.** This answers the second half. Within a slice,
child starts are made one at a time - a child run created through the storage
adapter, then one `Oban.insert/2` under decision 4's key - and an interrupted
slice leaves the children it got to started and the rest unstarted.

The alternative is a slice inserted with `Oban.insert_all/3` inside one
transaction. It is rejected on the context's third fact: that call does not
apply Oban's unique option, so an atomically-inserted slice would be a slice
with no dedup key, and a replayed batch would start every child a second
time. Trading idempotency for atomicity is the wrong way round here, because
**idempotency is what makes non-atomicity harmless** and atomicity would not
make the operation safe on its own: the child-run creation half lives behind
`sp-ADR-0003`'s adapter behaviour, which no Oban transaction reaches.

`sp-ADR-0008` has already ruled this shape for the multi-run operation it
built - idempotent and resumable rather than atomic, for want of cross-run
locking the package does not want - and this record adopts that ruling for
starts rather than minting a second answer for the same question.
`sb-ADR-0009` names this record and `sp-ADR-0008` as joint owners; the sob
half is decided here, and the sp half is `sp-3n2`'s amendment to state in its
own terms. **If that amendment lands a transactional child-creation
guarantee, this decision reopens** - that is its reopen trigger, and the
only one it has.

**4. The per-child dedup key is ADR-0003's, plus the item index.** ADR-0003
keys an invoke job on `{scope, invoke_id, macrostep}`. N children of one
fan-out share all three: they are one invocation, planned in one macrostep.
The fan-out start job's key is therefore the four-component
`{scope, invoke_id, macrostep, index}`, `index` being the item's position in
`items` - the same integer `sp-3n2` puts on the child run's metadata.

ADR-0003's three-component key is unchanged for every other invoke job, and
this is an extension for fan-out starts rather than an amendment to it. The
index is a key component and not row data for the reason ADR-0003 gives for
the macrostep: it is what makes two legitimately different scheduling
decisions distinguishable, and without it a replayed slice would conflict
with a sibling instead of with itself.

The property that key buys is the whole of decision 3's safety: **re-running
an interrupted slice starts only the children that are missing.** The ones
already started conflict, `job.conflict?` set, exactly as a replayed timer
insert does today - the same scheduling decision, not a new one.

**5. Progress is derived from the linkage set, never from a batch cursor.**
This is the "what happens to a batch spanning a restart" half of decision 9's
question. There is no batch row, no cursor, and no per-fan-out scheduler
state of this package's own. The resumable unit is the difference between the
indices of `items` and the indices already recorded in the invocation's
ordered linkage set (`sp-3n2`), and resuming a fan-out is recomputing that
difference and enqueueing the missing indices under decision 4's key.

A cursor was the obvious alternative and it loses twice: it is a second piece
of durable state to keep consistent with the linkage set that is already
authoritative, and it is wrong precisely when it matters, because a crash
between "child created" and "cursor advanced" leaves it lying. The linkage
set cannot lie about a child it does not contain.

**6. Refill is driven by completions arriving at the existing doors.** A
slice is topped up when children land, on the parent's ordinary step - the
`done.invoke` and failure doors `sp-ADR-0007` already built and
`sp-ADR-0008` decision 3 already routes children through. No polling job, no
timer, and no supervisor process belonging to this package. A completion
delivered twice - which at-least-once permits - may not start a child twice,
and does not, because decision 4's key makes the second enqueue a conflict.

**7. Batching may reorder execution freely; it may not reorder results.**
Slices are cut as contiguous ranges of item indices and enqueued in index
order, but nothing about execution order is promised: Oban fetches at the
queue's limit, children take unequal time, and a resumed fan-out enqueues its
gaps in whatever order it finds them. This is compatible with `sb-ADR-0009`
decision 5 by construction, because the accumulated list is ordered by the
index the child carries on its own metadata (`sp-3n2`) and never by arrival.
Stating it is the point: it is the guarantee `sb-ADR-0009` says is its only
dependency on this record.

**8. No numeric cap on N is set here, and a host's cap refuses on the
ordinary error route.** `sb-ADR-0009` decision 7 point 4 sends the question
of a cap to the runtime - "if a bound is needed, it is the runtime's to
enforce and to refuse against". This record declines to pick a number, for
the same reason that record declines to: the honest limit is a property of a
deployment's queue and database, not of this package. A host that measures
one configures it, and a fan-out exceeding it is a **failure of the
invocation**, carried on `error.communication.invoke.<block id>` with
`st-ADR-0068`'s payload, not a compile finding and not a validation finding.

**9. No telemetry event is minted here.** ADR-0006's event set is unchanged
by this record. What a batched fan-out emits - whether a slice is an event,
whether the bound being reached is one - is a question for the campaign that
implements it, against working code, and inventing the names now would put
six strings into `docs/telemetry.md` that nothing emits.

## Consequences

The three records now compose without a gap: an author writes `core.map` with
an optional `max_concurrency` hint, `sp-ADR-0008`'s ordered set links and
steps the children, and their starts go out in slices bounded by the smaller
of the hint and the host's queue limit, keyed per index, resumable from the
linkage set alone.

**A fan-out is observably partial while it runs, and after a crash.** That is
decision 2's cost, stated where a host will read it: a query over the linkage
set mid-fan-out sees fewer children than `items` has items, and so does a
query after a node died mid-slice. The difference between the two is not
visible from the linkage set, and nothing here makes it visible. What makes
the second case safe is that the parent is stepped again and the difference
recomputed, not that it can be distinguished from the first.

**The four-component key is a second shape of invoke job key**, and a host
reading job rows to build its own dashboards now sees two. That is a real
cost of decision 4 and the alternative was worse: reusing the three-component
key would make N-1 of every N children a conflict against their own sibling,
which is a silent fan-out of one.

**Decision 1 buys its clamp by inheriting the host's queue semantics, which
this package does not control.** A host that pauses the fan-out queue pauses
every live fan-out, and a host that scales it changes the bound under
in-flight work. Both are correct - the bound is the deployment's, which is
`R26-6` - and both mean the effective concurrency of a run is not a property
of the document that produced it. An author who reads `max_concurrency: 4`
and expects four for the run's whole life will be wrong on a rescaled queue.

**Nothing here is implemented.** Campaign 026's `R26-1` defers the
implementation; this record carries no `lib/` change and no test. It depends
on `sp-3n2`, which is filed and unlanded - decisions 4, 5 and 7 name the
ordered set and the per-child index as though they exist, and they do not
yet.

The reopen triggers are two, both named above: `sp-3n2` landing a
transactional child-creation guarantee (decision 3), and a version of Oban in
which `insert_all/3` applies unique options, which would make the atomic
slice rejected in decision 3 available without its cost.

## Note (2026-09-05): the bound is the queue's alone, and a hint below it is not honoured

Decision 1's second bullet (`:74`) said a hint **below** the queue's limit
"is the only case needing enforcement here", enforced "by the batch size:
at most `max_concurrency` child starts are outstanding at once, the next
slice going out as earlier children land." That sentence is reversed by
this Note. **All N start jobs are enqueued up front. There are no slices,
and a hint below the queue's limit is not honoured.**

Two facts found while implementing the record did it, and neither was
visible when it was written.

**Decision 6's refill has no trigger.** Refill was to be driven by
completions arriving at "the `done.invoke` and failure doors". Those doors
*complete the invocation*: `sp-ADR-0007` decision 2 builds
`done.invoke.<invoke_id>` and steps it, a compiled `core.map` carries one
`<invoke>` and one `done.invoke` transition (`sb-ADR-0009` decision 3), and
the core removes the `active_invocations` entry on exit. Under the shipped
code the *first* child to finish would complete the whole map block, and a
non-final child completion has no parent step to ride. So there is no door
at which slice k+1 could go out. Building one means a re-dispatch of the
invocation on every settlement, which is the parent-driven refill the scale
walk (`R31-11`) declined to pull forward.

**The bound the record actually wanted is already enforced without
slicing.** Decision 1's first bullet is the whole mechanism: jobs sit
`available` and the queue fetches them at its own limit. That is true of N
jobs exactly as it is of a slice of them. Slicing changes when a row is
*written*, not how many children *run*; the concurrency ceiling is the
queue's either way. What slicing bought was a hint *below* the queue limit
having an effect, and it bought it with durable state (a refill trigger, a
resumable notion of "outstanding") that decision 5 spent its argument
refusing.

So `max_concurrency` is **shape-validated and clamped in both directions**:
above the queue's limit the queue clamps it, silently and with no code
here, exactly as the first bullet says; below it, it is accepted and not
honoured. `sb-ADR-0009` decision 9's "clamped down silently rather than
refused" still holds - the value the runtime uses is still never larger
than the author asked for a *deployment* to run, because a hint has never
reserved lanes (decision 1's own "the bound is per-deployment, not
per-block"). What an author loses is the ability to make a fan-out slower
than its queue allows, and the honest answer to that need was always
decision 1's: give the fan-out its own queue, which is a deployment change.

Decisions 2, 3, 4, 5, 7 and 8 are unchanged and this Note leans on them.
Decision 4's four-component key is what makes enqueueing N up front safe to
replay; decision 5's "progress is derived from the linkage set, never from
a batch cursor" is *more* true with no batch to cursor over; decision 7's
"batching may reorder execution freely" now reads as the queue's fetch
order, which was always what it described. Decision 2's observably-partial
fan-out survives too: N inserts are not one transaction, so a crash
mid-enqueue still leaves some indices started and others not, and the
resume is decision 5's difference against the linkage set.

**Decision 6 is superseded in full**, not amended: with everything enqueued
up front there is nothing to refill, so the completion doors carry no
scheduling duty at all. The idempotency argument it ended on is retained
elsewhere - a completion delivered twice cannot start a child twice, because
decision 4's key makes the second enqueue a conflict.

Recorded from the operator's `R31-11` (campaign 031, 2026-09-05), taken
from the fan-out scale walk, and implemented by `sob-q3y` in
`StatifierOban.Invoke.FanOut`.

## Note (2026-09-05): the cap gets a number, and the seam it needs

Decision 8 declined to pick a number for the cap and left it to a host
that measures one. Two things the record left open are settled here by the
operator's ruling `R31-9` (campaign 031, 2026-09-05), taken from the same
fan-out scale walk as Note 1's `R31-11`, because the implementation cannot
proceed without them.

**The cap is a `StatifierOban.Config` key, `:max_fan_out`, defaulting to
`1_000`.** A default is not a measurement, and this one does not pretend
to be: 1,000 is the largest N anything in the three records has reasoned
about, and a host that measures its own deployment raises or lowers it.
What the default buys is that a fan-out of a hundred thousand items fails
loudly on its first run rather than silently taking the database with it.
The refusal is decision 8's, unchanged: the invocation fails on
`error.communication.invoke.<invoke_id>`, with the count and the cap in the
event's `detail`, checked **before the first child start** so a refused
fan-out starts nothing at all. The compiler still validates nothing about
N, and cannot: `items` is a datamodel path the handler evaluates.

**Child runs are created through a host-wired seam, not by this package.**
Nothing here depends on `statifier_persistence`, and decision 3's child-run
creation "lives behind `sp-ADR-0003`'s adapter behaviour, which no Oban
transaction reaches". So a start job reaches it the way a completed invoke
reaches its run: through a module the host names in its config.
`:child_starter` is that seam, beside `:invoke_delivery`, and its callback
takes the parent run id, the effect, the index and the count. A host
running `statifier_persistence` wires the start-with-index function that
package ships for this; a host with its own run store wires its own.

Recorded from the operator's `R31-9` (campaign 031, 2026-09-05), taken from
the fan-out scale walk, and implemented by `sob-q3y` in
`StatifierOban.Config` and `StatifierOban.Invoke.FanOut`.
