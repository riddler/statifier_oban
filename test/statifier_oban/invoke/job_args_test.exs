defmodule StatifierOban.Invoke.JobArgsTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias StatifierOban.Invoke.JobArgs

  @invoke %Invoke{
    invoke_id: "inv_1",
    type: "myapp:authorize",
    src: nil,
    params: %{"account_id" => 42, :atom_key => {:tuple, "value"}},
    content: [1, 2, {:three, ~U[2026-08-22 12:00:00Z]}],
    autoforward: true,
    state_index: 3,
    invoke_index: 1,
    macrostep: 7,
    microstep: 2,
    round: 4
  }

  # sabotage: `to_invoke/1` read "invoke_index" for state_index - went
  # red (the rebuilt struct swapped the two counters), reverted.
  test "to_invoke/1 is the exact inverse of from_invoke/3, opaque terms byte-identical" do
    args = JobArgs.from_invoke("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    # What Oban stores is JSON: round-trip through it, as redelivery does.
    args = args |> JSON.encode!() |> JSON.decode!()

    assert {:ok, "sess_ja", "Elixir.StatifierOban.TestInvokeHandler", rebuilt} =
             JobArgs.to_invoke(args)

    assert rebuilt == @invoke
  end

  # sabotage: `fetch_binary/2`'s nil arm returned {:ok, ""} - went red
  # (a missing scope decoded instead of erroring), reverted.
  test "a missing required field is a typed error naming the field" do
    args = JobArgs.from_invoke("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    assert {:error, {:missing_field, "scope"}} = JobArgs.to_invoke(Map.delete(args, "scope"))

    assert {:error, {:missing_field, "invoke_id"}} =
             JobArgs.to_invoke(Map.delete(args, "invoke_id"))

    assert {:error, {:missing_field, "handler"}} = JobArgs.to_invoke(Map.delete(args, "handler"))
  end

  # sabotage: `fetch_non_neg_integer/2` accepted any value - went red
  # (the corrupt row decoded), reverted.
  test "a corrupt counter or opaque payload is a typed error about the row" do
    args = JobArgs.from_invoke("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    assert {:error, {:invalid_field, "macrostep", "seven"}} =
             JobArgs.to_invoke(Map.put(args, "macrostep", "seven"))

    assert {:error, {:invalid_field, "params", "not a payload"}} =
             JobArgs.to_invoke(Map.put(args, "params", "not a payload"))
  end
end
