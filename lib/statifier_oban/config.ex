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

  `:invoke_queue` names the host queue that invoke-handler jobs
  (`StatifierOban.Invoke.Worker`) target. It is optional because a
  timers-only host has no invoke jobs to queue - but it has no default
  either: a host whose handlers are built on
  `StatifierOban.Invoke.Handler` gets `{:error, {:missing_option,
  :invoke_queue}}` from the first `perform/2` rather than a silent
  fallback queue.

  The delivery seams are the options with defaults, and each default is a
  documented choice rather than a fallback: `:delivery` (the run-liveness
  seam fired timers go through, `StatifierOban.Timer.Delivery`) and
  `:invoke_delivery` (the seam a completed invoke's `done.invoke` goes
  through, `StatifierOban.Invoke.Delivery`) both default to their
  `Statifier.Session`-backed check, which is correct for any host running
  sessions with the session id as scope. A host answering liveness from
  its own run store supplies its implementations here.

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

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, invoke_queue: :statifier_invokes)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, invoke_queue: :statifier_invokes}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, invoke_queue: 42)
      {:error, {:invalid_option, :invoke_queue, 42}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, opaque_codec: MyApp.ArgsCodec)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, opaque_codec: MyApp.ArgsCodec}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, opaque_codec: "MyApp.ArgsCodec")
      {:error, {:invalid_option, :opaque_codec, "MyApp.ArgsCodec"}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, child_starter: MyApp.Starter)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, child_starter: MyApp.Starter}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, child_starter: "MyApp.Starter")
      {:error, {:invalid_option, :child_starter, "MyApp.Starter"}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, max_fan_out: 50)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban, timers_queue: :t, max_fan_out: 50}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, timers_queue: :t, max_fan_out: 0)
      {:error, {:invalid_option, :max_fan_out, 0}}

  ## The `:opaque_codec` seam (ADR-0002 stance)

  `:opaque_codec` is optional and defaults to `nil` - identity, today's
  plain `t2b64` encoding, unchanged. A host that wants a transform over
  the bytes of the four host-opaque job-arg fields (a timer's `data` and
  `caller_context`, an invoke's `params` and `content`) names a module
  implementing `StatifierOban.OpaqueTerm.Codec` here. As with `:oban`,
  `:delivery`, and every other seam this module owns, there is no ambient
  or application-env fallback: a host that wants the transform states it
  in the keyword list handed to `new/1`, explicitly, every time.

  ## The fan-out options (ADR-0007)

  `:child_starter` is the third seam and the fan-out half's own: the
  module implementing `StatifierOban.Invoke.ChildStarter` that a child
  start job calls to create child `i` of the invocation. It is optional
  and defaults to `nil`, because a host with no `core.map` in any of its
  charts has no children to start - and it has no default module either,
  for the reason `:invoke_queue` has none: this package does not create
  runs, so there is nothing here to fall back to. A fan-out on a config
  without one is refused on the invocation's error route rather than
  starting nothing silently.

  `:max_fan_out` is the runtime cap ADR-0007 decision 8 sends to the
  host, given a number here at last: a positive integer, defaulting to
  `1_000`, checked by the fan-out **before the first child start**. A
  fan-out wider than the cap starts no children at all and fails the
  invocation on `error.communication.invoke.<invoke_id>` with the count
  and the cap in `detail`. The default is the largest N the family's
  records have reasoned about rather than a measurement of any
  particular deployment; a host that measures its own raises or lowers
  it here.
  """

  @enforce_keys [:oban, :timers_queue]
  defstruct [
    :oban,
    :timers_queue,
    :invoke_queue,
    :opaque_codec,
    :child_starter,
    delivery: StatifierOban.Timer.Delivery.Session,
    invoke_delivery: StatifierOban.Invoke.Delivery.Session,
    max_fan_out: 1_000
  ]

  @typedoc """
  The host-supplied Oban configuration.

  `:oban` is the name of the host's Oban instance, as given to
  `Oban.start_link/1` - anything `t:Oban.name/0` allows. `:timers_queue`
  is the host queue delayed-send timer jobs are inserted into - an atom or
  string, exactly as the host names it in its own Oban `:queues`.
  `:delivery` is the module implementing `StatifierOban.Timer.Delivery`
  that fired timer jobs go through. `:invoke_queue` is the host queue
  invoke-handler jobs are inserted into (`nil` on a timers-only host), and
  `:invoke_delivery` is the module implementing
  `StatifierOban.Invoke.Delivery` that a completed invoke's `done.invoke`
  goes back through. `:opaque_codec` is the module implementing
  `StatifierOban.OpaqueTerm.Codec` that the two enqueue sites run the
  host-opaque job-arg fields through (`nil` - the default - is the
  identity encoding). `:child_starter` is the module implementing
  `StatifierOban.Invoke.ChildStarter` that fan-out child start jobs
  create their child through (`nil` on a host with no fan-out), and
  `:max_fan_out` is the positive integer cap on a fan-out's width.
  """
  @type t :: %__MODULE__{
          oban: Oban.name(),
          timers_queue: atom() | String.t(),
          invoke_queue: atom() | String.t() | nil,
          opaque_codec: module() | nil,
          child_starter: module() | nil,
          delivery: module(),
          invoke_delivery: module(),
          max_fan_out: pos_integer()
        }

  @known_options [
    :oban,
    :timers_queue,
    :invoke_queue,
    :delivery,
    :invoke_delivery,
    :opaque_codec,
    :child_starter,
    :max_fan_out
  ]
  @default_delivery StatifierOban.Timer.Delivery.Session
  @default_invoke_delivery StatifierOban.Invoke.Delivery.Session
  @default_max_fan_out 1_000

  @doc """
  Builds a config from the host's options.

  `:oban` and `:timers_queue` are required; `:invoke_queue` is optional
  with no default (see the moduledoc); `:delivery` and `:invoke_delivery`
  are optional and default to the `Statifier.Session`-backed seams;
  `:opaque_codec` is optional and defaults to `nil` (identity - see the
  moduledoc's ADR-0002 stance); `:child_starter` is optional and defaults
  to `nil`, and `:max_fan_out` is optional and defaults to `1_000` (see
  the moduledoc's fan-out section). Unknown options are rejected rather
  than ignored, so a typo fails loudly instead of silently dropping a
  setting.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- check_unknown(opts),
         {:ok, oban} <- fetch_required(opts, :oban),
         {:ok, timers_queue} <- fetch_required(opts, :timers_queue),
         :ok <- check_queue_name(:timers_queue, timers_queue),
         {:ok, invoke_queue} <- fetch_invoke_queue(opts),
         {:ok, delivery} <- fetch_delivery(opts, :delivery, @default_delivery),
         {:ok, invoke_delivery} <-
           fetch_delivery(opts, :invoke_delivery, @default_invoke_delivery),
         {:ok, opaque_codec} <- fetch_opaque_codec(opts),
         {:ok, child_starter} <- fetch_optional_module(opts, :child_starter),
         {:ok, max_fan_out} <- fetch_max_fan_out(opts) do
      {:ok,
       %__MODULE__{
         oban: oban,
         timers_queue: timers_queue,
         invoke_queue: invoke_queue,
         delivery: delivery,
         invoke_delivery: invoke_delivery,
         opaque_codec: opaque_codec,
         child_starter: child_starter,
         max_fan_out: max_fan_out
       }}
    end
  end

  @spec fetch_invoke_queue(keyword()) ::
          {:ok, atom() | String.t() | nil} | {:error, term()}
  defp fetch_invoke_queue(opts) do
    case Keyword.get(opts, :invoke_queue) do
      nil -> {:ok, nil}
      queue when is_atom(queue) or is_binary(queue) -> {:ok, queue}
      other -> {:error, {:invalid_option, :invoke_queue, other}}
    end
  end

  @spec fetch_delivery(keyword(), atom(), module()) :: {:ok, module()} | {:error, term()}
  defp fetch_delivery(opts, key, default) do
    case Keyword.get(opts, key, default) do
      delivery when is_atom(delivery) and not is_nil(delivery) and not is_boolean(delivery) ->
        {:ok, delivery}

      other ->
        {:error, {:invalid_option, key, other}}
    end
  end

  # Shape only, per the moduledoc: `nil` (the documented default - the
  # identity encoding for `:opaque_codec`, no fan-out for
  # `:child_starter`) or an atom that is neither `nil` nor a boolean.
  # Whether the named module actually implements its behaviour is
  # resolved later, at the boundary that uses it - the same division of
  # labor `:delivery` and `:invoke_delivery` follow.
  @spec fetch_optional_module(keyword(), atom()) :: {:ok, module() | nil} | {:error, term()}
  defp fetch_optional_module(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      module when is_atom(module) and not is_boolean(module) -> {:ok, module}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  @spec fetch_opaque_codec(keyword()) :: {:ok, module() | nil} | {:error, term()}
  defp fetch_opaque_codec(opts), do: fetch_optional_module(opts, :opaque_codec)

  # The cap is a count, so the shape check is a count's: a positive
  # integer. Zero is rejected rather than read as "no fan-out allowed" -
  # a host that wants that wires no `:child_starter` - and so is a
  # negative number, which no reading makes sense of.
  @spec fetch_max_fan_out(keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp fetch_max_fan_out(opts) do
    case Keyword.get(opts, :max_fan_out, @default_max_fan_out) do
      cap when is_integer(cap) and cap > 0 -> {:ok, cap}
      other -> {:error, {:invalid_option, :max_fan_out, other}}
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
