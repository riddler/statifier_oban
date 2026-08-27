# Host-Pluggable Codec for Opaque Job Args Implementation Plan

## Overview

Give the host one seam to transform the bytes of the four host-opaque job-arg
payloads - a `%SendDelayed{}`'s `data` and `caller_context`, an
`%Invoke{}`'s `params` and `content` - on the way into `oban_jobs.args` and
back out again, so a host carrying sensitive values in its datamodel can
protect them at this boundary. The seam is a behaviour the host implements
(`encode/1`, `decode/1`, both over `binary()`, byte-identical round trip); this
package never learns what the transform is or what it is for.

The default stays exactly today's behaviour: no codec configured means the
stored payload is byte-for-byte the `%{"t2b64" => base64}` envelope this
package already writes, so every row stored before the upgrade keeps decoding.

Beads issue: `sob-d7i`

## Current State Analysis

`StatifierOban.OpaqueTerm` (`lib/statifier_oban/opaque_term.ex`) is the single
encoding both job kinds share:

- `encode/1` returns `nil` for `nil`, otherwise
  `%{"t2b64" => Base.encode64(:erlang.term_to_binary(term))}`
  (`lib/statifier_oban/opaque_term.ex:26-30`).
- `decode_field/2` reads the field, matches the `"t2b64"` tag, Base64-decodes,
  and `:erlang.binary_to_term(binary, [:safe])` inside a `rescue ArgumentError`
  that returns `{:error, {:invalid_field, field, term}}`
  (`lib/statifier_oban/opaque_term.ex:41-73`). Errors are data about the row,
  never raises.

There is no seam of any kind between the term and the bytes. The four opaque
fields are encoded, not protected:

- `lib/statifier_oban/timer/job_args.ex:53,66,145` (`data`, `caller_context`)
- `lib/statifier_oban/invoke/job_args.ex:65-66,97-98` (`params`, `content`)

The two enqueue sites are the only places that hold a `%Config{}`:

- `StatifierOban.Timer.schedule/3` (`lib/statifier_oban/timer.ex:57-73`) calls
  `JobArgs.from_effect/2` and inserts.
- `StatifierOban.Invoke.Handler.perform_start/3`
  (`lib/statifier_oban/invoke/handler.ex:203-219`) calls
  `JobArgs.from_invoke/3` and inserts.

The two decode sites - `StatifierOban.Timer.Worker.perform/1`
(`lib/statifier_oban/timer/worker.ex:60-69`) and
`StatifierOban.Invoke.Worker.perform/1`
(`lib/statifier_oban/invoke/worker.ex:82-92`) - hold **no** `%Config{}`. Both
already solve exactly this problem for another module reference: the delivery
module is written as a string at enqueue time (`Atom.to_string/1`) and resolved
back in the worker with `String.to_existing_atom/1` +
`Code.ensure_loaded?/1` + `function_exported?/3`
(`lib/statifier_oban/timer/worker.ex:82-105`), and the invoke handler module
travels the same way inside the args
(`lib/statifier_oban/invoke/job_args.ex:64`,
`lib/statifier_oban/invoke/worker.ex:126-144`). That is the established
pattern this plan follows for the codec.

Both workers classify decode failures the same way today: any `{:error, _}`
from `to_effect/1` / `to_invoke/1` becomes `{:cancel, {:undecodable, reason}}`
(`lib/statifier_oban/timer/worker.ex:72-77`,
`lib/statifier_oban/invoke/worker.ex:95-100`), while an unresolvable module is
`{:error, {:invalid_delivery | :invalid_handler, _}}` and **retries**, because
that is an environment fact a deploy fixes rather than a fact about the row.

Config (`lib/statifier_oban/config.ex`) is the ADR-0002 shape: explicit host
options, `@known_options` rejected on typo, required options with no default at
all, optional options whose default is a documented choice rather than a
fallback, doctests for every accept/reject arm.

## Desired End State

1. A public behaviour, `StatifierOban.OpaqueTerm.Codec`, with
   `encode(binary()) :: {:ok, binary()} | {:error, term()}` and
   `decode(binary()) :: {:ok, binary()} | {:error, term()}`, whose contract is
   that `decode/1` returns byte-identically what was handed to `encode/1`.
2. `StatifierOban.Config` accepts `:opaque_codec` - `nil` (the documented
   default: identity) or a module - validated, rejected on any other shape,
   with doctests.
