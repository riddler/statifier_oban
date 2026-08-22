defmodule StatifierOban.Config do
  @moduledoc """
  Configuration for running Statifier effects on a host-supplied Oban
  instance.

  Per ADR-0002, this package never owns, starts, or names an Oban instance:
  the host supplies its own instance's name and every public entry point in
  this package takes it from here. There is no default - not even Oban's own
  default name `Oban` - so a missing instance is a configuration error at
  the call site, never a silent fallback into whatever instance happens to
  be running.

  ## Examples

      iex> StatifierOban.Config.new(oban: MyApp.Oban)
      {:ok, %StatifierOban.Config{oban: MyApp.Oban}}

      iex> StatifierOban.Config.new([])
      {:error, {:missing_option, :oban}}

      iex> StatifierOban.Config.new(oban: MyApp.Oban, queue: :timers)
      {:error, {:unknown_options, [:queue]}}
  """

  @enforce_keys [:oban]
  defstruct [:oban]

  @typedoc """
  The host-supplied Oban configuration.

  `:oban` is the name of the host's Oban instance, as given to
  `Oban.start_link/1` - anything `t:Oban.name/0` allows.
  """
  @type t :: %__MODULE__{oban: Oban.name()}

  @known_options [:oban]

  @doc """
  Builds a config from the host's options.

  `:oban` is required. Unknown options are rejected rather than ignored, so
  a typo fails loudly instead of silently dropping a setting.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- check_unknown(opts),
         {:ok, oban} <- fetch_oban(opts) do
      {:ok, %__MODULE__{oban: oban}}
    end
  end

  defp check_unknown(opts) do
    case Keyword.keys(opts) -- @known_options do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp fetch_oban(opts) do
    case Keyword.fetch(opts, :oban) do
      {:ok, nil} -> {:error, {:missing_option, :oban}}
      {:ok, oban} -> {:ok, oban}
      :error -> {:error, {:missing_option, :oban}}
    end
  end
end
