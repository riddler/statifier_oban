defmodule StatifierOban.Invoke.ChildStarter do
  @moduledoc """
  The seam a fan-out's child runs are created through.

  This package schedules fan-out child starts (ADR-0007) and does not
  create runs: creating a child run is a durable, multi-run operation
  behind a storage adapter this package has no dependency on. So the
  starter is a host-wired seam, exactly as `:invoke_delivery` is for the
  other direction: the host names a module here, and
  `StatifierOban.Invoke.ChildStartWorker` calls it once per index.

  A host running `statifier_persistence` wires the start-with-index
  function that package ships for this; a host with its own run store
  wires its own. Nothing in this package knows which.

  ## Idempotency

  `c:start_child/5` is called from an Oban job, so it is called **at
  least once** per index and MUST be idempotent on
  `{parent_run_id, invoke.invoke_id, index}` - the triple the child's
  identity is derived from. A second call for an index whose child
  already exists is a replay of the same scheduling decision, not a
  request for a second child, and must succeed without creating one.

  This is the same requirement `c:StatifierOban.Invoke.Handler.run/1`
  carries on `invoke_id`, for the same reason: at-least-once is what an
  external scheduler costs.

  ## Why the callback takes an option list

  The settlement side records the aggregation policy on **every child's
  own linkage**, not on the parent's, so it can decide what a completing
  child means without reading the parent. That makes the policy an
  argument of every child start rather than a fact the starter module
  holds, and a starter wired for `:all` cannot be reused for a
  `:first_error` invocation of the same chart.

  It rides as a keyword list rather than as a fifth positional value so
  a later scheduling fact - the fan-out's own deadline, say - is an
  added key rather than another arity. `t:opts/0` is what this package
  passes today; an implementation should ignore keys it does not know
  rather than match the list exactly, which is what keeps a host that
  upgrades this package before it upgrades its own starter compiling.

  ## Failure

  `{:error, reason}` makes the start job retry, which is right for the
  environment-shaped failures a run store has (the database is down, a
  lock is held). A child that can never be created exhausts the job's
  retries and is observable on the job row, and the index then has no
  run record - the partially-started fan-out `sb-ADR-0009` decision 8
  and `ADR-0007` decision 2 both specify behaviour for. Noticing it is
  the settlement side's, not this package's.
  """

  alias Statifier.Effect.Invoke

  @typedoc """
  How the settlement side aggregates the children's answers.

  `:all` waits for every child; `:first_error` cancels the siblings of
  the first child that fails. The value is the chart's, read off the
  `core.map` invocation's `on` parameter by
  `StatifierOban.Invoke.FanOut`, and it is recorded on each child at
  creation because that is where the settlement side reads it.
  """
  @type policy :: :all | :first_error

  @typedoc """
  The scheduling facts that travel with one child start.

  `:policy` is the only key this package passes today. An implementation
  should read the keys it knows and ignore the rest - see the moduledoc.
  """
  @type opts :: [policy: policy()]

  @doc """
  Creates child `index` of `count` for the invocation `invoke`, under the
  parent run named by `parent_run_id`.

  `parent_run_id` is the scope the invocation was enqueued under - the
  same value that rides the invoke job's `"scope"` arg. `invoke` is the
  effect the fan-out invocation planned, byte-identical to the one
  `c:StatifierOban.Invoke.Handler.run/1` saw. `index` is the item's
  zero-based position in the fanned-out list and `count` is the list's
  length; together they are what makes the child's identity and its slot
  in the ordered result. `opts` carries the scheduling facts the child is
  created with, `:policy` today.

  Returns `:ok` when the child exists (whether this call created it or a
  previous one did - see the idempotency section) and `{:error, reason}`
  when it could not be created right now.
  """
  @callback start_child(
              parent_run_id :: String.t(),
              invoke :: Invoke.t(),
              index :: non_neg_integer(),
              count :: pos_integer(),
              opts :: opts()
            ) :: :ok | {:error, term()}
end
