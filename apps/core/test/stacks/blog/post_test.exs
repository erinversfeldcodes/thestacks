defmodule Stacks.Blog.PostTest do
  use Core.DataCase, async: true

  import Stacks.Factory

  alias Stacks.Blog
  alias Stacks.Blog.Post

  describe "post_changeset/2" do
    test "is valid with user, title, body, and visibility" do
      user = insert(:user)

      changeset =
        Blog.post_changeset(%Post{}, %{
          user_id: user.id,
          title: "My First Post",
          body: "Some markdown body.",
          visibility: "owner"
        })

      assert changeset.valid?
    end

    test "is invalid without title" do
      user = insert(:user)

      changeset =
        Blog.post_changeset(%Post{}, %{
          user_id: user.id,
          body: "Some markdown body.",
          visibility: "owner"
        })

      refute changeset.valid?
      assert %{title: [_ | _]} = errors_on(changeset)
    end

    test "is invalid without body" do
      user = insert(:user)

      changeset =
        Blog.post_changeset(%Post{}, %{
          user_id: user.id,
          title: "A Title",
          visibility: "owner"
        })

      refute changeset.valid?
      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "is invalid with an unknown visibility value" do
      user = insert(:user)

      changeset =
        Blog.post_changeset(%Post{}, %{
          user_id: user.id,
          title: "A Title",
          body: "Some markdown body.",
          visibility: "invisible"
        })

      refute changeset.valid?
      assert %{visibility: [_ | _]} = errors_on(changeset)
    end

    test "published_at is nil by default (draft)" do
      user = insert(:user)

      changeset =
        Blog.post_changeset(%Post{}, %{
          user_id: user.id,
          title: "Draft Post",
          body: "Body text.",
          visibility: "owner"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :published_at) == nil
    end
  end
end
