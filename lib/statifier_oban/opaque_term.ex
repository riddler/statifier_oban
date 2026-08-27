defmodule StatifierOban.OpaqueTerm do
  @moduledoc """
  Tagged `:erlang.term_to_binary/1` payloads for the host-opaque fields a
  job's args carry.

  Oban args live as JSON, and some Statifier effect fields (`data`,
  `caller_context`, an invoke's `params` and `content`) are arbitrary terms
  with no JSON shape - so they ride as Base64-encoded external term format
  under a single tag key, and come back byte-identical. `nil` stays `nil`,
  so the common case costs nothing and stays readable in the row.

  `encode/2` optionally takes a `StatifierOban.OpaqueTerm.Codec`
  implementation and runs it over the bytes before they are Base64-encoded;
  when it does, the payload also carries the codec's module name under a
  `"codec"` tag, and `decode_field/2` resolves that name and runs the
  codec's `decode/1` before `binary_to_term`. A payload with no `"codec"`
  tag - every row written before a host adopted a codec, and every row
  written with none configured - takes the plain path unchanged, so a
  codec is opt-in per payload, not per deploy.

  Decoding uses `:safe`, so a payload naming an atom the reading node has
  never seen decodes to a typed error rather than minting atoms. Both job
  wire modules (`StatifierOban.Timer.JobArgs`,
  `StatifierOban.Invoke.JobArgs`) share this one encoding, which is what
  keeps their rows mutually readable during an incident.
  """

  @term_tag "t2b64"
  @codec_tag "codec"

  @typedoc "Why `encode/2` could not produce a payload."
  @type encode_error :: {:codec_failed, module(), term()}

  @typedoc "Why a stored payload could not be decoded."
  @type decode_error ::
          {:invalid_field, String.t(), term()}
          | {:invalid_codec, String.t(), term()}
          | {:codec_failed, String.t(), module(), term()}

  @doc """
  Encodes `term` as a tagged payload map, or `nil` for `nil`.

  With no `codec` (the default), the payload is exactly
  `%{"t2b64" => base64}` - byte-identical to every row written before this
  seam existed. With a codec, the payload also carries `"codec"` naming the
  module, and `codec.encode/1` runs over the term's bytes first; a codec
  that fails - returns `{:error, _}`, returns a non-binary, or raises -
  produces `{:error, {:codec_failed, codec, reason}}` with no payload
  built. `nil` never reaches the codec: the `nil` arm is unconditional, so
  the row stays readable either way.
  """
  @spec encode(term(), module() | nil) ::
          {:ok, nil | %{String.t() => String.t()}} | {:error, encode_error()}
  def encode(term, codec \\ nil)
  def encode(nil, _codec), do: {:ok, nil}

  def encode(term, nil),
    do: {:ok, %{@term_tag => Base.encode64(:erlang.term_to_binary(term))}}

  def encode(term, codec) when is_atom(codec) do
    binary = :erlang.term_to_binary(term)

    case apply_codec(codec, :encode, binary) do
      {:ok, encoded} ->
        {:ok, %{@term_tag => Base.encode64(encoded), @codec_tag => Atom.to_string(codec)}}

      {:error, reason} ->
        {:error, {:codec_failed, codec, reason}}
    end
  end

  @doc """
  Decodes the tagged payload stored under `field` in `args`.

  A missing or `nil` field decodes to `{:ok, nil}` - the exact inverse of
  `encode/2`'s `nil` arm. A payload carrying a `"codec"` tag resolves that
  module name and runs its `decode/1` on the Base64-decoded bytes before
  `binary_to_term`, ignoring whatever codec (if any) this call's own
  caller configured - the tag on the row, not the reader's configuration,
  decides. Anything that is neither `nil` nor a well-formed tagged payload
  is a typed error about the row, returned as data rather than raised: the
  caller (a worker at its boundary) decides what a corrupt row costs.
  """
  @spec decode_field(map(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  def decode_field(args, field) when is_map(args) and is_binary(field) do
    case Map.get(args, field) do
      nil -> {:ok, nil}
      %{@term_tag => encoded} = payload when is_binary(encoded) -> decode(field, payload)
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec decode(String.t(), map()) :: {:ok, term()} | {:error, decode_error()}
  defp decode(field, payload) do
    encoded = Map.fetch!(payload, @term_tag)

    with {:ok, binary} <- base64_decode(field, encoded),
         {:ok, binary} <- decode_with_codec(field, payload, binary) do
      safe_binary_to_term(field, binary)
    end
  end

  @spec base64_decode(String.t(), String.t()) :: {:ok, binary()} | {:error, decode_error()}
  defp base64_decode(field, encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, {:invalid_field, field, encoded}}
    end
  end

  @spec decode_with_codec(String.t(), map(), binary()) ::
          {:ok, binary()} | {:error, decode_error()}
  defp decode_with_codec(field, payload, binary) do
    case Map.fetch(payload, @codec_tag) do
      :error -> {:ok, binary}
      {:ok, name} when is_binary(name) -> resolve_and_decode(field, name, binary)
      {:ok, other} -> {:error, {:invalid_codec, field, other}}
    end
  end

  @spec resolve_and_decode(String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, decode_error()}
  defp resolve_and_decode(field, name, binary) do
    case resolve_codec(name) do
      {:ok, module} ->
        case apply_codec(module, :decode, binary) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:codec_failed, field, module, reason}}
        end

      :error ->
        {:error, {:invalid_codec, field, name}}
    end
  end

  # Same shape as `StatifierOban.Timer.Worker.resolve_delivery/1`: a name
  # this node cannot resolve to a loaded module exporting `decode/1` is
  # deploy-shaped, not a crash.
  @spec resolve_codec(String.t()) :: {:ok, module()} | :error
  defp resolve_codec(name) do
    module = String.to_existing_atom(name)

    if Code.ensure_loaded?(module) and function_exported?(module, :decode, 1) do
      {:ok, module}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  # The one place a codec is called, on both sides. A boundary, not a leaf:
  # `{:ok, binary}` passes through, any other return is a typed error, and a
  # raise or exit out of a host codec is caught here and returned as data
  # rather than crashing the job.
  @spec apply_codec(module(), :encode | :decode, binary()) :: {:ok, binary()} | {:error, term()}
  defp apply_codec(codec, function, binary) do
    case apply(codec, function, [binary]) do
      {:ok, result} when is_binary(result) -> {:ok, result}
      {:ok, other} -> {:error, {:invalid_return, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_return, other}}
    end
  catch
    kind, reason -> {:error, {:raised, kind, reason}}
  end

  @spec safe_binary_to_term(String.t(), binary()) :: {:ok, term()} | {:error, decode_error()}
  defp safe_binary_to_term(field, binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    # :safe rejects a payload naming atoms this node has never seen, and a
    # corrupt binary raises too - both are facts about the row, returned
    # as data rather than crashed on (this is the boundary, not a leaf).
    ArgumentError -> {:error, {:invalid_field, field, binary}}
  end
end
