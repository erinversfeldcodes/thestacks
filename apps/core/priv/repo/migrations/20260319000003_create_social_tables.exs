defmodule Core.Repo.Migrations.CreateSocialTables do
  @moduledoc "Creates op.user_blocks, op.groups, op.group_members, op.group_invitations, and op.visibility_grants."

  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE TYPE op.group_type AS ENUM ('close_friends', 'broadcast', 'subscription');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.group_visibility AS ENUM ('invite_only', 'platform');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.group_member_role AS ENUM ('member', 'moderator');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    execute("""
    DO $$ BEGIN
      CREATE TYPE op.invitation_status AS ENUM ('pending', 'accepted', 'declined');
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    """)

    create table(:user_blocks, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :blocker_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :blocked_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:user_blocks, [:blocker_id, :blocked_id], prefix: "op")

    create table(:groups, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :type, :text, null: false
      add :visibility, :text, null: false, default: "invite_only"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:groups, [:owner_id], prefix: "op")

    create table(:group_members, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id,
          references(:groups, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
        null: false

      add :role, :text, null: false, default: "member"
      add :joined_at, :utc_datetime_usec, null: false, default: fragment("NOW()")

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:group_members, [:group_id, :user_id], prefix: "op")

    create table(:group_invitations, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id,
          references(:groups, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :invited_by_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :invited_user_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :status, :text, null: false, default: "pending"
      add :responded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create index(:group_invitations, [:group_id], prefix: "op")

    create table(:visibility_grants, prefix: "op", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :resource_type, :text, null: false
      add :resource_id, :binary_id, null: false

      add :granted_to_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      add :granted_by_id,
          references(:users, type: :binary_id, prefix: "op", on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:visibility_grants, [:resource_type, :resource_id, :granted_to_id],
             prefix: "op"
           )

    for table_name <- ~w(user_blocks groups group_members group_invitations visibility_grants) do
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
    drop table(:visibility_grants, prefix: "op")
    drop table(:group_invitations, prefix: "op")
    drop table(:group_members, prefix: "op")
    drop table(:groups, prefix: "op")
    drop table(:user_blocks, prefix: "op")

    execute("DROP TYPE IF EXISTS op.invitation_status")
    execute("DROP TYPE IF EXISTS op.group_member_role")
    execute("DROP TYPE IF EXISTS op.group_visibility")
    execute("DROP TYPE IF EXISTS op.group_type")
  end
end
