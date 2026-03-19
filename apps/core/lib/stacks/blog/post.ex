defmodule Stacks.Blog.Post do
  @moduledoc "Schema for op.blog_posts — a user-authored blog post."

  use Ecto.Schema
  import Ecto.Changeset

  alias Stacks.Accounts.User
  alias Stacks.Blog.PostBookAssociation
  alias Stacks.Social.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "op"

  @derive {Jason.Encoder,
           only: [
             :id,
             :user_id,
             :title,
             :body,
             :visibility,
             :visibility_group_id,
             :published_at,
             :created_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "blog_posts" do
    field :title, :string
    field :body, :string
    field :visibility, :string, default: "owner"
    field :published_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :visibility_group, Group, foreign_key: :visibility_group_id

    has_many :book_associations, PostBookAssociation, foreign_key: :post_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @required_fields [:user_id, :title, :body]
  @optional_fields [:visibility, :visibility_group_id, :published_at]

  @valid_visibilities ~w(owner group platform)

  @doc "Changeset for creating or updating a blog post."
  def changeset(post, attrs) do
    post
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:visibility, @valid_visibilities)
  end
end
