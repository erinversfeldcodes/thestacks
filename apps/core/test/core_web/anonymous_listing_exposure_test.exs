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

  defp anonymous_book_payloads do
    listing = insert(:listing, status: "active")

    index =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings")
      |> json_response(200)

    show =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings/#{listing.id}")
      |> json_response(200)

    Enum.map(index["listings"], & &1["book"]) ++ [show["listing"]["book"]]
  end

  defp anonymous_seller_payloads do
    seller =
      insert(:user,
        email: "seller-private@example.invalid",
        display_name: "Seller",
        profile_visibility: "owner"
      )

    listing = insert(:listing, seller: seller, status: "active")

    index =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings")
      |> json_response(200)

    show =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings/#{listing.id}")
      |> json_response(200)

    {seller, Enum.map(index["listings"], & &1["seller"]) ++ [show["listing"]["seller"]]}
  end

  test "⛔ the seller payload's key set is EXACTLY what it should be" do
    # ⛔ The form that subsumes both of the others, and the reason it is here
    # rather than a longer denylist. The `pending_email` tripwire catches the
    # MECHANISM — re-inheriting a wider list — but not a hand-added field. The
    # denylist below catches named fields but can never enumerate a personal
    # field nobody has invented yet. An exact key set catches inherited,
    # hand-added and invented additions alike, needs no maintenance, and fails
    # on a deliberate widening, which is where someone should have to justify
    # themselves.
    #
    # ⚠️ It also has NO ABSENCE FORM, which makes it structurally immune to the
    # vacuity that has now bitten three times in two rounds: there is no empty
    # input that satisfies `== ["display_name", "id"]`.
    #
    # The line worth keeping: an exact set for a NARROW PROJECTION across a
    # trust boundary; a denylist for a wide, evolving record on the owner's own
    # path. This payload is the former.
    {_seller, sellers} = anonymous_seller_payloads()
    present = Enum.filter(sellers, &is_map/1)

    assert length(present) == 2,
           "expected a seller payload from both endpoints, got #{length(present)} — the " <>
             "assertion below would be comparing against nothing"

    for payload <- present do
      assert payload |> Map.keys() |> Enum.sort() == ["display_name", "id"],
             "the anonymous seller payload's shape changed. Every addition here is published " <>
               "to unauthenticated callers on an enumerable index, so widening this set is a " <>
               "disclosure decision and not a serialisation detail."
    end
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

  test "⛔ the listing still carries its book, which NOTHING asserted before" do
    # ⛔ `book` is the precedent `seller` was built to copy — both are embedded
    # by a hand-written projection and both are therefore skipped from the
    # generated serializer. But only `seller` had a boundary assertion, so
    # `seller` ended up better guarded than the pattern it was modelled on, and
    # a serializer that stopped carrying `book` would have broken every
    # marketplace card with no test failing.
    #
    # ⚠️ Deliberately a PRESENCE-AND-SHAPE assertion rather than an exact key
    # set. `seller` is a narrow projection across a trust boundary, where an
    # exact set is right because every addition is a disclosure. `book` is
    # public catalogue data on a public listing, so additions are not
    # disclosures and pinning its exact set would fail on every ordinary
    # catalogue change — a test that cries wolf gets deleted. What matters here
    # is that the embed exists and is usable.
    books = anonymous_book_payloads()

    assert length(books) == 2,
           "expected a book payload from both endpoints, got #{length(books)} — the " <>
             "assertions below would be comparing against nothing"

    for book <- books do
      assert is_map(book),
             "the listing payload carries no `book` object. The marketplace card renders " <>
               "from it, so this is a broken surface rather than a serialisation detail."

      assert is_binary(book["id"]) and book["id"] != "",
             "the embedded book has no id, so nothing can link to it"

      assert is_binary(book["title"]) and book["title"] != "",
             "the embedded book has no title, so the card has nothing to show"
    end
  end

  test "and the seller is still identifiable, which is what the embed is for" do
    # The positive control. Redacting until nothing is left would pass every
    # assertion above and break the marketplace.
    {_seller, [first | _]} = anonymous_seller_payloads()

    assert first["display_name"] == "Seller"
    assert is_binary(first["id"]) and first["id"] != ""
  end

  test "⛔ a seller with NO display name does not fall back to their handle" do
    # ⛔ `display_name` is nullable (`add :display_name, :text`, no
    # `null: false`), and this repo's established fix for a null name on the
    # wire is `coalesce(display_name, handle)` — used in `list_blocked_users/2`
    # and the group-feed decoration. Applying that house idiom to the listing
    # seller would put a handle on an anonymous payload, and
    # `e2e/tests/search.spec.ts` drives a test named "a seller's handle and
    # asking price never reach an anonymous caller".
    #
    # ⚠️ The other cases in this file all set `display_name`, so none of them
    # can see this: the positive control would pass while a coalesce quietly
    # published the handle. So the house pattern is wrong on exactly this
    # endpoint, and this is what makes that a failing test rather than a comment.
    seller = insert(:user, display_name: nil, handle: "private-handle-probe")
    listing = insert(:listing, seller: seller, status: "active")

    body =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings")
      |> response(200)

    # ⛔ ANTI-VACUITY FIRST. The refutation below is absence-only over a response
    # that can legitimately be EMPTY — an index filter change, a renamed key, a
    # status the factory stops producing — so without this it passes having
    # tested nothing. Third instance of this shape in two rounds, in a file whose
    # comments are about it.
    #
    # ⚠️ Keyed on the LISTING's own id rather than the seller's name, because
    # this fixture deliberately has no display name: asserting on the seller
    # would be asserting on the thing under test.
    assert body =~ listing.id,
           "the anonymous listings response did not contain the planted listing, so the " <>
             "refutation below is vacuous"

    refute body =~ "private-handle-probe",
           "a seller with no display name fell back to their handle, which an anonymous " <>
             "caller must never receive"
  end

  test "⛔ the real address does not appear ANYWHERE in the response body" do
    # ⚠️ A key-absence check only covers the keys it enumerates. This asserts on
    # the serialised bytes, so the address cannot reach a caller through a field
    # nobody thought to name — a nested contact blob, a denormalised copy, an
    # error message.
    seller = insert(:user, email: "unique-probe-addr@example.invalid")
    listing = insert(:listing, seller: seller, status: "active")

    body =
      CoreWeb.ConnCase.proven_conn()
      |> get("/api/listings")
      |> response(200)

    # ⛔ ANTI-VACUITY FIRST, for the same reason as above: a refutation over an
    # empty response is a test that cannot fail.
    assert body =~ listing.id,
           "the anonymous listings response did not contain the planted listing, so the " <>
             "refutation below is vacuous"

    refute body =~ "unique-probe-addr@example.invalid",
           "the seller's account address appears somewhere in the anonymous listings response"
  end
end
