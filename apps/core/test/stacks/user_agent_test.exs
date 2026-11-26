defmodule Stacks.UserAgentTest do
  @moduledoc """
      The SameSite classifier, and the two ways it could answer the question with
      its own default instead of with data.

      ⛔ THIS CLASSIFIER EXISTS TO PRODUCE A NUMBER SOMEBODY WILL ACT ON — whether
      a double-submit CSRF token is worth a 77-call-site refactor plus an
      enforcement step that can reject writes. So the cases that matter are not
      "does it recognise Chrome" but the two that would corrupt the answer:

        1. anything unrecognised must be `:unknown`, never `:enforces` — a
           default of enforcement makes the residual population look smaller
           than it is, which is the direction that skips the refactor;
        2. the family order must hold, because Edge's user agent contains
           "Chrome" and Chrome's contains "Safari" — a wrong order silently
           reclassifies whole families.

      ⚠️ Real user-agent strings below, not invented ones. A classifier tested
      against strings written from its own regexes proves the regexes match
      themselves.
  """

  use ExUnit.Case, async: true

  alias Stacks.UserAgent

  describe "families at or above their SameSite floor" do
    test "modern Chrome enforces" do
      ua =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

      assert UserAgent.samesite_support(ua) == :enforces
    end

    test "modern Firefox enforces" do
      ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:131.0) Gecko/20100101 Firefox/131.0"
      assert UserAgent.samesite_support(ua) == :enforces
    end

    test "modern Safari enforces" do
      ua =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

      assert UserAgent.samesite_support(ua) == :enforces
    end

    test "modern Edge enforces" do
      ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"

      assert UserAgent.samesite_support(ua) == :enforces
    end

    test "iOS Safari enforces" do
      ua =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

      assert UserAgent.samesite_support(ua) == :enforces
    end
  end

  describe "families below their floor — the population the decision turns on" do
    test "Chrome 50 does not enforce" do
      ua =
        "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) " <>
          "Chrome/50.0.2661.102 Safari/537.36"

      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end

    test "Firefox 59 does not enforce" do
      ua = "Mozilla/5.0 (Windows NT 6.1; rv:59.0) Gecko/20100101 Firefox/59.0"
      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end

    test "Safari 11 does not enforce" do
      ua =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/11.1.2 Safari/605.1.15"

      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end

    # ⛔ IE ignores the attribute at every version, so there is no floor to be
    # above. Tested because it is the clearest member of the population the
    # decision is about.
    test "Internet Explorer 11 does not enforce, at any version" do
      ua = "Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko"
      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end

    test "older Internet Explorer does not enforce either" do
      ua = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end
  end

  # ⛔ THE CASE THAT PROTECTS THE NUMBER. A classifier that defaults to
  # `:enforces` for traffic it cannot identify makes the residual population look
  # SMALLER than it is — and smaller is the direction that argues for skipping
  # the refactor. So every unrecognised input must land in `:unknown`, and a
  # large `:unknown` bucket is a finding about the classifier rather than an
  # answer about the traffic.
  describe "anything unrecognised is :unknown, never :enforces" do
    test "a missing header" do
      assert UserAgent.samesite_support(nil) == :unknown
    end

    test "an empty header" do
      assert UserAgent.samesite_support("") == :unknown
    end

    test "a bot or scripted client naming no family" do
      assert UserAgent.samesite_support("curl/8.7.1") == :unknown
      assert UserAgent.samesite_support("python-requests/2.32.3") == :unknown
    end

    test "a family with an unparseable version is unknown, not guessed" do
      # ⚠️ A family matched and its version did not. Placing it anyway would be
      # the default-answering failure this describe block exists for.
      assert UserAgent.samesite_support("Mozilla/5.0 Chrome/notanumber Safari/537.36") == :unknown
    end

    test "a non-string input" do
      assert UserAgent.samesite_support(:not_a_string) == :unknown
      assert UserAgent.samesite_support(42) == :unknown
    end
  end

  # ⛔ THE ORDERING, which is the quiet failure. Chrome's UA contains "Safari",
  # Edge's contains BOTH "Chrome" and "Safari", and every Chromium browser
  # advertises "Chrome". So a wrong family order does not error — it
  # reclassifies whole families against the wrong floor, and both answers look
  # plausible.
  describe "family precedence holds against overlapping user agents" do
    test "Edge is not classified as Chrome" do
      # Edg/16 is AT Edge's floor; the Chrome token in the same string is 51+,
      # so both orders yield :enforces and this case alone cannot discriminate.
      # The discriminating pair is below.
      ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"

      assert UserAgent.samesite_support(ua) == :enforces
    end

    # ⛔ THE DISCRIMINATING CASE: an Edge version BELOW its floor carrying a
    # Chrome token ABOVE Chrome's floor. Read as Edge it does not enforce; read
    # as Chrome it does. Only the correct precedence gives the first answer.
    test "an Edge below its floor is not rescued by its Chrome token" do
      ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/15.0"

      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end

    test "Chrome is not classified as Safari" do
      # Chrome 50 is below Chrome's floor. Safari's pattern requires a
      # `Version/` token, which Chrome does not send — so if Chrome were read as
      # Safari this would be :unknown rather than :does_not_enforce.
      ua =
        "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) " <>
          "Chrome/50.0.2661.102 Safari/537.36"

      assert UserAgent.samesite_support(ua) == :does_not_enforce
    end
  end

  # ⚖️ The classification is the ONLY thing that leaves this module — asserted
  # as a property of the return type rather than trusted, because the whole
  # argument for measuring this way is that no user-agent string is retained.
  describe "nothing but the classification escapes" do
    test "every answer is one of exactly three atoms" do
      inputs = [
        nil,
        "",
        "curl/8.7.1",
        "Mozilla/5.0 Chrome/129.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko",
        "Mozilla/5.0 Firefox/59.0"
      ]

      answers = Enum.map(inputs, &UserAgent.samesite_support/1) |> Enum.uniq()

      assert Enum.all?(answers, &(&1 in [:enforces, :does_not_enforce, :unknown])),
             "the classifier returned something outside its three-valued type: #{inspect(answers)}"
    end
  end
end