3. Both enqueue sites thread `config.opaque_codec` into their `JobArgs`
   encoder; both encoders return `{:ok, args} | {:error, reason}` because a
   codec can fail, and a failed encode means **no job is inserted** rather than
   a job carrying an unprotected payload.
4. The stored envelope self-describes which codec produced it:
   `%{"t2b64" => b64, "codec" => "Elixir.MyApp.ArgsCodec"}` when a codec ran,
   and exactly today's `%{"t2b64" => b64}` when none did. The reading side
   needs no configuration at all.
5. Both workers distinguish row facts (cancel) from environment facts (retry)
   for the new error shapes.
6. README documents the ids-only shape **first**, as the recommendation for
   most hosts, with the codec seam as the answer for hosts that cannot use it.
7. ADR-0004 (status **Proposed**) records the envelope-tag decision and the
   retry-vs-cancel classification.

Verified by: `mix quality` green (coverage minimum stays 90%,
`coveralls.json`), plus a test asserting that a payload encoded with no codec
is byte-identical to what `main` produces for the same term.

### Key Discoveries

- **A per-row codec tag is what makes a rollout and a key rotation survivable.**
  Config is not readable at decode time (`lib/statifier_oban/timer/worker.ex:60`
  takes only `args` and `meta`), and a scheduled job can sit in the table for
  days. Rows written before the host turned a codec on, rows written during a
  partial deploy, and rows written by a node that has already been reconfigured
  must all decode on any node that reads them. Only a tag travelling **with the
  payload** gives that: absent tag means identity, forever.
- **The tag belongs on the payload, not on the job meta.** `meta` is one map per
  job, but the codec question is per field and per row; a payload-level tag also
  means an operator reading a row in a dashboard sees, on the value itself, why
  it does not look like external term format.
- **Nondeterministic codec output cannot break dedup.** Both workers declare
  `unique: [fields: [:worker, :args], keys: [...]]`
  (`lib/statifier_oban/timer/worker.ex:52-57`,
  `lib/statifier_oban/invoke/worker.ex:69-74`), and Oban's unique query does
  `Map.take(args, keys)` before comparing
  (`deps/oban/lib/oban/engines/basic.ex:514-523`). The opaque fields are not
  among the keys, so a codec whose output differs on every call - the normal
  shape for anything with a nonce - still conflicts correctly on replay. This
  is load-bearing enough to pin with a test.
- **Cancellation is likewise unaffected**: both cancel queries match on
  `args["scope"]` plus `args["send_id"]` / `args["invoke_id"]`
  (`lib/statifier_oban/timer.ex:114-120`,
  `lib/statifier_oban/invoke/handler.ex:249-255`), all non-opaque JSON fields.
- **Module-name-as-string is this repo's established travel pattern**
  (`lib/statifier_oban/invoke/job_args.ex:64` +
  `lib/statifier_oban/invoke/worker.ex:126-144`), including its error stance:
  unresolvable module = retry, not cancel.
- **ADR-0002** fixes the Config stance: explicit host option, validated, no
  silent fallback. `:opaque_codec` follows `:delivery`'s validation shape
  (`lib/statifier_oban/config.ex:139-148`) - shape only, resolution deferred to
  the boundary that uses it.

## What We're NOT Doing

- **No encryption, and no dependency of any kind.** This package does not
  learn what a codec does. No new entry in `mix.exs`. The behaviour is over
  `binary() -> binary()` and nothing in this repo may name, require, suggest,
  or default to a particular implementation.
- **No change to any job semantic**: dedup keys, cancellation keys, scheduling,
  `scheduled_at`, retries, delivery, uniqueness fields, and every non-opaque
  JSON field are untouched. The only bytes that change are the four opaque
  payloads, and only when a host opts in.
- **No key management, rotation policy, or key-versioning scheme.** The codec
  module name is what travels; a host that rotates keys owns making its codec
  accept the older key. This plan documents that obligation and stops there.
- **No codec for `meta`, for the `owner` list, or for the dedup-key
  components.** Those are structural and must stay queryable.
- **Not registering the codec in Config as a resolved/loaded module.** Config
  validates shape only, exactly as `:delivery` does; a codec module that is not
  deployed surfaces at the boundary that resolves it, as a retryable error.
- **Not surfacing a permanently failed decode into the chart as an event.**
  That is the open question `StatifierOban.Invoke.Handler`'s moduledoc already
  records for `run/1` failures, and the event vocabulary is statifier-ex's
  call. See "Open Questions".
