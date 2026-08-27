# ADR-0004: Host-pluggable codec for opaque job args

Status: proposed (2026-08-27, sob-d7i)

## Context

Four Statifier effect fields ride as host-opaque job args: a timer's `data`
and `caller_context`, and an invoke's `params` and `content`
(`StatifierOban.OpaqueTerm`). They are arbitrary terms with no JSON shape, so
they are stored as Base64-encoded `:erlang.term_to_binary/1` bytes in
`oban_jobs.args` - encoded, not protected. Anyone who can read the host's
Oban table can read them.

A multi-tenant host carrying sensitive values in its datamodel - a signup
wizard's applicant data, a card-authorization request's payment details -
has no seam to protect those values at this boundary. The persistence layer
already has one: a storage adapter can wrap its own writes however the host
needs. This package had none, which made it the weakest link in an
otherwise-protected chain.

Two structural facts bound the design:

- **Workers hold no `%StatifierOban.Config{}` at decode time.** A worker
  reads its own job's row and resolves what it needs from the row itself
  (`StatifierOban.Timer.Worker` already does this for `:delivery`), because
  the config that enqueued a job is not necessarily the config decoding it
  days later on a different node.
- **Jobs can sit in `oban_jobs` for days.** A durable timer or a slow invoke
  is exactly the case this package exists for, so a rollout, a partial
  deploy, or a key rotation must overlap in time with rows written under the
  previous state. Any design that requires every row to move atomically is
  wrong for this package's own reason to exist.

## Decision

**1. A `binary() -> binary()` behaviour, host-supplied, with a
byte-identical round-trip contract.** `StatifierOban.OpaqueTerm.Codec`
declares `encode/1` and `decode/1`, each returning `{:ok, binary()} |
{:error, term()}`. This package never learns what the transform is or
inspects its output; a codec is called at exactly one boundary
(`OpaqueTerm`'s internal `apply_codec/3`), which catches a raise or exit
from either callback and turns it into a typed error rather than crashing
the job.

**2. The codec module name travels in the payload, not in configuration.**
`OpaqueTerm.encode/2` writes the module's name under a `"codec"` tag next to
the encoded bytes; `decode_field/2` reads that tag and resolves the module
itself, ignoring whatever the decoding call's own caller has configured. An
untagged payload - every row written before a host adopted a codec, and
every row written with none configured - takes the plain path unchanged, so
a codec is opt-in per payload, not per deploy. This is what makes
pre-upgrade rows, partial deploys, and key rotations decode correctly: the
reading side consults the row, never a config value that may have moved on
since the row was written.

**3. `:opaque_codec` is an explicit, validated `StatifierOban.Config`
option, defaulting to `nil`.** Per ADR-0002's stance (no ambient or
application-env fallback for any seam this module owns), a host that wants
the transform states it in the keyword list handed to `Config.new/1`, every
time. `nil` - the default - is identity: the plain `t2b64` encoding, byte-
identical to every row written before this seam existed. `Config` validates
only the shape (an atom, not a boolean or `nil` used as a value) at
configuration time, the same division of labor `:delivery` and
`:invoke_delivery` already follow; whether the named module actually
implements the behaviour is resolved later, at the boundary that uses it.

**4. A codec failure at encode means no job, not an unprotected payload.**
`encode/2` runs `codec.encode/1` over the term's bytes before the enqueue
happens. If the codec fails - returns `{:error, _}`, returns a non-binary,
or raises - `encode/2` returns `{:error, {:codec_failed, codec, reason}}`
and no payload is built, so the caller inserts nothing rather than falling
back to storing the term untransformed.

**5. A codec failure or an unresolvable codec at decode retries; a
genuinely corrupt row cancels.** `decode_field/2` distinguishes three
outcomes: a payload that is not a well-formed tagged map at all
(`{:invalid_field, field, other}` - the row itself is corrupt), a `"codec"`
tag naming a module this node cannot resolve to a loaded module exporting
`decode/1` (`{:invalid_codec, field, name}` - deploy-shaped, the module may
simply not be loaded on this node yet), and a resolvable codec whose
`decode/1` itself fails (`{:codec_failed, field, module, reason}` - could be
a key not yet rotated in, a transient error, or a genuine failure). Both
workers (`StatifierOban.Timer.Worker`, `StatifierOban.Invoke.Worker`) match
the codec-shaped errors and return `{:error, _}`, which Oban retries; only
the row-shaped error falls into the `{:cancel, {:undecodable, _}}` path.
This mirrors how `StatifierOban.Timer.Worker` already treats an
unresolvable `:delivery` module name.

## Consequences

- The default path is byte-identical to today's encoding, so no migration
  exists and none is needed for a host that does not configure
  `:opaque_codec`.
- Dedup and cancellation are unaffected: the unique `keys` Oban's engine
  reads and the cancel queries this package builds both read only
  non-opaque fields (`scope`, `send_id`, `invoke_id`, `macrostep`, and the
  other position data) - the four opaque fields never participate in either
  query.
- An operator reading a row sees, on the value, which codec (if any)
  produced it, without consulting any host configuration.
- The codec module name becomes part of the durable wire: renaming or
  removing it strands every row still naming it until the module is
  restored. This is the same exposure the `:delivery` and `:invoke_delivery`
  module names already carry on stored rows, so it introduces no new class
  of risk, only one more name a host must keep resolvable for as long as it
  might still be on a stored row.
- Key rotation is entirely the host's, inside one stable module: a codec
  that carries its own key material (a key id, a nonce, a version byte)
  inside the bytes `encode/1` returns can rotate freely, because `decode/1`
  reads whatever it needs to reverse itself back out of those bytes.
  `OpaqueTerm` stores only the module name and treats the bytes themselves
  as opaque in both directions.
- Risk accepted: a codec that fails permanently on a given row (a lost key,
  a bug in the host's own decode path) retries to exhaustion rather than
  cancelling immediately, because this package cannot distinguish "wrong
  key today, right key after tomorrow's rotation" from "will never decode."
  It ends as a discarded job, with the reason on the row for an operator to
  find.
- Rejected alternative: carrying the codec name in the job's `meta` instead
  of the payload envelope. `meta` is per job; the question of which codec
  produced a given field is per field, and today every opaque field on a
  job shares one codec choice only by convention, not by any constraint
  this design enforces. A meta-carried answer is also harder to read off a
  row in a dashboard, where the payload itself is the thing an operator is
  already looking at.
