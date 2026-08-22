defmodule StatifierOban.TestRepo do
  @moduledoc """
  SQLite-backed test repo for the Oban Lite engine, per ADR-0002.

  Test-only: the package ships no repo. Runtime options (database path,
  pool size) come from `test/test_helper.exs`, not `config/` - the package
  has no config directory and does not want one.
  """

  use Ecto.Repo,
    otp_app: :statifier_oban,
    adapter: Ecto.Adapters.SQLite3
end
