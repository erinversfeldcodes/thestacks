defmodule Core.Repo.Migrations.BackfillAndMaintainThePlacementOwner do
  use Ecto.Migration

  # The denormalised owner on op.bookshelf_placements, added one migration back
  # as a nullable uuid. This backfills it and keeps it current, so the owner
  # row-level policy can later become `user_id = op.current_scope()` — the
  # same-table equality an index serves — instead of the `bookshelf_id IN
  # (SELECT …)` sublink that can never be an index condition.
  #
  # A migration, not a data correction, on purpose: Release.deploy runs
  # corrections → migrate → corrections, so a correction would run first,
  # against the schema that does not yet have the column.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '120s'")

    execute("""
    UPDATE op.bookshelf_placements p
       SET user_id = b.user_id
      FROM op.bookshelves b
     WHERE p.bookshelf_id = b.id
       AND p.user_id IS DISTINCT FROM b.user_id
    """)

    # Maintain it on INSERT and on any change of bookshelf_id, so there is no
    # app/DB ordering dependency and no write can land without it. A generated
    # column cannot express this — the value comes from another table.
    #
    # SECURITY INVOKER (the default): the only row a caller may insert is into a
    # bookshelf they own (the placements WITH CHECK enforces that), and the
    # owner can always read that bookshelf, so the lookup resolves. A bookshelf
    # the caller cannot see yields NULL, and the WITH CHECK then rejects the
    # write — which is the correct outcome, not a silent mis-owned row.
    execute("""
    CREATE OR REPLACE FUNCTION op.set_placement_user_id()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        SELECT b.user_id
          INTO NEW.user_id
          FROM op.bookshelves b
         WHERE b.id = NEW.bookshelf_id;
        RETURN NEW;
      END;
      $$
    """)

    execute("""
    CREATE TRIGGER set_placement_user_id
      BEFORE INSERT OR UPDATE OF bookshelf_id ON op.bookshelf_placements
      FOR EACH ROW EXECUTE FUNCTION op.set_placement_user_id()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS set_placement_user_id ON op.bookshelf_placements")
    execute("DROP FUNCTION IF EXISTS op.set_placement_user_id()")
    execute("UPDATE op.bookshelf_placements SET user_id = NULL")
  end
end