- **No new hexdocs extra page.** `mix.exs:50-53` ships `README.md` and
  `CHANGELOG.md` only; the guidance lands in the README and in the behaviour's
  moduledoc rather than growing the docs config in a bead about a codec seam.

## Implementation Approach

Four phases, ordered so each leaves the tree committable and the full gate
green on its own.

Phase 1 is the encoding change in isolation: the behaviour, a codec-aware
`OpaqueTerm`, and the mechanical propagation of the now-fallible encode path
through both `JobArgs` modules to their two callers. Nothing reads a codec from
configuration yet - tests pass one directly - so the default path is provably
unchanged.

Phase 2 wires the host option: `Config.new/1` learns `:opaque_codec` and the
two enqueue sites pass it down. After this phase the feature works end to end
on the happy path.

Phase 3 teaches both workers that a codec failure is not a corrupt row.

Phase 4 is documentation: ADR-0004 (Proposed), the README section that leads
with the ids-only alternative, and the changelog fragment.

The envelope decision deserves restating because everything else follows from
it: **the encoder writes the codec module name into the payload; the decoder
reads it back off the payload.** No configuration is consulted at decode time,
which is why a legacy row, an in-flight row, and a row from a
differently-configured node all decode on any node that has the module.

---

## Phase 1: The codec behaviour and a codec-aware OpaqueTerm

### Overview

Introduce `StatifierOban.OpaqueTerm.Codec`, make `OpaqueTerm.encode/2` accept a
codec and `decode_field/2` honour the tag the encoder wrote, and propagate the
newly fallible encode path out through both `JobArgs` modules to
`Timer.schedule/3` and `Invoke.Handler.perform_start/3` - passing `nil` for now.

### Changes Required:

#### 1. The behaviour

**File**: `lib/statifier_oban/opaque_term/codec.ex` (new)
**Changes**: The public seam. Moduledoc in the house style of its neighbours
(plain hyphens, backticked module references), stating the round-trip contract,
the at-rest reasoning, the key-rotation obligation, and that the module name is
what travels in the row.

```elixir
defmodule StatifierOban.OpaqueTerm.Codec do
  @moduledoc """
  A host-supplied transform over the bytes of an opaque job-arg payload.

  ...  Implementations MUST satisfy, for every binary `b`:
  `decode(encode(b))` returns `{:ok, b}` - byte-identical, on any node that
  can read the row, for as long as a stored job can live. ...
  """

  @doc "..."
  @callback encode(binary()) :: {:ok, binary()} | {:error, term()}

  @doc "..."
  @callback decode(binary()) :: {:ok, binary()} | {:error, term()}
end
```

#### 2. Codec-aware encoding and decoding

**File**: `lib/statifier_oban/opaque_term.ex`
**Changes**: `encode/2` (codec defaults to `nil`) returns
`{:ok, nil | payload} | {:error, encode_error()}`; the single return shape is
deliberate - a codec can fail, so the honest signature is the tuple. The
`nil` term arm still yields `{:ok, nil}`, and the no-codec arm still yields
exactly `%{"t2b64" => base64}` with no extra key. `decode_field/2` keeps its
signature and reads the codec off the payload.

```elixir
@term_tag "t2b64"
@codec_tag "codec"

@type encode_error :: {:codec_failed, module(), term()}

@type decode_error ::
        {:invalid_field, String.t(), term()}
        | {:invalid_codec, String.t(), term()}
        | {:codec_failed, String.t(), module(), term()}

@spec encode(term(), module() | nil) :: {:ok, nil | %{String.t() => String.t()}} | {:error, encode_error()}
def encode(term, codec \\ nil)
def encode(nil, _codec), do: {:ok, nil}
def encode(term, nil), do: {:ok, %{@term_tag => Base.encode64(:erlang.term_to_binary(term))}}

def encode(term, codec) when is_atom(codec) do
  binary = :erlang.term_to_binary(term)

  case apply_codec(codec, :encode, binary) do
    {:ok, encoded} ->
      {:ok, %{@term_tag => Base.encode64(encoded), @codec_tag => Atom.to_string(codec)}}

    {:error, reason} ->
      {:error, {:codec_failed, codec, reason}}
  end
end
```

Decoding gains one arm before the existing Base64 step: a payload carrying
`@codec_tag` resolves the named module (`String.to_existing_atom/1` +
`Code.ensure_loaded?/1` + `function_exported?(module, :decode, 1)`, the exact
shape of `Timer.Worker.resolve_delivery/1` at
`lib/statifier_oban/timer/worker.ex:96-110`) and runs its `decode/1` on the
Base64-decoded bytes before `binary_to_term`. A payload with no `@codec_tag`
takes today's path verbatim.

