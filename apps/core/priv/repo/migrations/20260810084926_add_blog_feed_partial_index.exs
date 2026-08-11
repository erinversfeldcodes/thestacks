defmodule Core.Repo.Migrations.AddBlogFeedPartialIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:blog_posts, [:user_id, desc: :published_at],
             prefix: "op",
             name: "blog_posts_user_public_published_idx",
             where: "visibility = 'public' AND syndicated AND published_at IS NOT NULL",
             concurrently: true
           )
  end
end
