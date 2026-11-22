defmodule Core.Repo.Migrations.ForbidABookshelfFromChangingOwner do
  use Ecto.Migration

  # The placement owner is denormalised from its bookshelf and maintained by a
  # trigger on INSERT and on a change of bookshelf_id — but NOT on a change of
  # the bookshelf's own user_id. No code path reassigns a bookshelf's owner
  # today (bookshelf_changeset casts :user_id only so creation can set it; every
  # update caller passes visibility alone, and there is no transfer feature), so
  # the gap is latent. It stops being latent the moment a row-level policy trusts
  # placement.user_id, because a reassigned bookshelf would leave its placements'
  # user_id pointing at the previous owner.
  #
  # Rather than grow the maintenance surface to re-fire on bookshelves.user_id
  # changes, forbid the change outright: a bookshelf is personal and does not
  # change hands, so its owner is immutable. That is the stronger guarantee — the
  # denormalised copy cannot drift because the source cannot move — and it is
  # enforced in the database, not by one changeset remembering not to cast a
  # field.
  def up do
    execute("""
    CREATE OR REPLACE FUNCTION op.forbid_bookshelf_owner_change()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
          RAISE EXCEPTION
            'op.bookshelves.user_id is immutable — a bookshelf cannot change owner (placement.user_id is denormalised from it)';
        END IF;
        RETURN NEW;
      END;
      $$
    """)

    execute("""
    CREATE TRIGGER forbid_bookshelf_owner_change
      BEFORE UPDATE OF user_id ON op.bookshelves
      FOR EACH ROW EXECUTE FUNCTION op.forbid_bookshelf_owner_change()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS forbid_bookshelf_owner_change ON op.bookshelves")
    execute("DROP FUNCTION IF EXISTS op.forbid_bookshelf_owner_change()")
  end
end
