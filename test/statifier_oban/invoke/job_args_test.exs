defmodule StatifierOban.Invoke.JobArgsTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias StatifierOban.Invoke.JobArgs
  alias StatifierOban.TestCodecs.{Boom, Raises, Xor}

  defp from_invoke!(scope, handler, invoke, codec \\ nil) do
    {:ok, args} = JobArgs.from_invoke(scope, handler, invoke, codec)
    args
  end

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
    round: 4,
    caller_context: %{
      "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }
  }

  # sabotage: `to_invoke/1` read "invoke_index" for state_index - went
  # red (the rebuilt struct swapped the two counters), reverted.
  test "to_invoke/1 is the exact inverse of from_invoke/4, opaque terms byte-identical" do
    args = from_invoke!("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    # What Oban stores is JSON: round-trip through it, as redelivery does.
    args = args |> JSON.encode!() |> JSON.decode!()

    assert {:ok, "sess_ja", "Elixir.StatifierOban.TestInvokeHandler", rebuilt} =
             JobArgs.to_invoke(args)

    assert rebuilt == @invoke
  end

  # sabotage: `fetch_binary/2`'s nil arm returned {:ok, ""} - went red
  # (a missing scope decoded instead of erroring), reverted.
  test "a missing required field is a typed error naming the field" do
    args = from_invoke!("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    assert {:error, {:missing_field, "scope"}} = JobArgs.to_invoke(Map.delete(args, "scope"))

    assert {:error, {:missing_field, "invoke_id"}} =
             JobArgs.to_invoke(Map.delete(args, "invoke_id"))

    assert {:error, {:missing_field, "handler"}} = JobArgs.to_invoke(Map.delete(args, "handler"))
  end

  # sabotage: `fetch_non_neg_integer/2` accepted any value - went red
  # (the corrupt row decoded), reverted.
  test "a corrupt counter or opaque payload is a typed error about the row" do
    args = from_invoke!("sess_ja", StatifierOban.TestInvokeHandler, @invoke)

    assert {:error, {:invalid_field, "macrostep", "seven"}} =
             JobArgs.to_invoke(Map.put(args, "macrostep", "seven"))

    assert {:error, {:invalid_field, "params", "not a payload"}} =
             JobArgs.to_invoke(Map.put(args, "params", "not a payload"))
  end

  # sabotage: encode_term/3 (Invoke.JobArgs) passed `nil` instead of the
  # caller's `codec` to `OpaqueTerm.encode/2` - went red (the payload
  # carried no "codec" tag), reverted.
  test "params and content round-trip through a codec" do
    args =
      "sess_ja"
      |> from_invoke!(StatifierOban.TestInvokeHandler, @invoke, Xor)
      |> JSON.encode!()
      |> JSON.decode!()

    assert %{"codec" => "Elixir.StatifierOban.TestCodecs.Xor"} = args["params"]

    assert {:ok, "sess_ja", "Elixir.StatifierOban.TestInvokeHandler", rebuilt} =
             JobArgs.to_invoke(args)

    assert rebuilt == @invoke
  end

  describe "codec failures" do
    # sabotage: encode_term/3 (Invoke.JobArgs) swallowed the codec's
    # {:error, reason} and returned {:ok, nil} - went red (from_invoke/4
    # returned {:ok, _} instead of the error), reverted.
    test "from_invoke/4 fails closed when the codec's encode/1 fails" do
      assert {:error, {:codec_failed, "params", {:codec_failed, Boom, :boom}}} =
               JobArgs.from_invoke("sess_ja", StatifierOban.TestInvokeHandler, @invoke, Boom)
    end

    # sabotage: apply_codec/3 (OpaqueTerm) let a raise propagate instead of
    # catching it - went red (the test process crashed instead of getting
    # an error tuple), reverted.
    test "from_invoke/4 fails closed when the codec's encode/1 raises" do
      assert {:error,
              {:codec_failed, "params", {:codec_failed, Raises, {:raised, _kind, _reason}}}} =
               JobArgs.from_invoke("sess_ja", StatifierOban.TestInvokeHandler, @invoke, Raises)
    end
  end

  # -- caller_context (st-ADR-0063, sob-10x) --------------------------------

  # sabotage: dropped `caller_context: caller_context` from `to_invoke/1`'s
  # rebuilt struct - went red (the rebuilt effect reported caller_context:
  # nil while the row still carried the payload), reverted.
  test "caller_context is stored opaquely and comes back byte-identical" do
    context = {:trace, 123_456_789, :span, ~U[2026-09-02 12:00:00Z]}
    invoke = %{@invoke | caller_context: context}

    args = from_invoke!("sess_cc", StatifierOban.TestInvokeHandler, invoke)

    # Opaque, not JSON: the slot is an arbitrary host term, so it rides as
    # a tagged term_to_binary payload exactly as params and content do.
    assert %{"t2b64" => _} = args["caller_context"]

    args = args |> JSON.encode!() |> JSON.decode!()

    assert {:ok, "sess_cc", _handler, rebuilt} = JobArgs.to_invoke(args)
    assert rebuilt.caller_context == context
  end

  # sabotage: `from_invoke/4` passed `nil` instead of `codec` for the
  # caller_context field - went red (the stored payload carried no "codec"
  # tag and the plain bytes were readable), reverted.
  test "caller_context runs through the host codec like the other opaque fields" do
    invoke = %{@invoke | caller_context: %{"traceparent" => "00-ab"}}

    args = from_invoke!("sess_cc_codec", StatifierOban.TestInvokeHandler, invoke, Xor)

    assert %{"t2b64" => _, "codec" => "Elixir.StatifierOban.TestCodecs.Xor"} =
             args["caller_context"]

    refute args["caller_context"]["t2b64"] ==
             Base.encode64(:erlang.term_to_binary(invoke.caller_context))

    # The tag on the row decides, not the reading caller's configuration.
    assert {:ok, _scope, _handler, rebuilt} = JobArgs.to_invoke(args)
    assert rebuilt.caller_context == invoke.caller_context
  end

  # sabotage: `to_invoke/1`'s caller_context clause was changed to
  # `Map.fetch!(args, "caller_context")` - went red (a row written before
  # the field existed raised instead of decoding to nil), reverted. This
  # is what makes the field additive over stored rows, not a migration.
  test "a row written before the field existed decodes to a nil caller_context" do
    args =
      "sess_cc_old"
      |> from_invoke!(StatifierOban.TestInvokeHandler, @invoke)
      |> Map.delete("caller_context")

    assert {:ok, "sess_cc_old", _handler, rebuilt} = JobArgs.to_invoke(args)
    assert rebuilt.caller_context == nil
  end

  # sabotage: `from_invoke/4`'s caller_context arm encoded `invoke.params`
  # instead - went red (the nil slot came back as the params map),
  # reverted.
  test "no context attached stays nil through the round trip, and stays out of the row" do
    invoke = %{@invoke | caller_context: nil}

    args = from_invoke!("sess_cc_nil", StatifierOban.TestInvokeHandler, invoke)

    assert args["caller_context"] == nil

    assert {:ok, _scope, _handler, rebuilt} =
             JobArgs.to_invoke(args |> JSON.encode!() |> JSON.decode!())

    assert rebuilt.caller_context == nil
  end
end
