defmodule StacksWeb.RobotsTest do
  @moduledoc """
      Verifies that robots.txt exists in priv/static and contains the correct
      directives to block crawlers from user-generated-content paths.

      Anti-scraping requirement from.
  """

  use ExUnit.Case, async: true

  @robots_path Path.join([:code.priv_dir(:core), "static", "robots.txt"])

  describe "robots.txt" do
    test "file exists in priv/static" do
      assert File.exists?(@robots_path),
             "Expected priv/static/robots.txt to exist — create it as part of anti-scraping hardening"
    end

    test "lets crawlers reach profile paths (/u/) so the per-user opt-in header governs" do
      content = File.read!(@robots_path)
      # Reversed from a blanket block: a profile is crawlable, and CoreWeb.PageController's
      # fail-closed x-robots-tag header decides indexing per profile (noindex unless the
      # owner opted in to search indexing on a public profile).
      refute content =~ "Disallow: /u/"
    end

    test "disallows crawlers from shelf paths (/shelf/)" do
      content = File.read!(@robots_path)
      assert content =~ "Disallow: /shelf/"
    end

    test "disallows crawlers from post paths (/post/)" do
      content = File.read!(@robots_path)
      assert content =~ "Disallow: /post/"
    end

    test "disallows crawlers from listing paths (/listing/)" do
      content = File.read!(@robots_path)
      assert content =~ "Disallow: /listing/"
    end

    test "contains a User-agent directive" do
      content = File.read!(@robots_path)
      assert content =~ "User-agent:"
    end
  end
end
