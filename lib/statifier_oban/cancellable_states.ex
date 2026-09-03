defmodule StatifierOban.CancellableStates do
  @moduledoc false
  # The Oban job states a cancel is allowed to reach, shared by
  # `StatifierOban.Timer.cancel/3` and
  # `StatifierOban.Invoke.Handler.perform_cancel/3`: every non-terminal
  # state except `executing`. `executing` is deliberately absent - a
  # delivery that cancels its own send_id or invoke_id would otherwise
  # pkill itself (sob-uon, sob-84c). The terminal states are excluded by
  # `Oban.cancel_all_jobs/2` anyway; naming the set positively keeps the
  # whole rule readable in one place. `suspended` earns its place because
  # a held job has not fired and would fire on resume.
  #
  # The list is intersected with `Oban.Job.states/0` at call time rather
  # than written as a literal, because the package declares `~> 2.19` and
  # `suspended` only exists from Oban 2.21.0 (migration v14). On an older
  # Oban a literal `suspended` compiles fine and then fails at query time:
  # Postgres rejects it for the `oban_job_state` enum (22P02), so every
  # cancel raised (sob-axb). Asking the installed Oban what it knows keeps
  # the declared floor honest without parsing a version number, and a
  # state Oban adds later still lands as a review point in
  # `StatifierOban.CancellableStatesTest` rather than as a job that
  # silently stops being cancellable.

  @intended ~w(suspended scheduled available retryable)

  @doc false
  @spec list() :: [String.t()]
  def list do
    known = Enum.map(Oban.Job.states(), &Atom.to_string/1)
    Enum.filter(@intended, &(&1 in known))
  end
end
