defmodule Stacks.WritingAssistant.SafetyPassTest do
  @moduledoc """
      The recorded red-team for the anti-ghost-writing rule. The ghost-writing
      attempts below are the planted adversarial set; every one must be refused,
      and the coaching requests must pass. Neutering the patterns reds the
      refusal cases — the guard can fail, so passing means something.
  """
  use ExUnit.Case, async: true

  alias Stacks.WritingAssistant.SafetyPass

  # The red-team: requests to produce the author's creative prose FOR them.
  @ghostwriting_attempts [
    "Write the next chapter of my novel.",
    "Can you continue my story from here?",
    "Write this scene for me.",
    "Please ghostwrite the dedication.",
    "Draft the next paragraph in my voice.",
    "Finish my poem for me.",
    "Compose the opening stanza.",
    "Keep writing my manuscript where I left off."
  ]

  # Coaching: thinking WITH the author, which the assistant is here to do.
  @coaching_requests [
    "What do you think of this chapter?",
    "How can I improve the pacing in this scene?",
    "Is this character consistent with chapter two?",
    "Summarise my chapter in a sentence.",
    "What themes am I exploring in this passage?",
    "Where does the dialogue feel flat?"
  ]

  test "every planted ghost-writing attempt is refused" do
    for attempt <- @ghostwriting_attempts do
      assert {:refuse, :ghostwriting, message} = SafetyPass.check_request(attempt),
             "expected a ghost-writing refusal for: #{attempt}"

      assert message =~ "won't write it for you"
    end
  end

  test "coaching requests pass the safety pass" do
    for request <- @coaching_requests do
      assert :ok = SafetyPass.check_request(request),
             "expected coaching to pass, but it was refused: #{request}"
    end
  end
end
