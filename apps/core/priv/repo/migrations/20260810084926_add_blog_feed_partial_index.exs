defmodule Core.Repo.Migrations.AddBlogFeedPartialIndex do
  use Ecto.Migration

  # CONCURRENTLY cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The syndication feed's exact slice (US-6.2.1 §5): a writer's public,
  # syndicated, published posts, newest first. Partial because the feed only
  # ever asks for that slice — hand-written since the proto.sync generator has
  # no `where:` support.
  def change do
    create index(:blog_posts, [:user_id, desc: :published_at],
             prefix: "op",
             name: "blog_posts_user_public_published_idx",
             where: "visibility = 'public' AND syndicated AND published_at IS NOT NULL",
             concurrently: true
           )
  end
end
