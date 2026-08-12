defmodule Stacks.AccountsPropertyTest do
  @moduledoc """
      StreamData property-based tests for User changesets that parse untrusted input.

      Verifies that changesets never crash on arbitrary strings and always return
      a well-formed `%Ecto.Changeset{}` — whether valid or with errors.
  """

  use Core.DataCase, async: false
  use ExUnitProperties

  import Stacks.Factory

  alias Stacks.Accounts

  describe "location_changeset/2" do
    property "never crashes on arbitrary country_code and city strings" do
      check all(
              country <- string(:printable),
              city <- string(:printable),
              max_runs: 200
            ) do
        user = build(:user)
        result = Accounts.location_changeset(user, %{"country_code" => country, "city" => city})
        assert %Ecto.Changeset{} = result
      end
    end

    property "accepts exactly 2-character country_code" do
      check all(
              country <- string(:alphanumeric, length: 2),
              max_runs: 100
            ) do
        user = build(:user)
        cs = Accounts.location_changeset(user, %{"country_code" => country})
        refute Map.has_key?(cs.errors |> Map.new(fn {k, _} -> {k, true} end), :country_code)
      end
    end

    property "rejects country_code of any length other than 2" do
      len_gen = one_of([constant(1), integer(3..10)])

      check all(
              len <- len_gen,
              country <- string(:alphanumeric, length: len),
              max_runs: 100
            ) do
        user = build(:user)
        cs = Accounts.location_changeset(user, %{"country_code" => country})
        assert cs.errors[:country_code] != nil
      end
    end
  end

  describe "profile_changeset/2" do
    property "never crashes on arbitrary display_name and website_url" do
      check all(
              name <- string(:printable),
              url <- string(:printable),
              max_runs: 200
            ) do
        user = build(:user)
        result = Accounts.profile_changeset(user, %{"display_name" => name, "website_url" => url})
        assert %Ecto.Changeset{} = result
      end
    end

    property "accepts website_url up to 500 characters" do
      check all(
              url <- string(:alphanumeric, max_length: 500),
              max_runs: 100
            ) do
        user = build(:user)
        cs = Accounts.profile_changeset(user, %{"website_url" => url})
        refute Map.has_key?(cs.errors |> Map.new(fn {k, _} -> {k, true} end), :website_url)
      end
    end

    property "rejects website_url longer than 500 characters" do
      check all(
              extra <- string(:alphanumeric, min_length: 1, max_length: 100),
              max_runs: 50
            ) do
        url = String.duplicate("a", 500) <> extra
        user = build(:user)
        cs = Accounts.profile_changeset(user, %{"website_url" => url})
        assert cs.errors[:website_url] != nil
      end
    end
  end

  describe "password_change_changeset/2" do
    property "never crashes on arbitrary new_password strings" do
      check all(
              pw <- string(:printable),
              max_runs: 200
            ) do
        user = build(:user)
        result = Accounts.password_change_changeset(user, %{"password" => pw})
        assert %Ecto.Changeset{} = result
      end
    end

    property "accepts passwords of 8 or more characters" do
      check all(
              pw <- string(:alphanumeric, min_length: 8),
              max_runs: 100
            ) do
        user = build(:user)
        cs = Accounts.password_change_changeset(user, %{"password" => pw})
        refute Map.has_key?(cs.errors |> Map.new(fn {k, _} -> {k, true} end), :password)
      end
    end

    property "rejects passwords shorter than 8 characters" do
      check all(
              pw <- string(:alphanumeric, min_length: 1, max_length: 7),
              max_runs: 100
            ) do
        user = build(:user)
        cs = Accounts.password_change_changeset(user, %{"password" => pw})
        assert cs.errors[:password] != nil
      end
    end
  end
end
