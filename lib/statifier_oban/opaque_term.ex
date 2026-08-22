defmodule StatifierOban.OpaqueTerm do
  @moduledoc """
  Tagged `:erlang.term_to_binary/1` payloads for the host-opaque fields a
  job's args carry.

  Oban args live as JSON, and some Statifier effect fields (`data`,
  `caller_context`, an invoke's `params` and `content`) are arbitrary terms
  with no JSON shape - so they ride as Base64-encoded external term format
  under a single tag key, and come back byte-identical. `nil` stays `nil`,
  so the common case costs nothing and stays readable in the row.

  Decoding uses `:safe`, so a payload naming an atom the reading node has
  never seen decodes to a typed error rather than minting atoms. Both job
  wire modules (`StatifierOban.Timer.JobArgs`,
  `StatifierOban.Invoke.JobArgs`) share this one encoding, which is what
  keeps their rows mutually readable during an incident.
  """

  @term_tag "t2b64"

  @typedoc "Why a stored payload could not be decoded."
  @type decode_error :: {:invalid_field, String.t(), term()}

  @doc """
  Encodes `term` as a tagged payload map, or `nil` for `nil`.
  """
  @spec encode(term()) :: nil | %{String.t() => String.t()}
  def encode(nil), do: nil

  def encode(term),
    do: %{@term_tag => Base.encode64(:erlang.term_to_binary(term))}

  @doc """
  Decodes the tagged payload stored under `field` in `args`.

  A missing or `nil` field decodes to `{:ok, nil}` - the exact inverse of
  `encode/1`'s `nil` arm. Anything that is neither `nil` nor a well-formed
  tagged payload is a typed error about the row, returned as data rather
  than raised: the caller (a worker at its boundary) decides what a corrupt
  row costs.
  """
  @spec decode_field(map(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  def decode_field(args, field) when is_map(args) and is_binary(field) do
    case Map.get(args, field) do
      nil -> {:ok, nil}
      %{@term_tag => encoded} when is_binary(encoded) -> decode(field, encoded)
      other -> {:error, {:invalid_field, field, other}}
    end
  end

  @spec decode(String.t(), String.t()) :: {:ok, term()} | {:error, decode_error()}
  defp decode(field, encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> safe_binary_to_term(field, binary)
      :error -> {:error, {:invalid_field, field, encoded}}
    end
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
