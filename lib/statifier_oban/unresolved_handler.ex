defmodule StatifierOban.UnresolvedHandler do
  @moduledoc false

  # The unresolvable-handler policy, carried on the invoke job's meta -
  # the same pattern `StatifierOban.JobTimeout` uses for the run-time
  # bound.
  #
  # `StatifierOban.Invoke.Worker.perform/1` receives only the
  # `%Oban.Job{}`, so a `StatifierOban.Config` never reaches the worker
  # at perform time. The policy therefore travels the way the delivery
  # module and the run-time bound already do: the enqueue site writes it
  # into the job's meta from a validated config, and the worker reads it
  # back off the row.
  #
  # `:retry` - the default - writes nothing, so a job enqueued under the
  # default carries exactly the meta it carried before the option
  # existed. A job without the key - including every job stored before
  # it existed, and a hand-edited row - reads as `:retry`; only the
  # stored string `"cancel"` reads as `:cancel`, because the key is only
  # ever written from a validated config.

  @meta_key "unresolved_handler"
  @cancel_value "cancel"

  @doc false
  @spec put(map(), StatifierOban.Config.unresolved_handler()) :: map()
  def put(meta, :retry) when is_map(meta), do: meta
  def put(meta, :cancel) when is_map(meta), do: Map.put(meta, @meta_key, @cancel_value)

  @doc false
  @spec cancel?(Oban.Job.t()) :: boolean()
  def cancel?(%Oban.Job{meta: meta}), do: Map.get(meta, @meta_key) == @cancel_value
end
