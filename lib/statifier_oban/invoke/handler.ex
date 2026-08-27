defmodule StatifierOban.Invoke.Handler do
  @moduledoc """
  The Oban-backed base for a `Statifier.Invoke.Handler` implementation:
  `use` it and the host's `<invoke type="...">` runs its work in an Oban
  job on the host-supplied instance, with completion delivered back into
  the run as `done.invoke.<invoke_id>` through
  `StatifierOban.Invoke.Delivery`.

      defmodule MyApp.AuthorizationHandler do
        use StatifierOban.Invoke.Handler

        @impl StatifierOban.Invoke.Handler
        def config, do: MyApp.statifier_oban_config()

        @impl StatifierOban.Invoke.Handler
        def run(invoke) do
          # `invoke.invoke_id` is the idempotency key upstream hands you:
          # stable by construction across replays. Keying the write on it
          # makes a re-run land on the prior attempt's row instead of
          # authorizing the card a second time.
          with {:ok, authorization} <-
                 MyApp.Payments.authorize_by_invoke_id(invoke.invoke_id, invoke.params) do
            {:ok, %{"authorization_id" => authorization.id}}
          end
        end
      end

  The division of labor follows st-ADR-0051 decision 4 exactly:

  - **The injected `start/2`, `cancel/2`, and `forward/3` are pure
    planning callbacks.** Each returns `{:handler, __MODULE__, payload}`
    instructions (or none) and touches nothing - not the config, not
    Oban. `forward/3` plans nothing by default and is overridable: this
    base gives a job-shaped invocation no autoforward path, because a
    job that has not run yet has nowhere to receive an event.
  - **The injected `perform/2` is the impure half**: for a start it
    inserts one `StatifierOban.Invoke.Worker` job, unique on
    `{scope, invoke_id, macrostep}` (ADR-0003), into the config's
    `:invoke_queue` on the config's Oban instance; for a cancel it
    cancels every stored job under `{scope, invoke_id}`, whatever its
    macrostep. Both are idempotent by construction: the unique key makes
    a replayed insert conflict with the stored job (the same scheduling
    decision, not a new one), and a replayed cancel
    matches only jobs still in a non-terminal state. That uniqueness is
    what this module enforces; what your `run/1` does with the outside
    world is yours to make idempotent the same way.
  - **`run/1` is your work**, executed inside the Oban job - at least
    once, so the MUST-be-idempotent-on-`invoke_id` contract from
    statifier-ex's `docs/extending.md` lands on it. `{:ok, donedata}`
    becomes `done.invoke.<invoke_id>` with that donedata, delivered
    behind the run-liveness check; `{:error, reason}` makes the job
    retry; a raise does the same.

  `config/0` is read at `perform/2` time, never at planning time - which
  is what keeps the planning callbacks pure even though the config is
  host state. A config without `:invoke_queue` fails the first
  `perform/2` with `{:error, {:missing_option, :invoke_queue}}` rather
  than falling back into any host queue.

  The uniqueness key is `{scope, invoke_id, macrostep}` (ADR-0003) for
  the same reason the timer jobs key on `{scope, ordinal}`: every
  component is deterministic as of scheduling, byte-identical when a
  crashed host re-runs the same drive. `invoke_id` is either the
  author's literal id, used verbatim, or a deterministic
  `%MachineState{}` counter (st-ADR-0008 as amended); it restarts per
  chart run, so the scope (`ctx.session_id`, or the host's own durable
  run id) keeps unrelated runs apart. `macrostep` is what tells a
  replay from a re-entry: an authored id is byte-identical on every
  re-entry of its state, and only the macrostep separates that fresh
  scheduling decision from a redelivery of the old one. The unique
  window is every state over an infinite period, and the unique fields
  exclude `:queue` and the meta the delivery module rides on - a host
  moving its invoke queue or reconfiguring its delivery must not turn a
  replay into a second job.

  ## At-least-once: the contract is upstream's

  Jobs here are at-least-once, so a handler's work MUST be idempotent
  on `invoke_id`. The contract's wording is statifier-ex's, not this
  package's: read "At-least-once: handlers must be idempotent" in
  statifier-ex's `docs/extending.md` - this module cites it rather than
  restating it, because the seam that defines `perform/2` owns the
  rulebook. What this base adds on top is only the enqueue-side dedup
  described above ({scope, invoke_id, macrostep} uniqueness).
  Everything `run/1`
  does to the outside world is the implementor's to key, and
  `invoke.invoke_id` is the key upstream hands you for exactly that,
  as the example above demonstrates.

  ## Open question: surfacing permanent failure into the chart

  `{:error, reason}` from `run/1` (and a raise or exit out of it) maps
  to an Oban **retry**, never a cancel: the work is idempotent on
  `invoke_id` by contract, so retrying is what at-least-once means.
  When retries are exhausted, Oban discards the job, and today nothing
  is fed back into the run: the failure is observable on the job row
  (`discarded` state, `{:run_failed, reason}` in the errors) and
  nowhere else. Whether - and as what - a permanently failed invocation
  should surface into the chart (an `error.*` event on the run, for
  example) is **deliberately open**: the event vocabulary is
  statifier-ex's call, so this package documents the gap rather than
  deciding it.

  What this module deliberately does not do: interpret `run/1`'s
  donedata (`<finalize>` and namelist auto-assign are the session's, per
  st-ADR-0051 decision 6), dedup your side effects (the at-least-once
  contract is documented upstream and pinned by
  `Statifier.Testing.HandlerCase`), or feed anything to a dead run (the
  delivery seam discards a completed invoke against a dead or halted run
  the same way a fired timer is discarded).
  """

  import Ecto.Query, only: [where: 3]

  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Handler, as: UpstreamHandler
  alias StatifierOban.Config
  alias StatifierOban.Invoke.{JobArgs, Worker}

  @typedoc """
  The payload inside this base's `{:handler, module, payload}`
  instructions: a start carrying the full effect, or a cancel carrying
  the `invoke_id`.
  """
  @type payload :: {:start, Invoke.t()} | {:cancel, String.t()}

  @typedoc "Why a start or cancel could not be performed."
  @type perform_error ::
          {:missing_option, :invoke_queue}
          | {:invalid_scope, term()}
          | JobArgs.encode_error()
          | Ecto.Changeset.t()

  @doc """
  The host's `StatifierOban.Config` - the Oban instance, the
  `:invoke_queue`, and the `:invoke_delivery` seam. Read at `perform/2`
  time only, so implementations may read it from wherever host
  configuration lives.
  """
  @callback config() :: Config.t()

  @doc """
  The work itself, executed inside the Oban job - at least once per
  `invoke_id`, so it MUST be idempotent on it (statifier-ex
  `docs/extending.md`, "At-least-once"). `{:ok, donedata}` is delivered
  back to the run as `done.invoke.<invoke_id>`; `{:error, reason}` and
  raises both make the job retry.
  """
  @callback run(invoke :: Invoke.t()) :: {:ok, donedata :: term()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Statifier.Invoke.Handler
      @behaviour StatifierOban.Invoke.Handler

      @impl Statifier.Invoke.Handler
      def start(%Statifier.Effect.Invoke{} = invoke, _ctx),
        do: {:ok, [{:handler, __MODULE__, {:start, invoke}}]}

      @impl Statifier.Invoke.Handler
      def cancel(invoke_id, _ctx) when is_binary(invoke_id),
        do: {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}]}

      @impl Statifier.Invoke.Handler
      def forward(_invoke_id, _event, _ctx), do: {:ok, []}

      @impl Statifier.Invoke.Handler
      def perform(payload, ctx),
        do: StatifierOban.Invoke.Handler.perform(__MODULE__, payload, ctx)

      defoverridable forward: 3
    end
  end

  @doc """
  The one implementation behind every `use`-ing module's `perform/2`:
  routes a `{:start, invoke}` payload to `perform_start/3` and a
  `{:cancel, invoke_id}` payload to `perform_cancel/3`.
  """
  @spec perform(module(), payload(), UpstreamHandler.ctx()) :: :ok | {:error, perform_error()}
  def perform(handler, {:start, %Invoke{} = invoke}, ctx),
    do: perform_start(handler, invoke, ctx)

  def perform(handler, {:cancel, invoke_id}, ctx) when is_binary(invoke_id),
    do: perform_cancel(handler, invoke_id, ctx)

  @doc """
  Inserts the one Oban job that runs `handler.run/1` for `invoke`.

  Unique on `{scope, invoke_id, macrostep}` over every state and an
  infinite period, so performing the same instruction again - the
  at-least-once replay st-ADR-0051 decision 4 says MAY happen -
  conflicts with the stored job and inserts nothing, while a re-entered
  state's fresh invocation (same authored id, later macrostep) inserts
  a fresh job (ADR-0003). The job lands in the config's
  `:invoke_queue` and carries the config's `:invoke_delivery` module in
  its meta; meta is not part of the unique fields, so a replay under a
  reconfigured delivery still conflicts with the stored job.
  """
  @spec perform_start(module(), Invoke.t(), UpstreamHandler.ctx()) ::
          :ok | {:error, perform_error()}
  def perform_start(handler, %Invoke{} = invoke, ctx) do
    config = handler.config()

    with {:ok, scope} <- validated_scope(ctx),
         {:ok, queue} <- invoke_queue(config),
         {:ok, args} <- JobArgs.from_invoke(scope, handler, invoke, nil) do
      changeset =
        Worker.new(args,
          queue: queue,
          meta: %{"delivery" => Atom.to_string(config.invoke_delivery)}
        )

      case Oban.insert(config.oban, changeset) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Cancels every stored invoke job under `{scope, invoke_id}` on the
  handler's configured instance - every generation, whatever macrostep
  each job was keyed under (ADR-0003).

  6.4.3's cancellation for a job-shaped invocation: a job that has not
  run yet is cancelled and never runs; a job that already reached a
  terminal state keeps its outcome - a real-time `<cancel>` can lose to
  work that already completed, and the delivery seam's liveness check is
  the guard on that side, not this one. A cancel matching nothing
  (including an `invoke_id` this handler never saw - a crash-recovering
  host may replay a cancel whose start it never durably recorded) is a
  no-op, never an error. The match ignores the queue, exactly as the
  unique key does.
  """
  @spec perform_cancel(module(), String.t(), UpstreamHandler.ctx()) ::
          :ok | {:error, perform_error()}
  def perform_cancel(handler, invoke_id, ctx) when is_binary(invoke_id) do
    config = handler.config()

    with {:ok, scope} <- validated_scope(ctx) do
      {:ok, _count} = Oban.cancel_all_jobs(config.oban, invoke_jobs(scope, invoke_id))
      :ok
    end
  end

  @spec invoke_jobs(String.t(), String.t()) :: Ecto.Query.t()
  defp invoke_jobs(scope, invoke_id) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["scope"] == ^scope and j.args["invoke_id"] == ^invoke_id)
  end

  @spec validated_scope(UpstreamHandler.ctx()) ::
          {:ok, String.t()} | {:error, perform_error()}
  defp validated_scope(%{session_id: scope}) when is_binary(scope) and scope != "",
    do: {:ok, scope}

  defp validated_scope(ctx), do: {:error, {:invalid_scope, ctx}}

  @spec invoke_queue(Config.t()) ::
          {:ok, atom() | String.t()} | {:error, perform_error()}
  defp invoke_queue(%Config{invoke_queue: nil}), do: {:error, {:missing_option, :invoke_queue}}
  defp invoke_queue(%Config{invoke_queue: queue}), do: {:ok, queue}
end
