if Code.ensure_loaded?(StatifierPersistence.PinSource) do
  defmodule StatifierOban.Timer.PinSource do
    @moduledoc """
    Pending timers as a `StatifierPersistence.PinSource`, per ADR-0008.

    Before `statifier_persistence` retires a chart it asks every pin source
    the host names whether anything still pins it. A pending timer is state
    that package cannot see: a row in the host's Oban table. This module
    answers for it, so a host running both packages does not write the
    adapter.

    This module exists only when `statifier_persistence` is in the host's
    dependencies: `statifier_oban` depends on it optionally.

    ## Adopting it

        defmodule MyApp.TimerPins do
          use StatifierOban.Timer.PinSource, config: {MyApp, :statifier_oban_config}
        end

    `:config` names a zero-arity function in the host that returns the
    host's `%StatifierOban.Config{}`. The `use` declares the behaviour in the
    host's module and defines its `pins/2`, which calls that function on
    every call - a config built at runtime is read when the count is taken -
    and hands the context's `:execution_ids` to
    `StatifierOban.Timer.pending_for/2`. The answer is one count,
    `%{timers: n}`, `n` being the timers still pending under those ids; no
    ids, or ids with nothing pending, answer `%{timers: 0}`.

    The host passes its own module, `MyApp.TimerPins` above, wherever the
    persistence package takes pin sources.

    Take a library hold: the hold's chart waits for `copy.collected` and
    schedules a `pickup.expired` timer when the copy becomes available.
    While that timer is pending, a retirement of the hold's chart is refused
    with `%{timers: 1}` under `MyApp.TimerPins`; once it fires or is
    cancelled the count is zero and the timer no longer holds the chart.

    ## Only for a host that schedules under durable execution ids

    The execution ids a pin source is handed go straight to
    `pending_for/2` as scopes. That is right for a process-less host, whose
    timers were scheduled under its own durable execution ids. A host that
    schedules under a live session's id (`StatifierOban.Timer.Key`) is
    scoping by session, the ids it is handed match no stored scope, and
    this module would answer `%{timers: 0}` for timers that exist, a zero
    every caller reads as nothing pending. Nothing here can see which
    choice a host made, so it cannot refuse on the mismatch. Such a host
    does not adopt this module; it writes its own source that maps its
    executions to the sessions its timers were scheduled under.

    ## The content hash is unused

    A timer job carries the scope and the send, never a chart identity, so
    this source cannot answer by hash and does not try. The hash still
    reaches it because every source is handed the same arguments.

    ## A source that cannot count raises

    `pending_for/2` raises when the Oban instance is not running or its
    repo cannot answer, and the injected `pins/2` rescues nothing.
    `StatifierPersistence.PinSource.collect/3` turns the raise into a
    refusal naming the host's module, so "no pending timers" and "could not
    count" stay two answers.
    """

    @doc """
    Declares `StatifierPersistence.PinSource` in the calling module and
    defines its `pins/2` over the host's config.

    `opts` must carry `config: {module, function}`, naming a zero-arity
    function that returns a `%StatifierOban.Config{}`. Anything else is an
    `ArgumentError` at compile time.
    """
    defmacro __using__(opts) do
      {module, function} = config!(opts, __CALLER__)

      quote do
        @behaviour StatifierPersistence.PinSource

        @impl StatifierPersistence.PinSource
        def pins(_content_hash, %{execution_ids: execution_ids}) when is_list(execution_ids) do
          pending =
            unquote(module)
            |> apply(unquote(function), [])
            |> StatifierOban.Timer.pending_for(execution_ids)
            |> Map.values()
            |> Enum.sum()

          %{timers: pending}
        end
      end
    end

    @spec config!(keyword(), Macro.Env.t()) :: {module(), atom()}
    defp config!(opts, caller) do
      case Keyword.fetch(opts, :config) do
        {:ok, {module_ast, function}} ->
          module = Macro.expand(module_ast, caller)

          if is_atom(module) and is_atom(function),
            do: {module, function},
            else: raise(ArgumentError, config_error(opts))

        _missing_or_malformed ->
          raise ArgumentError, config_error(opts)
      end
    end

    @spec config_error(keyword()) :: String.t()
    defp config_error(opts) do
      "use StatifierOban.Timer.PinSource expects config: {module, function} " <>
        "naming a zero-arity function that returns a %StatifierOban.Config{}, " <>
        "got: #{Macro.to_string(opts)}"
    end
  end
end
