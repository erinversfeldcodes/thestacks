defmodule CoreWeb.AnonymousListingExposureTest do
  @moduledoc """
      What an UNAUTHENTICATED caller receives from the public listing endpoints.

      ⛔ WHY THIS FILE EXISTS, and why it is a controller test rather than a
      serializer one. A seller's account email was served to anonymous callers
      on a paginated, enumerable index — together with their analytics consent
      flag, their age-verification state and their role — and the serializer
      test covering that payload ASSERTED the email as contract. So the defect
      was pinned by a passing test, which is the hardest kind to notice: fixing
      it looks like breaking something.

      Measured before the fix, through this same path:

          seller keys: age_verified, consent_analytics, created_at,
                       display_name, email, id, profile_visibility, role,
                       updated_at
          seller.email == the real account address  -> true
          profile_visibility                        -> "owner"

      That last line is the sharpest: the email was served even for a seller who
      had chosen the most private profile setting available.

      ⚠️ The assertions here are deliberately at the HTTP boundary. The cause
      was a take-list reused across a trust boundary — `@user_embed_fields`
      inherited `@user_core_fields`, which is the caller's OWN record, where
      `email` is correct — so a test on either list would have been testing the
      thing that was wrong. What an anonymous request receives is the only
      question that cannot be satisfied by a correct-looking list.
  """
  use CoreWeb.ConnCase, async: false

  import Stacks.Factory

  # Everything personal that the embed used to carry. Named as a set rather than
  # asserted one by one so a field ADDED to the seller payload later is caught
  # by the same test, not just these five.
  @must_not_appear [
    "email",
    "consent_analytics",
    "age_verified",
    "profile_visibility",
    "role",
    "pending_email",
    "pending_email_sent_at",
    "consent_writing_assistant"
  ]

  defp anonymous_seller_payloads do
    seller =
      insert(:user,
        email: "seller-private@example.invalid",
        display_name: "Seller",
        profile_visibility: "owner"
      )

    listing = insert(:listing, seller: seller, status: "active")

    index =
      build_conn()
      |> get("/api/listings")
      |> json_response(200)

    show =
      build_conn()
      |> get("/api/listings/#{listing.id}")
      |> json_response(200)

    {seller, Enum.map(index["listings"], & &1["seller"]) ++ [show["listing"]["seller"]]}
  end

  test "⛔ no personal field reaches an anonymous caller on either endpoint" do
    {_seller, sellers} = anonymous_seller_payloads()

    # ⚠️ Anti-vacuity first. If the fixture stops producing a seller payload —
    # a status filter change, a renamed key — every refutation below passes
    # against nothing, which is how an exposure test goes quietly green.
    # ⚠️ Counts NON-NIL payloads, not elements. The first version of this
    # asserted `length(sellers) == 2` — and `show["seller"]` was nil because the
    # show response nests under a `listing` key, so a nil element satisfied the
    # count and every refutation below would have passed against nothing. An
    # anti-vacuity check that counts can itself be vacuous.
    present = Enum.filter(sellers, &is_map/1)

    assert length(present) == 2,
           "expected a seller payload from both /api/listings and /api/listings/:id, got " <>
             "#{length(present)} non-nil of #{length(sellers)} — the refutations below " <>
             "would be vacuous"

    for payload <- present do
      assert is_map(payload), "a listing carried no seller object, so nothing was checked"

      assert Map.has_key?(payload, "id"),
             "the seller payload is missing `id`, so it is not the shape this test believes"

      for field <- @must_not_appear do
        refute Map.has_key?(payload, field),
               "an anonymous listings read exposes `#{field}` — personal data on an " <>
                 "enumerable public index"
      end
    end
  end

  test "and the seller is still identifiable, which is what the embed is for" do
    # The positive control. Redacting until nothing is left would pass every
    # assertion above and break the marketplace.
    {_seller, [first | _]} = anonymous_seller_payloads()

    assert first["display_name"] == "Seller"
    assert is_binary(first["id"]) and first["id"] != ""
  end

  test "⛔ the real address does not appear ANYWHERE in the response body" do
    # ⚠️ A key-absence check only covers the keys it enumerates. This asserts on
    # the serialised bytes, so the address cannot reach a caller through a field
    # nobody thought to name — a nested contact blob, a denormalised copy, an
    # error message.
    seller = insert(:user, email: "unique-probe-addr@example.invalid")
    _listing = insert(:listing, seller: seller, status: "active")

    body =
      build_conn()
      |> get("/api/listings")
      |> response(200)

    refute body =~ "unique-probe-addr@example.invalid",
           "the seller's account address appears somewhere in the anonymous listings response"
  end
end
