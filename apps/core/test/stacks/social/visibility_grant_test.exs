defmodule Stacks.Social.VisibilityGrantTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Social.VisibilityGrant

  describe "changeset/2" do
    test "is valid with resource_type, resource_id, granted_to, and granted_by" do
      granted_to = insert(:user)
      granted_by = insert(:user)
      resource_id = Ecto.UUID.generate()

      changeset =
        VisibilityGrant.changeset(%VisibilityGrant{}, %{
          resource_type: "bookshelf",
          resource_id: resource_id,
          granted_to_id: granted_to.id,
          granted_by_id: granted_by.id
        })

      assert changeset.valid?
    end

    test "is invalid without resource_type" do
      granted_to = insert(:user)
      granted_by = insert(:user)

      changeset =
        VisibilityGrant.changeset(%VisibilityGrant{}, %{
          resource_id: Ecto.UUID.generate(),
          granted_to_id: granted_to.id,
          granted_by_id: granted_by.id
        })

      refute changeset.valid?
      assert %{resource_type: [_ | _]} = errors_on(changeset)
    end
  end

  describe "unique constraint" do
    test "inserting a duplicate (same resource_type + resource_id + granted_to) raises unique constraint error" do
      granted_to = insert(:user)
      granted_by = insert(:user)
      resource_id = Ecto.UUID.generate()

      insert(:visibility_grant,
        resource_type: "bookshelf",
        resource_id: resource_id,
        granted_to: granted_to,
        granted_by: granted_by
      )

      assert_raise Ecto.ConstraintError, fn ->
        insert(:visibility_grant,
          resource_type: "bookshelf",
          resource_id: resource_id,
          granted_to: granted_to,
          granted_by: granted_by
        )
      end
    end
  end
end