`apply_codec/3` is the one place a codec is called, on both sides. It returns
data for every outcome: `{:ok, binary}` passes through, `{:ok, other}` becomes
`{:error, {:invalid_return, other}}`, `{:error, reason}` passes through, and a
raise or exit is caught and returned as `{:error, {:raised, kind, reason}}` -
this is a boundary, not a leaf, and a host codec blowing up is a fact the
caller decides about, never a silent fall back to plaintext.

Error mapping on the decode side:

| Situation | Result |
|---|---|
| tag names a module this node cannot resolve, or one without `decode/1` | `{:error, {:invalid_codec, field, name}}` |
| tag is present but not a string | `{:error, {:invalid_codec, field, other}}` |
| the codec returns `{:error, r}`, returns a non-binary, or raises | `{:error, {:codec_failed, field, module, r}}` |
| Base64 fails, or `binary_to_term` rejects the bytes | `{:error, {:invalid_field, field, _}}` (unchanged) |

#### 3. Fallible encode threaded through both wire modules

**Files**: `lib/statifier_oban/timer/job_args.ex`,
`lib/statifier_oban/invoke/job_args.ex`
**Changes**: `from_effect(scope, effect, codec \\ nil)` and
`from_invoke(scope, handler, invoke, codec \\ nil)` return
`{:ok, args()} | {:error, encode_error()}`, where the module's own
`encode_error` wraps the field name:
`{:codec_failed, String.t(), OpaqueTerm.encode_error()}`. Each builds its two
opaque values through a `with`, so the first failure short-circuits and no
partially-encoded args map is ever produced. Both modules' `decode_error`
types widen to include `OpaqueTerm.decode_error()`. Moduledocs gain a sentence
on the codec tag, matching the existing typography.

#### 4. Callers updated mechanically

**Files**: `lib/statifier_oban/timer.ex`, `lib/statifier_oban/invoke/handler.ex`
**Changes**: both add the encoder to their existing `with` and pass `nil` as
the codec for now; both `schedule_error()` and `perform_error()` gain the
codec error member. A failed encode returns before `Oban.insert/2` - no job.

#### 5. Test codecs

**File**: `test/support/opaque_codecs.ex` (new; `test/support` is already on
`elixirc_paths(:test)` at `mix.exs:36`)
**Changes**: four small modules - a reversible byte transform
(`Bitwise.bxor/2` over each byte), a nondeterministic-but-reversible one
(prepend four random bytes, strip on decode), one whose `encode/1` and
`decode/1` return `{:error, :boom}`, and one that raises. No module here
resembles any real cryptographic implementation; they exist to prove the seam.

#### 6. Tests

**File**: `test/statifier_oban/opaque_term_test.exs` (extend), plus the arity
and return-shape updates in `test/statifier_oban/timer/job_args_test.exs` and
`test/statifier_oban/invoke/job_args_test.exs`.

The return-shape update lands in `opaque_term_test.exs` first, because that file
exercises the changed function directly: `test/statifier_oban/opaque_term_test.exs:10`
asserts `OpaqueTerm.encode(nil) == nil` and becomes
`{:ok, nil} = OpaqueTerm.encode(nil)`, and
`test/statifier_oban/opaque_term_test.exs:20` builds
`%{"data" => OpaqueTerm.encode(term)}` and must unwrap the `{:ok, payload}`
tuple before putting it on the wire. Both existing sabotage notes stay accurate
and are kept.

New cases, each with a one-line sabotage note above it per the repo convention:

- a term round-trips byte-identically through a codec, over the JSON wire;
- with no codec the payload is exactly `%{"t2b64" => b64}` - asserted as an
  exact map equality against a hand-computed
  `Base.encode64(:erlang.term_to_binary(term))`, which is the byte-identity
  regression test for every pre-upgrade row;
- a legacy payload (no `"codec"` key) decodes on a node whose caller passes a
  codec - the reading side ignores configuration entirely;
- a payload tagged with an unknown/undeployed module name is
  `{:invalid_codec, field, name}`, not `{:invalid_field, ...}`;
- a payload tagged with a non-string is `{:invalid_codec, ...}`;
- a codec returning `{:error, _}`, returning a non-binary, and raising each
  produce `{:codec_failed, ...}` at decode, and the encode-side equivalents
  produce `{:error, {:codec_failed, module, _}}` from `encode/2` with no
  payload built;
