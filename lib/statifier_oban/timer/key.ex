defmodule StatifierOban.Timer.Key do
  @moduledoc """
  Derives the two scoped keys a durable-timer store needs, per ADR-0054
  decision 3 and `docs/durable-timers.md` ("Keying your store") in
  statifier-ex.

  `scope` is always an argument and never derived: `send_counter` restarts
  at 0 for every chart run (ADR-0035), so `send_1` from one run addresses
  the same row as `send_1` from an unrelated run unless the store keeps
  them apart. It is `ctx.session_id` (spec 5.10's `_sessionid`) for a live
  session, or the host's own durable run id for a process-less host.
  """

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.Timer.{CancellationKey, DedupKey}

  @type scope :: String.t()
  @type error :: :invalid_scope | :missing_send_id

  @spec cancellation_key(scope(), SendDelayed.t() | Cancel.t()) ::
          {:ok, CancellationKey.t()} | {:error, error()}
  def cancellation_key(scope, %SendDelayed{send_id: send_id}) do
    build_cancellation_key(scope, send_id)
  end

  def cancellation_key(scope, %Cancel{send_id: send_id}) do
    build_cancellation_key(scope, send_id)
  end

  @spec dedup_key(scope(), SendDelayed.t()) ::
          {:ok, DedupKey.t()} | {:error, error()}
  def dedup_key(scope, %SendDelayed{send_id: send_id} = send_delayed) do
    with {:ok, scope} <- validated_scope(scope),
         {:ok, send_id} <- validated_send_id(send_id) do
      {:ok,
       %DedupKey{
         scope: scope,
         send_id: send_id,
         macrostep: send_delayed.macrostep,
         microstep: send_delayed.microstep,
         round: send_delayed.round,
         c_index: send_delayed.c_index,
         owner: send_delayed.owner
       }}
    end
  end

  @spec cancels?(CancellationKey.t(), DedupKey.t()) :: boolean()
  def cancels?(%CancellationKey{scope: scope, send_id: send_id}, %DedupKey{
        scope: scope,
        send_id: send_id
      }),
      do: true

  def cancels?(%CancellationKey{}, %DedupKey{}), do: false

  @spec build_cancellation_key(scope(), String.t() | nil) ::
          {:ok, CancellationKey.t()} | {:error, error()}
  defp build_cancellation_key(scope, send_id) do
    with {:ok, scope} <- validated_scope(scope),
         {:ok, send_id} <- validated_send_id(send_id) do
      {:ok, %CancellationKey{scope: scope, send_id: send_id}}
    end
  end

  @spec validated_scope(term()) :: {:ok, scope()} | {:error, error()}
  defp validated_scope(scope) when is_binary(scope) and scope != "", do: {:ok, scope}
  defp validated_scope(_scope), do: {:error, :invalid_scope}

  @spec validated_send_id(String.t() | nil) :: {:ok, String.t()} | {:error, error()}
  defp validated_send_id(nil), do: {:error, :missing_send_id}
  defp validated_send_id(send_id), do: {:ok, send_id}
end
