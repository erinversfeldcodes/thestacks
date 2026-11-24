defimpl Inspect, for: Stacks.Accounts.User do
  @moduledoc """
      Redacting inspector for `%Stacks.Accounts.User{}`.

      The schema is generated from proto and carries no field-level `redact`, so
      the default inspector renders every field — including the Argon2
      `password_hash`, the email address, and the one-time auth tokens. When a
      worker raised with a `%User{}` argument, the error formatter inspected that
      struct and wrote the hash and email into `public.oban_jobs.errors`, where
      they were retained outside the erasure path. Redacting here closes that at
      the source: every path that inspects a user — a logger, an error dump, a
      crash report, `oban_jobs.errors` — gets the redacted form, not just the one
      worker that happened to fail.

      Regeneration-safe on purpose: it lives outside the generated module, so
      `mix proto.sync` cannot overwrite it.
  """
  import Inspect.Algebra

  # Secrets (credential + one-time auth tokens) and direct contact PII. Not the
  # consent/verification booleans: those are not identifying without the id or
  # email, and keeping them visible keeps an inspected user useful to debug.
  @redacted ~w(
    password_hash password email pending_email
    email_confirmation_token password_reset_token
    pending_email_token pending_email_revert_token
  )a

  def inspect(user, opts) do
    fields =
      @redacted
      |> Enum.reduce(user, fn field, acc ->
        case Map.get(acc, field) do
          nil -> acc
          _ -> Map.put(acc, field, "**redacted**")
        end
      end)
      |> Map.from_struct()
      |> Map.delete(:__meta__)

    concat(["#Stacks.Accounts.User<", to_doc(fields, opts), ">"])
  end
end
