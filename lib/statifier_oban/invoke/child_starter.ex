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

  `c:start_child/4` is called from an Oban job, so it is called **at
  least once** per index and MUST be idempotent on
  `{parent_run_id, invoke.invoke_id, index}` - the triple the child's
  identity is derived from. A second call for an index whose child
  already exists is a replay of the same scheduling decision, not a
  request for a second child, and must succeed without creating one.

  This is the same requirement `c:StatifierOban.Invoke.Handler.run/1`
  carries on `invoke_id`, for the same reason: at-least-once is what an
  external scheduler costs.

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

  @doc """
  Creates child `index` of `count` for the invocation `invoke`, under the
  parent run named by `parent_run_id`.

  `parent_run_id` is the scope the invocation was enqueued under - the
  same value that rides the invoke job's `"scope"` arg. `invoke` is the
  effect the fan-out invocation planned, byte-identical to the one
  `c:StatifierOban.Invoke.Handler.run/1` saw. `index` is the item's
  zero-based position in the fanned-out list and `count` is the list's
  length; together they are what makes the child's identity and its slot
  in the ordered result.

  Returns `:ok` when the child exists (whether this call created it or a
  previous one did - see the idempotency section) and `{:error, reason}`
  when it could not be created right now.
  """
  @callback start_child(
              parent_run_id :: String.t(),
              invoke :: Invoke.t(),
              index :: non_neg_integer(),
              count :: pos_integer()
            ) :: :ok | {:error, term()}
end
