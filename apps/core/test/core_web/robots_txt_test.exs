defmodule CoreWeb.RobotsTxtTest do
  @moduledoc """
  Asserts the crawl policy that is **served**, not the one in the repository.

  Campaign finding E2 (2026-07-28): the site served no AI-training-crawler policy
  at all, while the repository root declared one for the source code. The two are
  different documents about different subjects, so nothing was mis-wired — but the
  site's omission was invisible because `robots.txt` is a static asset with no
  test, and `CrawlerTelemetry` counts fetches without inspecting the response.

  These tests go through the endpoint so that `Plug.Static`'s `only:` allowlist is
  exercised. A file present in `priv/static` but absent from that list falls
  through to the SPA catch-all (`router.ex`) and answers with `index.html` and a
  200 — which is why asserting on file contents would prove nothing.
  """
  use CoreWeb.ConnCase, async: true

  @search_engines ~w(Googlebot bingbot DuckDuckBot)

  describe "GET /robots.txt" do
    test "is served as a text file rather than falling through to the SPA", %{conn: conn} do
      conn = get(conn, "/robots.txt")

      assert conn.status == 200

      body = conn.resp_body

      refute body =~ "<!DOCTYPE html",
             "/robots.txt fell through Plug.Static to the SPA catch-all — check `only:` in " <>
               "CoreWeb.Endpoint and that the file is in apps/core/priv/static/"

      assert body =~ "User-agent:"
    end

    test "keeps user-scoped paths out of search results", %{conn: conn} do
      body = get(conn, "/robots.txt").resp_body

      for path <- ~w(/api/ /u/ /shelf/ /post/ /listing/) do
        assert body =~ "Disallow: #{path}",
               "the `*` group no longer disallows #{path}"
      end
    end

    test "opts the site out of AI training crawlers" do
      body = get(build_conn(), "/robots.txt").resp_body

      for agent <- ~w(GPTBot ClaudeBot CCBot Bytespider PerplexityBot Google-Extended) do
        assert body =~ "User-agent: #{agent}",
               "no group for #{agent} — the site is open to it. See campaign finding E2."
      end
    end

    test "each AI crawler group actually disallows something" do
      body = get(build_conn(), "/robots.txt").resp_body

      for agent <- ~w(GPTBot ClaudeBot CCBot Bytespider PerplexityBot Google-Extended) do
        assert directives_for(body, agent) == ["Disallow: /"],
               "#{agent}'s group does not disallow the whole site: " <>
                 inspect(directives_for(body, agent))
      end
    end

    test "does not block search engines", %{conn: conn} do
      body = get(conn, "/robots.txt").resp_body

      for agent <- @search_engines do
        assert directives_for(body, agent) == [],
               "#{agent} has its own group — if it disallows /, the site is deindexed"
      end
    end
  end

  defp directives_for(body, agent) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.drop_while(&(&1 != "User-agent: #{agent}"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "User-agent:")))
  end
end
