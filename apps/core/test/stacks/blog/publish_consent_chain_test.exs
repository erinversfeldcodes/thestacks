defmodule Stacks.Blog.PublishConsentChainTest do
  @moduledoc """
      Publishing is the act a reader actually performs, and the author's
      writing-assistant consent is what decides whether the post's text reaches
      a third party. Every link in that chain has its own test; this one drives
      the whole of it — `publish_post` → event dispatch → `BlogAssociationHandler`
      → `PostBookAssociationWorker` → the Together client seam — and counts what
      crossed the seam, in both consent states.

      A gate proved only at the worker's own doorstep would still be a gate
      nothing walks through: a queue rename or an unregistered handler makes the
      consent-off case pass for the wrong reason. The consent-on case is the
      control that rules that out.
  """

  use Core.DataCase, async: false
  use Oban.Testing, repo: Core.Repo

  alias Stacks.AI.MockTogetherClient
  alias Stacks.Blog
  alias Stacks.GDPR.Consent

  import Stacks.Factory

  @body "The night I finished Piranesi I sat with it for an hour before shelving it."

  setup do
    MockTogetherClient.clear()
    MockTogetherClient.put_response({:ok, Jason.encode!([])})
    :ok
  end

  defp drain_chain do
    Oban.drain_queue(queue: :events, with_recursion: true)
    Oban.drain_queue(queue: :default, with_recursion: true)
  end

  defp draft_by(user) do
    insert(:book, title: "Piranesi")
    insert(:post, user: user, body: @body, published_at: nil)
  end

  describe "publishing a post" do
    test "sends nothing to Together AI when the author has not consented" do
      user = insert(:user)
      post = draft_by(user)

      assert {:ok, _published} = Blog.publish_post(post, user)
      drain_chain()

      assert MockTogetherClient.sent() == [],
             "the author never granted writing-assistant consent, yet their post " <>
               "text crossed the client seam"
    end

    test "sends the post text when the author has consented" do
      user = insert(:user)
      {:ok, user} = Consent.grant_consent(user.id, "writing_assistant")
      post = draft_by(user)

      assert {:ok, _published} = Blog.publish_post(post, user)
      drain_chain()

      assert [{:complete, prompt, _opts}] = MockTogetherClient.sent(),
             "the chain never reached the client seam at all — the consent-off " <>
               "case above would then pass for the wrong reason"

      assert prompt =~ @body
    end
  end
end
