defmodule StatifierOban.Invoke.HandlerConformanceTest do
  # Not async: shares the one SQLite repo and oban_jobs table (ADR-0002
  # harness) and the globally named Statifier.Supervisor, which the
  # HandlerCase probe checks drive real sessions through.
  use ExUnit.Case, async: false

  # st-ADR-0065's conformance case, run against the base handler exactly
  # as any downstream implementor runs it against theirs. The generated
  # tests are the upstream case's own; the sabotage discipline for them
  # was exercised at the module level rather than per generated block:
  # sabotage: StatifierOban.Invoke.Worker's `unique` keys dropped -> the
  # idempotency test went red (a second perform pass inserted a second
  # job for inv_1), reverted.
  use Statifier.Testing.HandlerCase,
    handler: StatifierOban.TestInvokeHandler,
    type: "myapp:enrich"

  import Ecto.Query, only: [where: 3]

  alias StatifierOban.Invoke.Worker
  alias StatifierOban.{TestInvokeHandler, TestRepo}

  setup do
    start_supervised!(Statifier.Supervisor)

    start_supervised!(
      {Oban,
       name: TestInvokeHandler.oban_name(),
       repo: TestRepo,
       engine: Oban.Engines.Lite,
       testing: :manual}
    )

    :ok
  end

  # The observation point HandlerCase judges planning purity and perform
  # idempotency against: the stored invoke jobs attributable to the
  # invoke_id, reduced to identity, state, and queue so row timestamps
  # cannot defeat the comparison.
  def observed_effects(invoke_id) do
    worker = Oban.Worker.to_string(Worker)

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.args["invoke_id"] == ^invoke_id)
    |> TestRepo.all()
    |> Enum.map(&{&1.args["scope"], &1.args["invoke_id"], &1.state, &1.queue})
    |> Enum.sort()
  end
end
