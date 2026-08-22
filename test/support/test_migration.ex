defmodule StatifierOban.TestMigration do
  @moduledoc """
  Creates Oban's tables in the SQLite test database (ADR-0002 harness).
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down()
end