- `nil` still round-trips to `nil` with a codec configured (the codec is never
  called for `nil`), so the row stays readable.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`), coverage at or above the 90%
      minimum in `coveralls.json`
- [x] `lib/statifier_oban/opaque_term/codec.ex` and
      `test/support/opaque_codecs.ex` exist
- [x] The no-codec payload equals `%{"t2b64" => Base.encode64(:erlang.term_to_binary(term))}`
      exactly, asserted in `test/statifier_oban/opaque_term_test.exs`
- [x] `grep -ri` over the diff finds no encryption-library or product name

#### Manual Verification:
- [ ] The behaviour's moduledoc reads as generic infrastructure - a reader
      cannot tell what a host would plug in, and nothing hints at a specific
      library
- [ ] The sabotage note above each new test names a mutation that would
      genuinely have gone red
- [ ] With no codec configured anywhere, schedule one delayed send and one
      invoke, read the stored `oban_jobs.args`, and confirm each opaque payload
      is exactly the map `main` writes for the same term - then cancel one and
      run one worker and confirm the delivered effect is unchanged

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual testing before moving to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The `:opaque_codec` host option

### Overview

`Config.new/1` learns one more explicit, validated option, and the two enqueue
sites thread it into the encoders. After this phase a host turns the seam on by
adding one keyword.

### Changes Required:

#### 1. Config

**File**: `lib/statifier_oban/config.ex`
**Changes**: `:opaque_codec` joins `@known_options`, the struct (default `nil`),
the `@type t`, the typedoc, and the moduledoc. Validation mirrors
`fetch_delivery/3` (`lib/statifier_oban/config.ex:139-148`) but admits `nil` as
the documented default rather than a fallback: `nil` -> `{:ok, nil}`; an atom
that is neither `nil` nor a boolean -> `{:ok, module}`; anything else ->
`{:error, {:invalid_option, :opaque_codec, other}}`. Shape only - the module is
resolved at decode time, by the row that names it, exactly as `:delivery` is.

New doctests alongside the existing ones:

```elixir
iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, opaque_codec: MyApp.ArgsCodec)
{:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, opaque_codec: MyApp.ArgsCodec}}

iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, opaque_codec: "MyApp.ArgsCodec")
{:error, {:invalid_option, :opaque_codec, "MyApp.ArgsCodec"}}
```

The moduledoc paragraph states the ADR-0002 stance for this option explicitly:
the default is identity - today's encoding, unchanged - and a host that wants a
transform names it here; there is no ambient or application-env fallback.

#### 2. Enqueue sites pass it down

**Files**: `lib/statifier_oban/timer.ex:57-73`,
`lib/statifier_oban/invoke/handler.ex:203-219`
**Changes**: replace the Phase 1 `nil` with `config.opaque_codec`. Both
moduledocs gain a sentence: the codec is fixed at enqueue time, and the module
name travels in the payload so the reading side needs no configuration.

#### 3. Tests

**Files**: `test/statifier_oban/config_test.exs`,
`test/statifier_oban/timer_test.exs`,
`test/statifier_oban/invoke/handler_test.exs` (and/or
`test/statifier_oban/invoke/worker_test.exs` for the round trip)

- Config: accepts a module, accepts absence (default `nil`), rejects a string,
  rejects a boolean, and still rejects an unknown option.
- End to end, timers: schedule with a codec configured, read the stored job
  row, assert the `data` payload carries the `"codec"` tag and is **not** the
  plain `t2b64` of the term, then run the worker and assert the delivered
  effect's `data` is the original term - proving the reading side needed no
  config.
- End to end, invoke: the same shape for `params` / `content`.
- **Dedup under a nondeterministic codec**: schedule the same scope and effect
  twice with the nonce-prepending codec; assert the second insert comes back
  with `conflict?` set and exactly one job is stored. Same for the invoke
  handler's replayed start.
- **Cancellation under a codec**: a cancel still matches and cancels a job
  whose opaque fields were codec-encoded.
- A codec that fails at encode: `Timer.schedule/3` returns
  `{:error, {:codec_failed, "data", _}}` and **no job is inserted** (assert the
  table is empty), and `perform_start/3` returns the same shape.

Each new test carries its sabotage note.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`), including the new Config
      doctests
- [ ] Coverage stays at or above the `coveralls.json` minimum
- [ ] The dedup-under-nondeterministic-codec test asserts exactly one stored
      job after the replayed insert

