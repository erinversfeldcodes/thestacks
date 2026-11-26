defmodule StacksWeb.Plugs.OptionalAuthPipeline do
  @moduledoc """
      Optional Guardian JWT authentication pipeline.

      Verifies a session carried by cookie OR by Bearer token in the
      Authorization header when present, but does not require authentication.
      Unauthenticated requests proceed with `Guardian.Plug.current_resource/1`
      returning `nil`.

      ⛔ THE COOKIE PLUG IS HERE BECAUSE ITS ABSENCE WAS A P1 WAITING ON A
      FUTURE CHANGE, and the shape is worth keeping because the defect was
      unreachable at the moment it was introduced.

      Without it, a signed-in reader whose session is carried by cookie is
      ANONYMOUS on all 15 routes behind this pipeline — and anonymity here is
      not a 401, it is **wrong data returned with a 200**:

        * `Social.blocked?/2` has a `blocked?(nil, _)` clause returning `false`,
          so **a reader who blocked someone sees their content again**.
        * `Visibility.viewable_shelves/2` resolves `viewer_id` to `nil` and
          takes the anonymous scope, so shelves the reader holds a
          group-visibility grant for disappear.
        * Discovery labels for an unauthenticated viewer are `%{}`.

      ⚠️ It was not reachable when introduced, and the reason it was not is
      exactly what made it dangerous: the login body still carries the token and
      the SPA still sends the header, so this pipeline found the bearer. **The
      gap would have bitten precisely when the bearer path was deleted** — the
      deletion the transport counter exists to authorise. And that counter lived
      only in `AuthPipeline`, so it would have read 100% cookie and said "safe
      to delete" while these 15 routes depended on the header being removed.
      A measurement that excludes the pipeline where failure is SILENT rather
      than a 401 is the wrong evidence base for a deletion.

      ⚖️ The semantics match this pipeline rather than being bent to fit: the
      cookie plug falls through on a missing or undecodable cookie, which is
      what this pipeline already does on a missing header.
  """

  use Guardian.Plug.Pipeline,
    otp_app: :core,
    error_handler: StacksWeb.Plugs.AuthErrorHandler,
    module: Stacks.Accounts.Guardian

  plug StacksWeb.Plugs.SessionCookie
  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.LoadResource, allow_blank: true
end
