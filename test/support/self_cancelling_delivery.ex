defmodule StatifierOban.SelfCancellingDelivery do
  @moduledoc """
  A `StatifierOban.Timer.Delivery` that cancels its own `send_id` from
  inside `deliver/2`, which is the shape sob-uon was found in.

  A fired timer's delivery routinely drives the chart out of the state
  that armed it, so the same step that consumes the timer emits that
  state's `onexit` `<cancel>` for the very `send_id` being delivered. The
  cancel and the delivery are then the same Oban job, and a cancel query
  that sweeps `executing` rows kills the delivery mid-step.

  This module reproduces that with a real running queue rather than an
  inline drain: `deliver/2` calls `StatifierOban.Timer.cancel/3` for its
  own scope and `send_id`, reports the count, then stays alive past the
  point where a `:pkill` signal would land before reporting that it
  survived. A test that never sees the second message watched the
  delivery get killed by its own cancel.

  Test-only. The config and the test's pid travel through
  `:persistent_term` under the run's scope, because the delivery
  behaviour deliberately hands an implementation only the scope and the
  effect.
  """

  @behaviour StatifierOban.Timer.Delivery

  alias Statifier.Effect.{Cancel, SendDelayed}

  @typedoc "What a test registers for a scope before the timer fires."
  @type registration :: {StatifierOban.Config.t(), pid()}

  @doc """
  Registers the config a delivery under `scope` cancels through, and the
  pid it reports to.
  """
  @spec register(String.t(), StatifierOban.Config.t(), pid()) :: :ok
  def register(scope, config, test_pid) do
    :persistent_term.put({__MODULE__, scope}, {config, test_pid})
  end

  @doc "Drops a `register/3` entry, so scopes do not accumulate globally."
  @spec unregister(String.t()) :: :ok
  def unregister(scope) do
    :persistent_term.erase({__MODULE__, scope})
    :ok
  end

  @doc """
  How long `deliver/2` stays alive after its own cancel, in milliseconds.

  Long enough that a `:pkill` published on the notifier has landed by the
  time the survival message is sent, so the survival message means the
  delivery was not killed rather than that the kill was still in flight.
  """
  @spec survival_window_ms() :: pos_integer()
  def survival_window_ms, do: 500

  @impl StatifierOban.Timer.Delivery
  @spec deliver(String.t(), SendDelayed.t()) :: :delivered
  def deliver(scope, %SendDelayed{} = effect) do
    {config, test_pid} = :persistent_term.get({__MODULE__, scope})

    send(test_pid, {:delivery_started, scope})

    result = StatifierOban.Timer.cancel(config, scope, self_cancel(effect))

    send(test_pid, {:self_cancel_returned, result})

    Process.sleep(survival_window_ms())

    send(test_pid, {:delivery_survived, scope})

    :delivered
  end

  # The `<cancel>` the exited state's onexit would emit: same send_id,
  # a later ordinal (the cancel is a separate execution step).
  @spec self_cancel(SendDelayed.t()) :: Cancel.t()
  defp self_cancel(%SendDelayed{} = effect) do
    %Cancel{
      send_id: effect.send_id,
      c_index: 0,
      owner: {:onexit, 0, 0},
      macrostep: effect.macrostep + 1,
      microstep: 0,
      round: effect.round,
      ordinal: effect.ordinal + 1
    }
  end
end
