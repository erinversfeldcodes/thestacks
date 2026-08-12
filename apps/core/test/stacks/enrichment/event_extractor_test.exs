defmodule Stacks.Enrichment.EventExtractorTest do
  use ExUnit.Case, async: true

  alias Stacks.Enrichment.EventExtractor

  defp page_with(json) do
    """
    <html><head>
    <script type="application/ld+json">#{json}</script>
    </head><body><h2>Site chrome heading</h2></body></html>
    """
  end

  describe "events/1" do
    test "reads a schema.org Event with its OWN title↔date pairing" do
      body =
        page_with("""
        {"@context":"https://schema.org","@type":"Event",
         "name":"Book signing with Treive Nicholas",
         "startDate":"2027-03-14T18:00:00+02:00",
         "location":{"@type":"Place","name":"Sea Point store"},
         "description":"An evening with the author.",
         "url":"https://shop.example/pages/signing"}
        """)

      assert [event] = EventExtractor.events(body)
      assert event.title == "Book signing with Treive Nicholas"
      assert event.location == "Sea Point store"
      assert event.description == "An evening with the author."
      assert event.url == "https://shop.example/pages/signing"
      assert DateTime.compare(event.event_date, ~U[2027-03-14 16:00:00Z]) == :eq
    end

    test "unwraps @graph envelopes and lists, and accepts Event subtypes" do
      body =
        page_with("""
        {"@graph":[
          {"@type":"Organization","name":"The Shop"},
          {"@type":"LiteraryEvent","name":"Poetry night","startDate":"2027-01-05"}
        ]}
        """)

      assert [event] = EventExtractor.events(body)
      assert event.title == "Poetry night"
      assert DateTime.compare(event.event_date, ~U[2027-01-05 00:00:00Z]) == :eq
    end

    test "a bare-date startDate parses; an unreadable one is nil, never a guess" do
      body =
        page_with("""
        [{"@type":"Event","name":"Dated","startDate":"2027-06-01"},
         {"@type":"Event","name":"Vague","startDate":"next Tuesday"}]
        """)

      assert [dated, vague] = EventExtractor.events(body)
      assert dated.event_date
      assert vague.event_date == nil
    end

    test "broken JSON-LD and non-Event objects give [], not an error" do
      assert EventExtractor.events(page_with("{not json")) == []
      assert EventExtractor.events(page_with(~s({"@type":"Product","name":"A book"}))) == []
      assert EventExtractor.events("<html><body>no ld+json at all</body></html>") == []
    end

    test "an Event with no name is dropped — a titleless row helps nobody" do
      assert EventExtractor.events(page_with(~s({"@type":"Event","startDate":"2027-01-01"}))) ==
               []
    end
  end
end
