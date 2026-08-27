defmodule StatifierOban.OpaqueTermTest.NonBinaryDecode do
  @moduledoc """
  Test-only codec whose `decode/1` returns a non-binary, for exercising
  `apply_codec/3`'s `{:invalid_return, _}` arm.
  """

  @behaviour StatifierOban.OpaqueTerm.Codec

  @impl StatifierOban.OpaqueTerm.Codec
  def encode(binary), do: {:ok, binary}

  @impl StatifierOban.OpaqueTerm.Codec
  def decode(_binary), do: {:ok, :not_a_binary}
end

defmodule StatifierOban.OpaqueTermTest do
  use ExUnit.Case, async: true

  alias StatifierOban.OpaqueTerm
  alias StatifierOban.OpaqueTermTest.NonBinaryDecode
  alias StatifierOban.TestCodecs.{Boom, NondeterministicXor, Raises, Xor}

  # sabotage: `encode/2`'s nil arm returned an encoded nil payload - went
  # red (the nil round-trip stopped being the bare nil the row stays
  # readable with), reverted.
  test "nil stays nil in both directions" do
    assert {:ok, nil} = OpaqueTerm.encode(nil)
    assert {:ok, nil} = OpaqueTerm.decode_field(%{"data" => nil}, "data")
    assert {:ok, nil} = OpaqueTerm.decode_field(%{}, "data")
  end

  # sabotage: encode(term, nil)'s clause built the payload from the codec
  # arg instead of the plain path - went red (`nil` reached `apply_codec`
  # and blew up), reverted.
  test "nil never reaches a codec, even with one configured" do
    assert {:ok, nil} = OpaqueTerm.encode(nil, Boom)
  end

  # sabotage: `decode/2` dropped the Base64 step - went red (every
  # payload came back {:error, ...}), reverted.
  test "an arbitrary term round-trips byte-identical through the JSON wire" do
    term = %{"k" => [1, :two, {~U[2026-08-22 12:00:00Z], self()}]}

    {:ok, payload} = OpaqueTerm.encode(term)
    args = %{"data" => payload} |> JSON.encode!() |> JSON.decode!()

    assert {:ok, ^term} = OpaqueTerm.decode_field(args, "data")
  end

  # sabotage: `encode/2`'s no-codec arm added the codec tag unconditionally
  # - went red (the exact-map assertion below failed), reverted. This is
  # the byte-identity regression test for every pre-upgrade row: a caller
  # that never configures a codec must keep writing the pre-seam shape.
  test "with no codec the payload is exactly the bare t2b64 map" do
    term = %{"k" => 1}

    assert {:ok, %{"t2b64" => Base.encode64(:erlang.term_to_binary(term))}} ==
             OpaqueTerm.encode(term)
  end

  # sabotage: `decode_field/2`'s catch-all returned {:ok, other} - went
  # red (the malformed rows decoded), reverted.
  test "malformed payloads are typed errors about the row, never raises" do
    assert {:error, {:invalid_field, "data", "plain"}} =
             OpaqueTerm.decode_field(%{"data" => "plain"}, "data")

    assert {:error, {:invalid_field, "data", "!!!"}} =
             OpaqueTerm.decode_field(%{"data" => %{"t2b64" => "!!!"}}, "data")

    corrupt = Base.encode64("not external term format")

    assert {:error, {:invalid_field, "data", _binary}} =
             OpaqueTerm.decode_field(%{"data" => %{"t2b64" => corrupt}}, "data")
  end

  describe "with a codec" do
    # sabotage: `apply_codec/3`'s {:ok, encoded} branch used the plain
    # bytes instead of the codec's transformed bytes - went red (the term
    # decoded without ever needing the codec's decode/1), reverted.
    test "a term round-trips byte-identically through a codec, over the JSON wire" do
      term = %{"k" => [1, :two, {~U[2026-08-22 12:00:00Z], "v"}]}

      {:ok, payload} = OpaqueTerm.encode(term, Xor)
      args = %{"data" => payload} |> JSON.encode!() |> JSON.decode!()

      assert {:ok, ^term} = OpaqueTerm.decode_field(args, "data")
    end

    # sabotage: `apply_codec/3` required `encode/1`'s return to be
    # byte-identical to a fixed sample instead of calling the codec fresh
    # each time - went red (the nondeterministic codec's varying prefix
    # failed the assertion), reverted.
    test "a nondeterministic-but-reversible codec still round-trips" do
      term = {:trace, 42}

      {:ok, payload_a} = OpaqueTerm.encode(term, NondeterministicXor)
      {:ok, payload_b} = OpaqueTerm.encode(term, NondeterministicXor)

      refute payload_a == payload_b

      assert {:ok, ^term} = OpaqueTerm.decode_field(%{"data" => payload_a}, "data")
      assert {:ok, ^term} = OpaqueTerm.decode_field(%{"data" => payload_b}, "data")
    end

    # sabotage: `decode_with_codec/3` ran the codec even without a
    # "codec" tag present - went red (a legacy no-tag payload failed to
    # decode once any codec module existed in the test suite), reverted.
    test "a legacy payload with no codec tag decodes even when the reader configures one" do
      term = %{"legacy" => true}

      {:ok, payload} = OpaqueTerm.encode(term)

      # The reading side ignores whatever it was configured with; only the
      # tag on the row decides.
      assert {:ok, ^term} = OpaqueTerm.decode_field(%{"data" => payload}, "data")
    end

    # sabotage: `resolve_codec/1` skipped the `function_exported?/3` check
    # - went red (an atom naming a module with no `decode/1` resolved
    # anyway instead of erroring), reverted.
    test "a payload tagged with an unresolvable module name is invalid_codec" do
      {:ok, payload} = OpaqueTerm.encode(%{"a" => 1}, Xor)
      tampered = %{payload | "codec" => "Elixir.StatifierOban.NoSuchCodec"}

      assert {:error, {:invalid_codec, "data", "Elixir.StatifierOban.NoSuchCodec"}} =
               OpaqueTerm.decode_field(%{"data" => tampered}, "data")
    end

    # sabotage: `decode_with_codec/3`'s non-string clause matched string
    # names too, using them as `is_binary` - went red (a non-string tag
    # was passed straight to `resolve_codec/1`, raising `FunctionClauseError`
    # instead of returning the typed error), reverted.
    test "a payload tagged with a non-string codec name is invalid_codec" do
      {:ok, payload} = OpaqueTerm.encode(%{"a" => 1}, Xor)
      tampered = %{payload | "codec" => 123}

      assert {:error, {:invalid_codec, "data", 123}} =
               OpaqueTerm.decode_field(%{"data" => tampered}, "data")
    end

    # sabotage: `resolve_and_decode/3` returned {:ok, binary} on a codec
    # {:error, _} instead of wrapping it - went red (a codec's declared
    # failure decoded as if it had succeeded), reverted.
    test "a codec returning {:error, _} at decode is codec_failed" do
      {:ok, payload} = OpaqueTerm.encode(%{"a" => 1}, Xor)
      tampered = %{payload | "codec" => "Elixir.StatifierOban.TestCodecs.Boom"}

      assert {:error, {:codec_failed, "data", Boom, :boom}} =
               OpaqueTerm.decode_field(%{"data" => tampered}, "data")
    end

    # sabotage: `apply_codec/3`'s {:ok, other} clause did not check
    # `is_binary/1` - went red (a codec returning a non-binary decoded as
    # if the non-binary were the bytes), reverted.
    test "a codec returning a non-binary at decode is codec_failed" do
      {:ok, payload} = OpaqueTerm.encode(%{"a" => 1}, NonBinaryDecode)

      assert {:error, {:codec_failed, "data", NonBinaryDecode, {:invalid_return, :not_a_binary}}} =
               OpaqueTerm.decode_field(%{"data" => payload}, "data")
    end

    # sabotage: `apply_codec/3` had no `catch` clause - went red (the raise
    # crashed the test process instead of coming back as data), reverted.
    test "a codec that raises at decode is codec_failed, not a crash" do
      {:ok, payload} = OpaqueTerm.encode(%{"a" => 1}, Xor)
      tampered = %{payload | "codec" => "Elixir.StatifierOban.TestCodecs.Raises"}

      assert {:error, {:codec_failed, "data", Raises, {:raised, :error, _reason}}} =
               OpaqueTerm.decode_field(%{"data" => tampered}, "data")
    end

    # sabotage: `encode/2`'s codec clause returned {:ok, payload} even when
    # `apply_codec/3` reported an error - went red (encode/2 built a
    # payload out of a failed codec run), reverted.
    test "a codec returning {:error, _} at encode fails encode/2 with no payload built" do
      assert {:error, {:codec_failed, Boom, :boom}} = OpaqueTerm.encode(%{"a" => 1}, Boom)
    end

    # sabotage: `apply_codec/3`'s catch clause was removed - went red (the
    # raise propagated out of `encode/2` and crashed the test), reverted.
    test "a codec that raises at encode fails encode/2 with no payload built" do
      assert {:error, {:codec_failed, Raises, {:raised, :error, _reason}}} =
               OpaqueTerm.encode(%{"a" => 1}, Raises)
    end
  end
end
