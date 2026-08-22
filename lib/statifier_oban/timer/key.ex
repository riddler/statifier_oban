defmodule StatifierOban.Timer.Key do
  @moduledoc """
  Derives the two scoped keys a durable-timer store needs, per ADR-0054
  decision 3 as amended by ADR-0059, and `docs/durable-timers.md` ("Keying
  your store") in statifier-ex.

  The dedup key is the compact `{scope, ordinal}` pair ADR-0059 decision 3
  blesses; the cancellation key is `{scope, send_id}`, which ADR-0059 leaves
  untouched. Because `send_id` is row data rather than a dedup-key component
  here, a cancel matches stored rows through `cancels?/3`, against the row's
  stored effect.

  `scope` is always an argument and never derived: Statifier's counters
  restart for every chart run, so `send_1` (or ordinal `1`) from one run
  addresses the same row as its twin from an unrelated run unless the store
  keeps them apart. It is `ctx.session_id` (spec 5.10's `_sessionid`) for a
  live session, or the host's own durable run id for a process-less host.
  """

  alias Statifier.Effect.{Cancel, SendDelayed}
  alias StatifierOban.Timer.{CancellationKey, DedupKey}

  @type scope :: String.t()
  @type error :: :invalid_scope | :missing_send_id | :missing_ordinal

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
  def dedup_key(scope, %SendDelayed{ordinal: ordinal}) do
    with {:ok, scope} <- validated_scope(scope),
         {:ok, ordinal} <- validated_ordinal(ordinal) do
      {:ok, %DedupKey{scope: scope, ordinal: ordinal}}
    end
  end

  @doc """
  Whether a cancellation key addresses the stored effect under a scope.

  Spec 6.3 cancels every delayed send under a sendid; the stored effect's
  `send_id` is row data, not a dedup-key component, so the match reads it
  off the row rather than off the key.
  """
  @spec cancels?(CancellationKey.t(), scope(), SendDelayed.t()) :: boolean()
  def cancels?(%CancellationKey{scope: scope, send_id: send_id}, scope, %SendDelayed{
        send_id: send_id
      }),
      do: true

  def cancels?(%CancellationKey{}, _scope, %SendDelayed{}), do: false

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

  @spec validated_ordinal(term()) :: {:ok, pos_integer()} | {:error, error()}
  defp validated_ordinal(ordinal) when is_integer(ordinal) and ordinal >= 1, do: {:ok, ordinal}
  defp validated_ordinal(_ordinal), do: {:error, :missing_ordinal}
end
