# ADR-0002 harness: a fresh SQLite database per suite run, migrated with
# Oban's tables. Runtime options live here rather than in config/ - the
# package has no config directory. Oban instances are started per test,
# under the test supervisor, with non-default names (host-supplied shape).

db_path = Path.join(Mix.Project.build_path(), "statifier_oban_test.db")

for file <- Path.wildcard(db_path <> "*"), do: File.rm!(file)

{:ok, _pid} =
  StatifierOban.TestRepo.start_link(
    database: db_path,
    pool_size: 1,
    log: false
  )

Ecto.Migrator.up(StatifierOban.TestRepo, 1, StatifierOban.TestMigration, log: false)

ExUnit.start()
