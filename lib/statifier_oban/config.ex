defmodule StatifierOban.Config do
  @moduledoc """
  Configuration for running Statifier effects on a host-supplied Oban
  instance.

  Per ADR-0002, this package never owns, starts, or names an Oban instance:
  the host supplies its own instance's name and every public entry point in
  this package takes it from here. There is no default - not even Oban's own
  default name `Oban` - so a missing instance is a configuration error at
  the call site, never a silent fallback into whatever instance happens to
  be running.

  Queues are the host's for the same reason (ADR-0002 fixes instance
  ownership and says each job kind's queue travels here as a further
  field). `:timers_queue` names the host queue that delayed-send timer
  jobs target; it is required with no default, so a job never falls back
  silently into a host's `:default` queue.

  `:delivery` is the one option with a default, and the default is a
  documented choice rather than a fallback: the run-liveness delivery
  seam (`StatifierOban.Timer.Delivery`) defaults to the
  `Statifier.Session`-backed check, which is correct for any host running
  sessions with the session id as scope. A host answering liveness from
  its own run store supplies its implementation here.

  ## Examples

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :statifier_timers)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :statifier_timers}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban)
      {:error, {:missing_option, :timers_queue}}

      iex> StatifierOban.Config.new([])
      {:error, {:missing_option, :oban}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, queue: :timers)
      {:error, {:unknown_options, [:queue]}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, delivery: MyApp.RunStore)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, delivery: MyApp.RunStore}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, delivery: "MyApp.RunStore")
      {:error, {:invalid_option, :delivery, "MyApp.RunStore"}}
  """

  @enforce_keys [:oban, :timers_queue]
  defstruct [:oban, :timers_queue, delivery: StatifierOban.Timer.Delivery.Session]

  @typedoc """
  The host-supplied Oban configuration.

  `:oban` is the name of the host's Oban instance, as given to
  `Oban.start_link/1` - anything `t:Oban.name/0` allows. `:timers_queue`
  is the host queue delayed-send timer jobs are inserted into - an atom or
  string, exactly as the host names it in its own Oban `:queues`.
  `:delivery` is the module implementing `StatifierOban.Timer.Delivery`
  that fired timer jobs go through.
  """
  @type t :: %__MODULE__{
          oban: Oban.name(),
          timers_queue: atom() | String.t(),
          delivery: module()
        }

  @known_options [:oban, :timers_queue, :delivery]
  @default_delivery StatifierOban.Timer.Delivery.Session

  @doc """
  Builds a config from the host's options.

  `:oban` and `:timers_queue` are required; `:delivery` is optional and
  defaults to `StatifierOban.Timer.Delivery.Session`. Unknown options are
  rejected rather than ignored, so a typo fails loudly instead of
  silently dropping a setting.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- check_unknown(opts),
         {:ok, oban} <- fetch_required(opts, :oban),
         {:ok, timers_queue} <- fetch_required(opts, :timers_queue),
         :ok <- check_queue_name(:timers_queue, timers_queue),
         {:ok, delivery} <- fetch_delivery(opts) do
      {:ok, %__MODULE__{oban: oban, timers_queue: timers_queue, delivery: delivery}}
    end
  end

  @spec fetch_delivery(keyword()) :: {:ok, module()} | {:error, term()}
  defp fetch_delivery(opts) do
    case Keyword.get(opts, :delivery, @default_delivery) do
      delivery when is_atom(delivery) and not is_nil(delivery) and not is_boolean(delivery) ->
        {:ok, delivery}

      other ->
        {:error, {:invalid_option, :delivery, other}}
    end
  end

  defp check_unknown(opts) do
    case Keyword.keys(opts) -- @known_options do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> {:error, {:missing_option, key}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp check_queue_name(_key, queue) when is_atom(queue) or is_binary(queue), do: :ok
  defp check_queue_name(key, queue), do: {:error, {:invalid_option, key, queue}}
end
