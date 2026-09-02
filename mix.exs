defmodule StatifierOban.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/riddler/statifier_oban"

  def project do
    [
      app: :statifier_oban,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "StatifierOban",
      description: "Durable timers and async invoke execution for Statifier, backed by Oban",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches.
  defp docs do
    [
      name: "StatifierOban",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier_oban",
      source_url: @source_url,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      name: "statifier_oban",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      statifier_dep(),
      {:oban, "~> 2.19"},
      # Declared directly rather than leaned on transitively: ADR-0006
      # makes `StatifierOban.Telemetry` public API, so `:telemetry` is a
      # requirement of this package's own surface, not an artifact of
      # Oban's. The floor matches statifier's and Oban's.
      {:telemetry, "~> 1.3"},

      # Dev / test
      {:ecto_sqlite3, "~> 0.24", only: :test},
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  #
  # The requirement floor is 2.5: this package reads
  # `%Statifier.Effect.Invoke{}.caller_context` and hands it to
  # `Statifier.Invoke.Answer.done/4` / `failed/4` (the invoke half of
  # st-ADR-0063), and all three first shipped in statifier 2.5.0. The
  # earlier floor was 2.2, for `Statifier.Session.failed_invocation/3`
  # (st-ADR-0068), the door
  # `StatifierOban.Invoke.Delivery.Session.deliver_failure/3` calls; 2.5
  # subsumes it.
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil ->
        {:statifier, "~> 2.5"}

      path ->
        {:statifier, path: path, override: true}
    end
  end
end
