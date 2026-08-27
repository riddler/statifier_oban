defmodule StatifierOban.TestCodecs.Xor do
  @moduledoc """
  A reversible, deterministic `StatifierOban.OpaqueTerm.Codec`: xors every
  byte against a fixed key byte. Not cryptography - a two-line proof that
  the seam calls a codec's `encode/1` and `decode/1` and round-trips
  whatever they return.
  """

  @behaviour StatifierOban.OpaqueTerm.Codec

  @key 0x5A

  @impl StatifierOban.OpaqueTerm.Codec
  @spec encode(binary()) :: {:ok, binary()}
  def encode(binary), do: {:ok, transform(binary)}

  @impl StatifierOban.OpaqueTerm.Codec
  @spec decode(binary()) :: {:ok, binary()}
  def decode(binary), do: {:ok, transform(binary)}

  @spec transform(binary()) :: binary()
  defp transform(binary) do
    for <<byte <- binary>>, into: <<>>, do: <<Bitwise.bxor(byte, @key)>>
  end
end

defmodule StatifierOban.TestCodecs.NondeterministicXor do
  @moduledoc """
  A `StatifierOban.OpaqueTerm.Codec` whose `encode/1` is nondeterministic
  (a random four-byte prefix) but whose `decode/1` still reverses it
  exactly, proving the seam's round-trip contract does not require
  `encode/1` to be pure.
  """

  @behaviour StatifierOban.OpaqueTerm.Codec

  @impl StatifierOban.OpaqueTerm.Codec
  @spec encode(binary()) :: {:ok, binary()}
  def encode(binary), do: {:ok, :crypto.strong_rand_bytes(4) <> binary}

  @impl StatifierOban.OpaqueTerm.Codec
  @spec decode(binary()) :: {:ok, binary()}
  def decode(<<_prefix::binary-size(4), binary::binary>>), do: {:ok, binary}
end

defmodule StatifierOban.TestCodecs.Boom do
  @moduledoc """
  A `StatifierOban.OpaqueTerm.Codec` whose `encode/1` and `decode/1` both
  fail outright, for exercising `{:codec_failed, ...}` on either side of
  the seam.
  """

  @behaviour StatifierOban.OpaqueTerm.Codec

  @impl StatifierOban.OpaqueTerm.Codec
  @spec encode(binary()) :: {:error, :boom}
  def encode(_binary), do: {:error, :boom}

  @impl StatifierOban.OpaqueTerm.Codec
  @spec decode(binary()) :: {:error, :boom}
  def decode(_binary), do: {:error, :boom}
end

defmodule StatifierOban.TestCodecs.Raises do
  @moduledoc """
  A `StatifierOban.OpaqueTerm.Codec` whose `encode/1` and `decode/1` both
  raise, for exercising the boundary catch in `StatifierOban.OpaqueTerm`'s
  `apply_codec/3` - a codec blowing up must come back as a typed error,
  never crash the caller.
  """

  @behaviour StatifierOban.OpaqueTerm.Codec

  @impl StatifierOban.OpaqueTerm.Codec
  @spec encode(binary()) :: no_return()
  def encode(_binary), do: raise("encode blew up")

  @impl StatifierOban.OpaqueTerm.Codec
  @spec decode(binary()) :: no_return()
  def decode(_binary), do: raise("decode blew up")
end
