defmodule StacksWeb.BookModerationController do
  @moduledoc """
      Owner moderation controller for the human-set age gate.

      The automatic age-gate classifier was removed: a book is age-gated only
      because a PERSON marked it. Users may RAISE the gate at add-time (see
      `BookController.set_age_gate/2`, raise-only). The platform OWNER may override
      the gate in EITHER direction from this surface.

      Requires an MFA-verified admin session JWT — enforced by the `:admin`
      pipeline at the router. Role is enforced at JWT issuance by
      `AdminAuthController.login/2`, not repeated per action.
  """

  use CoreWeb, :controller

  action_fallback CoreWeb.FallbackController

  alias Stacks.Books

  @doc """
      GET /api/admin/books — paginated list of books for moderation.

      Query params: `search` (title), `tier` (`public` | `age_gated`), `page`,
      `per_page`. The owner sees ALL books, including age-gated ones (which are
      hidden from the public catalogue).
  """
  def index(conn, params) do
    opts = [
      search: params["search"],
      tier: params["tier"],
      page: parse_int(params["page"], 1),
      per_page: parse_int(params["per_page"], 50)
    ]

    {books, total} = Books.list_for_moderation(opts)

    json(conn, %{
      books: Enum.map(books, &serialize_book/1),
      total: total,
      page: opts[:page],
      per_page: opts[:per_page]
    })
  end

  @doc """
      PUT /api/admin/books/:id/age-gate — owner sets a book's visibility tier.

      Body: `{"age_gated": true|false}` or `{"visibility_tier": "public"|"age_gated"}`.
      The owner path passes `source::owner, raise_only: false` so the gate may be
      set in EITHER direction. Returns 200 with the updated book, 404 when missing.
  """
  def set_age_gate(conn, %{"id" => id} = params) do
    tier = resolve_tier(params)

    with {:ok, book} <- Books.set_visibility_tier(id, tier, source: :owner, raise_only: false) do
      json(conn, %{book: serialize_book(Books.get_book_detail(book.id))})
    end
  end

  defp resolve_tier(%{"visibility_tier" => tier}) when tier in ["public", "age_gated"], do: tier

  defp resolve_tier(%{"age_gated" => value}),
    do: if(truthy?(value), do: "age_gated", else: "public")

  defp resolve_tier(_params), do: "public"

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_other), do: false

  defp serialize_book(book) do
    primary = Books.primary_edition(book)

    %{
      id: book.id,
      title: book.title,
      author: author_name(book.author),
      visibility_tier: book.visibility_tier,
      isbn: edition_field(primary, :isbn),
      cover_image_url: edition_field(primary, :cover_image_url)
    }
  end

  defp author_name(%{name: name}), do: name
  defp author_name(_author), do: nil

  defp edition_field(nil, _key), do: nil
  defp edition_field(edition, key), do: Map.get(edition, key)

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_val, default), do: default
end
