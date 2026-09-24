defmodule StatifierOban.JobTimeout do
  @moduledoc false

  # The per-job run-time bound, carried on the job row.
  #
  # `Oban.Worker.timeout/1` receives only the `%Oban.Job{}`, so a
  # `StatifierOban.Config` never reaches a worker at perform time. The
  # bound therefore travels the way the delivery module already does: an
  # enqueue site writes it into the job's meta from a validated config,
  # and the worker reads it back off the row. Meta is not part of any
  # worker's unique fields, so a replay under a reconfigured bound still
  # conflicts with the stored job.
  #
  # `:infinity` - the default - writes nothing, so a job enqueued under
  # the default carries exactly the meta it carried before the bound
  # existed, and a job without the key (including every job stored before
  # it existed) reads as `:infinity`. Only a positive integer is a bound;
  # any other value on the row reads as no bound, because the key is only
  # ever written from a validated config and a hand-edited row is not a
  # reason to kill the host's work early.

  @meta_key "timeout"

  @typedoc "A run-time bound in milliseconds, or none."
  @type bound :: pos_integer() | :infinity

  @doc false
  @spec put(map(), bound()) :: map()
  def put(meta, :infinity) when is_map(meta), do: meta

  def put(meta, bound) when is_map(meta) and is_integer(bound) and bound > 0,
    do: Map.put(meta, @meta_key, bound)

  @doc false
  @spec bound(Oban.Job.t()) :: bound()
  def bound(%Oban.Job{meta: meta}) do
    case meta do
      %{@meta_key => bound} when is_integer(bound) and bound > 0 -> bound
      _other -> :infinity
    end
  end
end