#### Manual Verification:
- [ ] A stored row is inspected by eye: the dedup-key fields, `send_id`,
      `invoke_id`, and the position row data are all still plainly readable,
      and only the four opaque payloads changed
- [ ] The Config moduledoc's new paragraph reads consistently with the
      `:delivery` paragraphs beside it
- [ ] Build a `Config` with no `:opaque_codec`, schedule and cancel a timer and
      start an invoke through it, and confirm the stored rows are identical to
      the pre-Phase-2 rows for the same effects

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual testing before moving to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Workers tell a codec failure from a corrupt row

### Overview

Today every decode error cancels the job
(`lib/statifier_oban/timer/worker.ex:72-77`,
`lib/statifier_oban/invoke/worker.ex:95-100`). Cancelling is right for a
corrupt row - no number of retries makes it decodable - and wrong for a codec
module that is not deployed on this node yet, or a codec that cannot decode the
row right now: both are environment facts a deploy or an operator fixes, and
cancelling would destroy a pending timer or a pending invocation over a
transient condition. Both workers already draw exactly this line for the
delivery and handler modules; this phase extends it to the codec.

### Changes Required:

#### 1. Both workers classify decode errors

**Files**: `lib/statifier_oban/timer/worker.ex`,
`lib/statifier_oban/invoke/worker.ex`
**Changes**: the private `decode/1` in each stops mapping every error to
`{:cancel, ...}`:

```elixir
defp decode(args) do
  case JobArgs.to_effect(args) do
    {:ok, scope, effect} -> {:ok, scope, effect}
    {:error, {:invalid_codec, _field, _name} = reason} -> {:error, reason}
    {:error, {:codec_failed, _field, _codec, _reason} = reason} -> {:error, reason}
    {:error, reason} -> {:cancel, {:undecodable, reason}}
  end
end
```

Both moduledocs gain the new outcome rows, written to match the existing
bullets: a codec the node cannot resolve, or one that cannot decode the row
right now, returns `{:error, ...}` and retries - an environment fact, fixable
by a deploy or by making the key available - while an undecodable row still
cancels.

#### 2. Tests

**Files**: `test/statifier_oban/timer/worker_test.exs`,
`test/statifier_oban/invoke/worker_test.exs`
**Changes**, each with a sabotage note:

- a job whose payload names an undeployed codec returns `{:error,
  {:invalid_codec, _, _}}` from `perform/1` (retry), and specifically not
  `{:cancel, _}`;
- a job whose codec raises or returns `{:error, _}` at decode returns
  `{:error, {:codec_failed, _, _, _}}` (retry);
