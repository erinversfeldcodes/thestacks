defmodule Core.Repo.Migrations.CreateBlogTables do
  @moduledoc "Creates op.blog_posts and op.post_book_associations."

  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.post_visibility AS ENUM ('owner', 'group', 'platform');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.association_source AS ENUM ('llm', 'manual');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:blog_posts, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :title, :text, null: false
      add :body, :text, null: false
      add :visibility, :text, null: false, default: "owner"

      add :visibility_group_id,
          references(:groups, type: :binary_id, prefix: "op", on_delete: :nilify_all)

      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:blog_posts, [:user_id], prefix: "op")

    create table(:post_book_associations, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :post_id,
          references(:blog_posts, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :book_id, references(:books, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :confidence, :float, null: false
      add :reasoning, :text
      add :source, :text, null: false, default: "llm"
      add :visible, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create index(:post_book_associations, [:post_id], prefix: "op")

    for table_name <- ~w(blog_posts post_book_associations) do
      execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
            GRANT SELECT ON op.#{table_name} TO stacks_dbt;
          END IF;
        END $$;
        """,
        """
        DO $$ BEGIN
          IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'stacks_dbt') THEN
            REVOKE SELECT ON op.#{table_name} FROM stacks_dbt;
          END IF;
        END $$;
        """
      )
    end
  end

  def down do
    drop table(:post_book_associations, prefix: "op")
    drop table(:blog_posts, prefix: "op")

    execute("DROP TYPE IF EXISTS op.association_source")
    execute("DROP TYPE IF EXISTS op.post_visibility")
  end
end
