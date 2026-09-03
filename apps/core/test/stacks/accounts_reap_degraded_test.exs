defmodule Stacks.AccountsReapDegradedTest do
  use Core.DataCase, async: false

  import Stacks.Factory

  alias Stacks.Accounts

  # `register/1` reaps abandoned signups for the incoming email before it does
  # anything else. `expired_unverified_ids/1` is careful about which accounts it
  # will name — its own docs warn that `email_confirmed == false` does NOT mean
  # "never confirmed", because an account whose email change lapsed is degraded
  # to exactly that flag while keeping every shelf, placement and post it has.
  #
  # This asks whether the OTHER query feeding the same reap is equally careful.

  test "a degraded account is not erased when someone registers with its email" do
    user = insert(:user, email: "reader@example.com", email_confirmed: true)
    bookshelf = insert(:bookshelf, user: user)
    placement = insert(:placement, bookshelf: bookshelf, book: insert(:book))

    # The documented way an account becomes degraded: an email change that
    # nobody answered inside the grace window. The reader keeps everything.
    {:ok, _degraded} = Accounts.degrade_lapsed_email_change(user.id)

    # Someone now attempts to register with that address. They need not succeed
    # — the reap runs before the invite gate and before validation.
    _ = Accounts.register(%{email: "reader@example.com", password: "irrelevant"})

    assert Core.Repo.get(Stacks.Accounts.User, user.id),
           "the degraded reader's account was erased by someone else's registration attempt"

    assert Core.Repo.get(Stacks.Shelving.Placement, placement.id),
           "the degraded reader's books were erased by someone else's registration attempt"
  end

  test "an abandoned signup IS still reaped, so the reader can sign up again" do
    # The whole point of the reap: someone started signing up, never confirmed,
    # and comes back later to try again. Their half-made account must get out of
    # the way or the email is permanently unusable. The guard above must not
    # cost this.
    abandoned =
      insert(:user,
        email: "returning@example.com",
        email_confirmed: false,
        email_confirmation_token: Stacks.Accounts.sign_confirmation_token(Ecto.UUID.generate())
      )

    _ = Accounts.register(%{email: "returning@example.com", password: "irrelevant"})

    refute Core.Repo.get(Stacks.Accounts.User, abandoned.id),
           "an abandoned signup must be cleared so its email can be used again"
  end
end