- a genuinely corrupt payload (bad Base64, non-term bytes, wrong tag shape)
  still returns `{:cancel, {:undecodable, _}}` - the existing behaviour is
  pinned, not widened.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`)
- [ ] Both workers' tests assert `{:error, _}` for the two codec-shaped
      failures and `{:cancel, _}` for the row-shaped ones
- [ ] Coverage stays at or above the `coveralls.json` minimum

#### Manual Verification:
- [ ] The moduledoc outcome lists in both workers read as one consistent set of
      rules with the delivery/handler rows already there
- [ ] The retry-not-cancel choice still looks right when read as an operator:
      a key that has not reached a node yet costs retries and an alert, not a
      silently destroyed timer
- [ ] Run a stored job whose args carry no codec tag at all and confirm it
      still delivers, and a genuinely corrupt one and confirm it still cancels
      with `{:undecodable, _}` - the classification widened for codec errors
      only

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual testing before moving to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: ADR-0004, the ids-only guidance, and the changelog fragment

### Overview

Record the decision and give hosts the guidance the bead asks for - leading
with the ids-only shape, because it is the recommendation for most hosts and
the codec seam is the answer for the ones that cannot use it.

### Changes Required:

#### 1. ADR-0004 (status Proposed)

**File**: `docs/adr/0004-host-pluggable-codec-for-opaque-job-args.md` (new)
**Changes**: three sections, the format `docs/adr/README.md` fixes.

- **Context**: four opaque fields ride as Base64 external term format in
  `oban_jobs.args`; a host with sensitive datamodel values has no seam here,
  while the persistence layer has its storage-adapter seam. Workers hold no
  `%Config{}` at decode time. Jobs can sit in the table for days, so rollouts
  and rotations overlap by construction.
- **Decision**: (1) a `binary() -> binary()` behaviour, host-supplied, with a
  byte-identical round-trip contract, and this package never learns what the
  transform is; (2) the codec module name travels **in the payload**, so the
  reading side consults no configuration and an untagged payload is identity
  forever - which is what makes pre-upgrade rows, partial deploys and key
  rotations decode; (3) `:opaque_codec` is an explicit, validated Config option
  with `nil` as its documented default, per ADR-0002; (4) a codec failure at
  encode aborts the enqueue - no job rather than an unprotected payload; (5) a
  codec failure or an unresolvable codec at decode **retries**, while a corrupt
  row still cancels.
- **Consequences**: the default path is byte-identical, so no migration exists
  and none is needed; dedup and cancellation are unaffected because the unique
  `keys` and the cancel queries read only non-opaque fields
  (`deps/oban/lib/oban/engines/basic.ex:514-523`); an operator reading a row
  sees on the value which codec produced it; the codec module name becomes part
  of the durable wire, so renaming or removing it strands rows until it is
  restored - the same exposure the delivery and handler module names already
  carry; key rotation is the host's, inside one stable module; and the risk
  accepted is that a genuinely corrupt ciphertext retries to exhaustion instead
  of cancelling immediately, ending as a discarded job with the reason on the
  row. The alternative of carrying the codec in the job `meta` is recorded and
  rejected: meta is per job, the question is per field, and a meta-carried
  answer is harder to read off a row in a dashboard.

**File**: `docs/adr/README.md`
**Changes**: one table row - `0004 | Host-pluggable codec for opaque job args
| proposed`.

#### 2. README section

**File**: `README.md`
**Changes**: a new section after "The contract this package implements",
titled something like "Sensitive values in job args", in the README's existing
voice and typography (plain hyphens, no em dashes).

It states the boundary fact first: the four opaque payloads are stored in
`oban_jobs.args` as Base64 external term format - encoded, not protected - and
anyone who can read the host's Oban table can read them.

Then the two answers, ids-only first and explicitly recommended:

1. **Pass ids, not values.** Put entity ids in `data`, `caller_context`,
   `params`, and `content`, and re-fetch at execution time inside the handler's
   `run/1` or at delivery. Nothing sensitive is ever written to the job row,
   the row stays small and readable during an incident, and the value the
   handler acts on is the current one rather than one captured hours earlier -
   which matters when the delay is measured in days. Shown with the canonical
   card-processing example: an `myapp:authorize` invoke whose `params` carry an
   authorization request id, with `run/1` loading the record; the moduledoc
   example at `lib/statifier_oban/invoke/handler.ex:16-30` is already keyed on
   `invoke_id` and re-fetches, so the README points at that shape rather than
   inventing a second one.
2. **Configure `:opaque_codec`** when the value genuinely has to travel - the
   host implements `StatifierOban.OpaqueTerm.Codec` and names it in its
   `Config`. Documented alongside: the round-trip contract; that the module
   name travels in the row, so every node that reads the row needs the module
   deployed; that key rotation lives inside the host's codec because the module
   name is what is durable; that an unresolvable codec or a failing decode
   retries rather than cancelling; and that a codec failure at enqueue means no
   job is inserted.

A closing note that the two compose - ids-only for most fields, a codec for the
few that cannot be reduced to an id - and that the non-opaque fields (`scope`,
`send_id`, `invoke_id`, the position data) are never transformed, because
dedup and cancellation query them.

#### 3. Changelog fragment

**File**: `changelog.d/sob-d7i.md` (new)
**Changes**: one user-facing entry, in `changelog.d/README.md`'s format:
`:opaque_codec` on `StatifierOban.Config`, the behaviour, the unchanged
default, and the ids-only pointer.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`) - this phase touches no Elixir
      code beyond doc references, but the gate still runs clean
- [ ] `docs/adr/0004-host-pluggable-codec-for-opaque-job-args.md` exists with
      `Status: proposed`, and `docs/adr/README.md` lists it
- [ ] `changelog.d/sob-d7i.md` exists
- [ ] The umbrella's terminology scan (`docs/terminology-firewall.md`) is clean
      over the full diff, and no example invoke type outside
      `myapp:authorize`, `myapp:capture`, `myapp:signup` appears

#### Manual Verification:
- [ ] The README section leads with ids-only and reads as a recommendation, not
      a footnote
- [ ] The ADR argues the envelope-tag decision well enough that a reader who
      disagrees can see what would have to change
