defmodule Stacks.VisibilityTelemetryTest do
  @moduledoc """
  Firing tests for the visibility/social observability counters added in
  Issue #197 (punch #20 of the #122 privacy/visibility epic).

  Verifies that telemetry events fire with the right measurements and
  metadata for:
  - profile-visibility change by direction (tighten / loosen / same)
  - visibility recap outcome + cap counts (bookshelves / placements / posts)
  - block / unblock counts
  - block error rates (cannot_block_self, already_blocked)
  - `:rate_limit_social` (generic rate-limit) hit counts by bucket
  - ViewAs usage + error counts by perspective
  - visibility ceiling-rejection counts by resource_type
  - robots.txt / crawler fetch counts

  Metadata tags are whitelisted atoms only — no raw user input (uuids,
  perspective strings) is ever passed as a telemetry tag.
  """

  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts
  alias Stacks.Accounts.Guardian
  alias Stacks.Blog
  alias Stacks.Social
  alias Stacks.Visibility
  alias Stacks.Workers.VisibilityRecapJob
  alias StacksWeb.Plugs.CrawlerTelemetry
  alias StacksWeb.Plugs.RateLimiter
  alias StacksWeb.Plugs.ViewAsPlug
  alias StacksWeb.SocialController

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp attach_telemetry(events) do
    test_pid = self()
    ref = make_ref()
    handler_id = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ── Profile-visibility change direction ──────────────────────────────────

  describe "profile visibility change telemetry" do
    test "emits tighten when moving platform -> owner" do
      attach_telemetry([[:stacks, :visibility, :profile_change]])
      user = insert(:user, profile_visibility: "platform")

      {:ok, _} = Accounts.update_profile_visibility(user.id, "owner")

      assert_receive {:telemetry_event, [:stacks, :visibility, :profile_change], %{count: 1},
                      %{direction: :tighten}}
    end

    test "emits loosen when moving owner -> platform" do
      attach_telemetry([[:stacks, :visibility, :profile_change]])
      user = insert(:user, profile_visibility: "owner")

      {:ok, _} = Accounts.update_profile_visibility(user.id, "platform")

      assert_receive {:telemetry_event, [:stacks, :visibility, :profile_change], %{count: 1},
                      %{direction: :loosen}}
    end

    test "classify direction helper whitelists to :tighten/:loosen/:same" do
      assert Visibility.classify_visibility_direction("platform", "owner") == :tighten
      assert Visibility.classify_visibility_direction("owner", "platform") == :loosen
      assert Visibility.classify_visibility_direction("owner", "owner") == :same
    end
  end

  # ── Visibility recap outcome + cap counts ────────────────────────────────

  describe "visibility recap telemetry" do
    test "emits recap with :capped outcome and cap counts" do
      attach_telemetry([[:stacks, :visibility, :recap]])
      user = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: user, visibility: "platform")
      _placement = insert(:placement, bookshelf: bookshelf, visibility: "platform")

      assert :ok =
               VisibilityRecapJob.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "new_visibility" => "owner"}
               })

      assert_receive {:telemetry_event, [:stacks, :visibility, :recap],
                      %{
                        bookshelves_capped: bookshelves,
                        placements_capped: placements,
                        posts_capped: _posts
                      }, %{outcome: :capped}}

      assert bookshelves >= 1
      assert placements >= 1
    end

    test "emits recap with :noop outcome when ceiling is platform" do
      attach_telemetry([[:stacks, :visibility, :recap]])
      user = insert(:user, profile_visibility: "platform")

      assert :ok =
               VisibilityRecapJob.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "new_visibility" => "platform"}
               })

      assert_receive {:telemetry_event, [:stacks, :visibility, :recap],
                      %{bookshelves_capped: 0, placements_capped: 0, posts_capped: 0},
                      %{outcome: :noop}}
    end
  end

  # ── Block / unblock counts ───────────────────────────────────────────────

  describe "block / unblock telemetry" do
    test "emits block on successful block_user" do
      attach_telemetry([[:stacks, :social, :block]])
      blocker = insert(:user)
      blocked = insert(:user)

      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      assert_receive {:telemetry_event, [:stacks, :social, :block], %{count: 1}, %{}}
    end

    test "emits unblock on successful unblock_user" do
      attach_telemetry([[:stacks, :social, :unblock]])
      blocker = insert(:user)
      blocked = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      {:ok, :unblocked} = Social.unblock_user(blocker.id, blocked.id)

      assert_receive {:telemetry_event, [:stacks, :social, :unblock], %{count: 1}, %{}}
    end
  end

  # ── Block error rates ────────────────────────────────────────────────────

  describe "block error telemetry" do
    test "emits block_error :already_blocked on duplicate block" do
      attach_telemetry([[:stacks, :social, :block_error]])
      blocker = insert(:user)
      blocked = insert(:user)
      {:ok, _} = Social.block_user(blocker.id, blocked.id)

      {:error, _} = Social.block_user(blocker.id, blocked.id)

      assert_receive {:telemetry_event, [:stacks, :social, :block_error], %{count: 1},
                      %{reason: :already_blocked}}
    end

    test "emits block_error :cannot_block_self via controller", %{conn: conn} do
      attach_telemetry([[:stacks, :social, :block_error]])
      user = insert(:user)

      conn = Guardian.Plug.put_current_resource(conn, user)
      resp = SocialController.block(conn, %{"id" => user.id})

      assert resp.status == 422

      assert_receive {:telemetry_event, [:stacks, :social, :block_error], %{count: 1},
                      %{reason: :cannot_block_self}}
    end
  end

  # ── Rate-limit hit counts (generic, tagged by bucket) ────────────────────

  describe "rate limit telemetry" do
    setup do
      original = Application.get_env(:core, :rate_limiting_enabled)
      Application.put_env(:core, :rate_limiting_enabled, true)

      on_exit(fn ->
        Application.put_env(:core, :rate_limiting_enabled, original)

        if :ets.whereis(:rate_limiter) != :undefined do
          :ets.delete_all_objects(:rate_limiter)
        end
      end)

      :ok
    end

    test "emits rate_limit hit tagged :social when the social bucket is exceeded", %{conn: conn} do
      attach_telemetry([[:stacks, :rate_limit, :hit]])
      user = insert(:user)
      conn = assign(conn, :guardian_default_resource, user)

      # Social bucket limit is 20/min; the 21st call within the window trips it.
      Enum.each(1..21, fn _ -> RateLimiter.call(conn, bucket: :social) end)

      assert_receive {:telemetry_event, [:stacks, :rate_limit, :hit], %{count: 1},
                      %{bucket: :social}}
    end
  end

  # ── ViewAs usage + error counts ──────────────────────────────────────────

  describe "view_as usage telemetry" do
    defp view_as_conn(conn, params) do
      conn
      |> Map.put(:query_params, params)
      |> ViewAsPlug.call(ViewAsPlug.init([]))
    end

    test "emits usage :unauthenticated on parse", %{conn: conn} do
      attach_telemetry([[:stacks, :view_as, :usage]])

      view_as_conn(conn, %{"view_as" => "unauthenticated"})

      assert_receive {:telemetry_event, [:stacks, :view_as, :usage], %{count: 1},
                      %{perspective: :unauthenticated}}
    end

    test "emits usage :specific_user without leaking the uuid", %{conn: conn} do
      attach_telemetry([[:stacks, :view_as, :usage]])
      uuid = Ecto.UUID.generate()

      view_as_conn(conn, %{"view_as" => "user:#{uuid}"})

      assert_receive {:telemetry_event, [:stacks, :view_as, :usage], %{count: 1}, metadata}
      assert metadata.perspective == :specific_user
      refute Map.has_key?(metadata, :id)
    end

    test "emits error :invalid_perspective on unknown perspective", %{conn: conn} do
      attach_telemetry([[:stacks, :view_as, :error]])

      view_as_conn(conn, %{"view_as" => "nonsense"})

      assert_receive {:telemetry_event, [:stacks, :view_as, :error], %{count: 1},
                      %{reason: :invalid_perspective, phase: :parse}}
    end

    test "emits error :not_implemented on group perspective", %{conn: conn} do
      attach_telemetry([[:stacks, :view_as, :error]])

      view_as_conn(conn, %{"view_as" => "group:#{Ecto.UUID.generate()}"})

      assert_receive {:telemetry_event, [:stacks, :view_as, :error], %{count: 1},
                      %{reason: :not_implemented, phase: :parse}}
    end

    test "emits error :forbidden on unauthorized authorize phase", %{conn: conn} do
      attach_telemetry([[:stacks, :view_as, :error]])
      viewer = insert(:user)
      other_owner_id = Ecto.UUID.generate()

      conn =
        conn
        |> assign(:requested_perspective, {:specific_user, Ecto.UUID.generate()})
        |> Guardian.Plug.put_current_resource(viewer)

      resp = ViewAsPlug.authorize_view_as(conn, other_owner_id)

      assert resp.status == 403

      assert_receive {:telemetry_event, [:stacks, :view_as, :error], %{count: 1},
                      %{reason: :forbidden, phase: :authorize}}
    end
  end

  # ── Ceiling-rejection counts ─────────────────────────────────────────────

  describe "ceiling rejection telemetry" do
    test "emits ceiling_rejection helper with whitelisted resource_type" do
      attach_telemetry([[:stacks, :visibility, :ceiling_rejection]])

      Visibility.emit_ceiling_rejection(:placement)

      assert_receive {:telemetry_event, [:stacks, :visibility, :ceiling_rejection], %{count: 1},
                      %{resource_type: :placement}}
    end

    test "coerces unknown resource_type to :other" do
      attach_telemetry([[:stacks, :visibility, :ceiling_rejection]])

      Visibility.emit_ceiling_rejection(:wildcard_thing)

      assert_receive {:telemetry_event, [:stacks, :visibility, :ceiling_rejection], %{count: 1},
                      %{resource_type: :other}}
    end

    test "fires :post when a blog post exceeds the profile ceiling" do
      attach_telemetry([[:stacks, :visibility, :ceiling_rejection]])
      user = insert(:user, profile_visibility: "owner")

      {:error, :visibility_ceiling} =
        Blog.create_post(user, %{title: "T", body: "B", visibility: "platform"})

      assert_receive {:telemetry_event, [:stacks, :visibility, :ceiling_rejection], %{count: 1},
                      %{resource_type: :post}}
    end

    test "fires :placement when a placement exceeds the bookshelf ceiling" do
      attach_telemetry([[:stacks, :visibility, :ceiling_rejection]])
      user = insert(:user)
      bookshelf = insert(:bookshelf, user: user, visibility: "owner")
      placement = insert(:placement, bookshelf: bookshelf, visibility: "owner")

      {:error, _} = Stacks.Shelving.update_placement_visibility(placement.id, user.id, "platform")

      assert_receive {:telemetry_event, [:stacks, :visibility, :ceiling_rejection], %{count: 1},
                      %{resource_type: :placement}}
    end

    test "fires :bookshelf when a bookshelf exceeds the profile ceiling" do
      attach_telemetry([[:stacks, :visibility, :ceiling_rejection]])
      user = insert(:user, profile_visibility: "owner")
      bookshelf = insert(:bookshelf, user: user, visibility: "owner")

      {:error, _} = Stacks.Shelving.update_bookshelf_visibility(bookshelf.id, user.id, "platform")

      assert_receive {:telemetry_event, [:stacks, :visibility, :ceiling_rejection], %{count: 1},
                      %{resource_type: :bookshelf}}
    end
  end

  # ── Crawler / robots.txt fetch counts ────────────────────────────────────

  describe "crawler telemetry" do
    test "emits robots_fetch when /robots.txt is requested", %{conn: conn} do
      attach_telemetry([[:stacks, :crawler, :robots_fetch]])

      conn
      |> Map.put(:request_path, "/robots.txt")
      |> CrawlerTelemetry.call(CrawlerTelemetry.init([]))

      assert_receive {:telemetry_event, [:stacks, :crawler, :robots_fetch], %{count: 1}, %{}}
    end

    test "does not emit for non-robots paths", %{conn: conn} do
      attach_telemetry([[:stacks, :crawler, :robots_fetch]])

      conn
      |> Map.put(:request_path, "/api/books")
      |> CrawlerTelemetry.call(CrawlerTelemetry.init([]))

      refute_receive {:telemetry_event, [:stacks, :crawler, :robots_fetch], _, _}
    end
  end
end