- [ ] The ADR stays **Proposed** - accepting it is the operator's, on merge
- [ ] Every code reference the README and the ADR make (module names, option
      name, error shapes) matches what Phases 1-3 actually shipped

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual testing before moving to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_oban/opaque_term_test.exs` - the seam itself: codec round
  trip, exact byte identity of the default envelope, legacy untagged payload,
  unknown codec module, non-string tag, codec that errors, codec that returns a
  non-binary, codec that raises, `nil` never reaching the codec.
- `test/statifier_oban/config_test.exs` - `:opaque_codec` accepted, defaulted,
  and rejected on every wrong shape, plus the doctests in the moduledoc.
- `test/statifier_oban/timer/job_args_test.exs`,
  `test/statifier_oban/invoke/job_args_test.exs` - `to_*` still inverts `from_*`
  exactly, now with and without a codec; the existing property test keeps the
  no-codec path honest across every generated effect.
- `test/statifier_oban/timer_test.exs`,
  `test/statifier_oban/invoke/handler_test.exs` - stored row shape under a
  codec, dedup under a nondeterministic codec, cancellation under a codec, and
  the no-job-on-encode-failure rule.
- `test/statifier_oban/timer/worker_test.exs`,
  `test/statifier_oban/invoke/worker_test.exs` - retry for the two codec-shaped
  failures, cancel for the row-shaped ones.

Key edge cases: a row written before the upgrade; a row written by a node with
a codec, read by a node without the module (retry, not cancel); `nil` payloads
with a codec configured; a codec whose output differs on every call.

Every new test asserting `lib/` behaviour carries the one-line sabotage note
the repo requires.

### Manual Testing Steps:

1. Check out `main`, encode a representative term through `OpaqueTerm`, and
   record the exact map. Repeat on the branch with no codec configured and
   confirm the two are identical.
2. With a codec configured, schedule a delayed send; read the stored
   `oban_jobs` row and confirm the dedup-key fields and `send_id` are plainly
   readable while `data` and `caller_context` are not the plain `t2b64` of the
   term.
3. Undeploy the codec module (rename it) and run the worker against that stored
   row: confirm the job retries rather than cancelling, and that the reason on
   the row names the codec.
4. Restore the module and confirm the same row now delivers the original term.
5. Read the README section as a host integrator who has never seen this package
   and confirm the ids-only shape is the one they would reach for first.

## Open Questions

One question is recorded and deliberately left open rather than decided here:

- **Should a permanently failed opaque decode surface into the chart?** When a
  codec-shaped failure exhausts its retries, Oban discards the job and nothing
  is fed back into the run - the failure is visible on the job row and nowhere
  else. This is the same gap `StatifierOban.Invoke.Handler`'s moduledoc already
  records for an exhausted `run/1` failure
  (`lib/statifier_oban/invoke/handler.ex`, "Open question: surfacing permanent
  failure into the chart"), and it has the same owner: the event vocabulary is
  statifier-ex's call, not this package's. This plan therefore matches the
  existing behaviour exactly and adds no new event. If the upstream question is
  answered, both cases should be answered together, in one bead, rather than
  this one being solved separately here.

No other question is left open: every design choice above is decided, and the
alternatives considered are recorded in the ADR (Phase 4) and in "What We're
NOT Doing".

## References

- Bead: `sob-d7i`
- Related ADRs: `docs/adr/0002-host-supplied-oban-instance.md` (the Config
  stance this option follows), `docs/adr/0003-macrostep-joins-the-invoke-job-dedup-key.md`
  (the dedup key this plan must not disturb), and the new
  `docs/adr/0004-host-pluggable-codec-for-opaque-job-args.md` (Phase 4)
- The seam being extended: `lib/statifier_oban/opaque_term.ex:26-73`
- The module-name-as-string travel pattern to model after:
  `lib/statifier_oban/invoke/job_args.ex:64` and
  `lib/statifier_oban/invoke/worker.ex:126-144`
- The retry-vs-cancel line already drawn: `lib/statifier_oban/timer/worker.ex:72-110`
- Oban's unique-key comparison: `deps/oban/lib/oban/engines/basic.ex:514-523`
- Similar plan for house style: `docs/plans/260820-sob-2hx.1-scoped-timer-keys.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The behaviour's moduledoc reads as generic infrastructure - a reader
      cannot tell what a host would plug in, and nothing hints at a specific
      library
- [ ] The sabotage note above each new test names a mutation that would
      genuinely have gone red
- [ ] With no codec configured anywhere, schedule one delayed send and one
      invoke, read the stored `oban_jobs.args`, and confirm each opaque payload
      is exactly the map `main` writes for the same term - then cancel one and
      run one worker and confirm the delivered effect is unchanged

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual testing before moving to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
