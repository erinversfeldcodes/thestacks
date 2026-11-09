# The association replay corpus: posts, candidates, a recorded model response,
# and the associations a human read out of the post text.
#
# ⛔ THE RESPONSE IS REPLAYED; THE EXPECTATION IS LABELLED BY HAND. That split
# is the whole integrity of this file. The `response` field is model output —
# it is the INPUT being replayed — but `expect` is read from the post's own
# text, never from what the model answered. A corpus labelled by the system it
# grades certifies that system's mistakes and drifts with it, invisibly,
# because the labels move too.
#
# ⚖️ REPLAY BY DEFAULT, because an eval that needs the provider to run is an
# eval nobody runs on a PR. Replaying scores OUR half — the decoder, the id
# mapping, the de-duplication, the refusal of books that are not in the
# catalogue — which is precisely the half that broke in production twice: a
# Markdown fence the decoder did not strip, and a 500-character cap that cut
# the JSON mid-object. Neither was a model failure.
#
# ⚠️ What replay CANNOT tell you is whether the model got better or worse. That
# needs the provider, and it is the live mode's job.
[
  %{
    name: "one_book_fenced",
    stratum: :happy,
    body:
      "I reread To the Lighthouse this week and the Ramsay dinner still undoes me — that long middle section where nothing happens and everything does.",
    candidates: [
      "00000001-0000-4000-8000-000000000001",
      "00000002-0000-4000-8000-000000000002"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000001-0000-4000-8000-000000000001"
    ],
    response:
      "```json\n[\n  {\n    \"book_id\": \"00000001-0000-4000-8000-000000000001\",\n    \"confidence\": 0.94,\n    \"reasoning\": \"Named outright and discussed at length.\"\n  }\n]\n```",
    notes:
      "The commonest real shape: one book, fenced ```json. If this fails nothing else matters."
  },
  %{
    name: "two_books_bare_fence",
    stratum: :happy,
    body:
      "A pairing that shouldn't work: Beloved and Wolf Hall, read back to back. Both are about what a house remembers.",
    candidates: [
      "00000007-0000-4000-8000-000000000007",
      "0000000a-0000-4000-8000-00000000000a",
      "00000008-0000-4000-8000-000000000008"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000007-0000-4000-8000-000000000007",
      "0000000a-0000-4000-8000-00000000000a"
    ],
    response:
      "```\n[\n  {\n    \"book_id\": \"00000007-0000-4000-8000-000000000007\",\n    \"confidence\": 0.91,\n    \"reasoning\": \"Named in the first line.\"\n  },\n  {\n    \"book_id\": \"0000000a-0000-4000-8000-00000000000a\",\n    \"confidence\": 0.88,\n    \"reasoning\": \"Named alongside it as the pairing.\"\n  }\n]\n```",
    notes:
      "A bare ``` fence. Pinning one spelling of the fence re-creates the defect one variant along."
  },
  %{
    name: "three_books_wrapped_object",
    stratum: :happy,
    body:
      "Le Guin year: The Dispossessed, then The Lathe of Heaven, then The Left Hand of Darkness. Read in that order they argue with each other.",
    candidates: [
      "0000000c-0000-4000-8000-00000000000c",
      "0000000d-0000-4000-8000-00000000000d",
      "0000000e-0000-4000-8000-00000000000e"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000c-0000-4000-8000-00000000000c",
      "0000000d-0000-4000-8000-00000000000d",
      "0000000e-0000-4000-8000-00000000000e"
    ],
    response:
      "```json\n{\n  \"associations\": [\n    {\n      \"book_id\": \"0000000c-0000-4000-8000-00000000000c\",\n      \"confidence\": 0.95,\n      \"reasoning\": \"Named first.\"\n    },\n    {\n      \"book_id\": \"0000000d-0000-4000-8000-00000000000d\",\n      \"confidence\": 0.93,\n      \"reasoning\": \"Named second.\"\n    },\n    {\n      \"book_id\": \"0000000e-0000-4000-8000-00000000000e\",\n      \"confidence\": 0.9,\n      \"reasoning\": \"Named third.\"\n    }\n  ]\n}\n```",
    notes:
      "The wrapped object the schema asks for. A model OBEYING the schema sends this, so refusing it would make the schema's own success look like a parse failure."
  },
  %{
    name: "unfenced_array",
    stratum: :happy,
    body: "Piranesi is the only book I've finished in one sitting this year.",
    candidates: [
      "0000000f-0000-4000-8000-00000000000f",
      "00000010-0000-4000-8000-000000000010"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000f-0000-4000-8000-00000000000f"
    ],
    response:
      "[{\"book_id\": \"0000000f-0000-4000-8000-00000000000f\", \"confidence\": 0.96, \"reasoning\": \"The post's only subject.\"}]",
    notes:
      "Unfenced, which is what response_format should yield. Anti-vacuity for the fence handling: a stripper written to REQUIRE a fence passes every other happy case and fails here."
  },
  %{
    name: "author_discussed_not_titled",
    stratum: :happy,
    body:
      "Eco's habit of burying a whole theology in a footnote — The Name of the Rose does it twice before the first murder.",
    candidates: [
      "00000004-0000-4000-8000-000000000004",
      "00000005-0000-4000-8000-000000000005",
      "00000006-0000-4000-8000-000000000006"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000004-0000-4000-8000-000000000004"
    ],
    response:
      "```json\n[\n  {\n    \"book_id\": \"00000004-0000-4000-8000-000000000004\",\n    \"confidence\": 0.87,\n    \"reasoning\": \"Named; the other Eco titles are not.\"\n  }\n]\n```",
    notes:
      "Two other books by the same author are candidates and must NOT be associated. An author-level match would pull all three."
  },
  %{
    name: "empty_array_is_an_answer",
    stratum: :empty,
    body: "A post about the smell of a secondhand bookshop in winter, naming no books at all.",
    candidates: [
      "00000001-0000-4000-8000-000000000001",
      "00000007-0000-4000-8000-000000000007"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [],
    response: "```json\n[]\n```",
    notes:
      "⛔ An empty array is an ANSWER. Treating it as a failure would report a working pass over a post with no books as broken."
  },
  %{
    name: "empty_wrapped_is_an_answer",
    stratum: :empty,
    body: "On rereading as a habit rather than a judgement. No titles.",
    candidates: [
      "00000003-0000-4000-8000-000000000003"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [],
    response: "```json\n{\n  \"associations\": []\n}\n```",
    notes: "The same answer in the wrapped shape."
  },
  %{
    name: "nothing_found_despite_candidates",
    stratum: :empty,
    body: "Thoughts on marginalia, and why I stopped writing in books.",
    candidates: [
      "00000009-0000-4000-8000-000000000009",
      "00000008-0000-4000-8000-000000000008",
      "00000011-0000-4000-8000-000000000011"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [],
    response: "[]",
    notes:
      "Candidates exist and none is discussed. A decoder that fell back to 'associate the first candidate' would pass the happy cases and fail here."
  },
  %{
    name: "truncated_mid_object",
    stratum: :broken,
    body: "A long post on the Cromwell books, naming both.",
    candidates: [
      "0000000a-0000-4000-8000-00000000000a",
      "0000000b-0000-4000-8000-00000000000b"
    ],
    # Labelled from the post text above, not from the response below.
    expect: :unreadable,
    response:
      "```json\n[\n  {\n    \"book_id\": \"0000000a-0000-4000-8000-00000000000a\",\n    \"confidence\": 0.9,\n    \"reasoning\": \"The post follows Cromwell from Putney to the Tower and back, quoting the scene at Austin Friars twice and returning to the cardinal's fall in the closing section.\"\n  },\n  {\n    \"book_id\": \"0000000b-0000-4000-8000-00000000000b\",\n    \"confidence\": 0.85,\n    \"reasoning\": \"Named as the sequel in the final paragraph, with the trial chapters singled out as the reason the writer could not put i",
    notes:
      "⛔ THE PRODUCTION DEFECT. A 500-character cap cut the JSON mid-object, so the worker ran Jason.decode on a fragment, logged a warning and dropped every association. Expect NO associations and an unparseable outcome — the right answer is to fail loudly."
  },
  %{
    name: "prose_instead_of_json",
    stratum: :broken,
    body: "A post about a reading slump.",
    candidates: [
      "00000001-0000-4000-8000-000000000001"
    ],
    # Labelled from the post text above, not from the response below.
    expect: :unreadable,
    response: "I looked at the post and I don't think any of these books are discussed.",
    notes:
      "The model answering in prose. Must be unparseable rather than silently empty: 'the model refused' and 'the model found nothing' want different fixes."
  },
  %{
    name: "object_not_array",
    stratum: :broken,
    body: "A post naming one book.",
    candidates: [
      "00000002-0000-4000-8000-000000000002"
    ],
    # Labelled from the post text above, not from the response below.
    expect: :unreadable,
    response:
      "{\"book_id\": \"00000002-0000-4000-8000-000000000002\", \"confidence\": 0.8, \"reasoning\": \"Named.\"}",
    notes:
      "Valid JSON of the wrong shape — one association, unwrapped. The model understood the format and not the task, which is a prompt fix rather than a parser fix."
  },
  %{
    name: "associations_key_holds_a_string",
    stratum: :broken,
    body: "A post naming nothing.",
    candidates: [
      "00000003-0000-4000-8000-000000000003"
    ],
    # Labelled from the post text above, not from the response below.
    expect: :unreadable,
    response: "{\"associations\": \"none that I could find\"}",
    notes:
      "The right key holding the wrong type. Acceptance must be about the LIST, not the key's presence."
  },
  %{
    name: "malformed_entry_among_good_ones",
    stratum: :partial,
    body: "A post naming Jazz and Sula.",
    candidates: [
      "00000009-0000-4000-8000-000000000009",
      "00000008-0000-4000-8000-000000000008"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000009-0000-4000-8000-000000000009",
      "00000008-0000-4000-8000-000000000008"
    ],
    response:
      "[{\"book_id\": \"00000009-0000-4000-8000-000000000009\", \"confidence\": 0.9, \"reasoning\": \"Named.\"}, {\"no_book_id\": true}, {\"book_id\": \"00000008-0000-4000-8000-000000000008\", \"confidence\": 0.8, \"reasoning\": \"Named.\"}]",
    notes:
      "⚠️ One bad row must not cost the good ones. All-or-nothing in that direction is the same defect wearing a different face."
  },
  %{
    name: "null_optional_fields",
    stratum: :partial,
    body: "A post naming The Waves.",
    candidates: [
      "00000003-0000-4000-8000-000000000003"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000003-0000-4000-8000-000000000003"
    ],
    response:
      "[{\"book_id\": \"00000003-0000-4000-8000-000000000003\", \"confidence\": null, \"reasoning\": null}]",
    notes:
      "⚖️ NULL, not absent. The schema lists every key as required with the optional ones nullable, so a model obeying it sends null — and both must land the same."
  },
  %{
    name: "missing_confidence",
    stratum: :partial,
    body: "A post naming Pale Fire.",
    candidates: [
      "00000014-0000-4000-8000-000000000014"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000014-0000-4000-8000-000000000014"
    ],
    response:
      "[{\"book_id\": \"00000014-0000-4000-8000-000000000014\", \"reasoning\": \"Named in the second paragraph.\"}]",
    notes: "The key simply absent. Must not discard the association."
  },
  %{
    name: "book_id_not_in_candidates",
    stratum: :hallucination,
    body: "A post naming The Name of the Wind.",
    candidates: [
      "00000013-0000-4000-8000-000000000013"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000013-0000-4000-8000-000000000013",
      "000003e7-0000-4000-8000-0000000003e7"
    ],
    response:
      "[{\"book_id\": \"00000013-0000-4000-8000-000000000013\", \"confidence\": 0.9, \"reasoning\": \"Named.\"}, {\"book_id\": \"000003e7-0000-4000-8000-0000000003e7\", \"confidence\": 0.8, \"reasoning\": \"A book the model invented.\"}]",
    notes:
      "⛔ THE DECODER REPORTS BOTH IDS, INCLUDING THE INVENTED ONE, AND THAT IS " <>
        "CORRECT HERE. Refusing a book that is not in the catalogue is the " <>
        "WORKER's job — `Blog.associate_book/3`'s `foreign_key_constraint(:book_id)` " <>
        "does it against real rows, which this replay has none of. This item used to " <>
        "expect one id, because the eval filtered to the candidate list in its own " <>
        "code: a second implementation of the rule, scoring itself. The refusal is " <>
        "tested in `post_book_association_worker_test.exs`, where a hallucinated id " <>
        "meets an actual foreign key."
  },
  %{
    name: "all_book_ids_hallucinated",
    stratum: :hallucination,
    body: "A post naming nothing in the catalogue.",
    candidates: [
      "00000001-0000-4000-8000-000000000001"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "000003e6-0000-4000-8000-0000000003e6",
      "000003e5-0000-4000-8000-0000000003e5"
    ],
    response:
      "[{\"book_id\": \"000003e6-0000-4000-8000-0000000003e6\", \"confidence\": 0.9, \"reasoning\": \"Invented.\"}, {\"book_id\": \"000003e5-0000-4000-8000-0000000003e5\", \"confidence\": 0.7, \"reasoning\": \"Also invented.\"}]",
    notes:
      "Every id invented. The decoder read two associations and says so; whether either " <>
        "book exists is a question only the database can answer, and does."
  },
  %{
    name: "duplicate_book_id",
    stratum: :hallucination,
    body: "A post naming Orlando twice, in two registers.",
    candidates: [
      "00000002-0000-4000-8000-000000000002"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000002-0000-4000-8000-000000000002",
      "00000002-0000-4000-8000-000000000002"
    ],
    response:
      "[{\"book_id\": \"00000002-0000-4000-8000-000000000002\", \"confidence\": 0.9, \"reasoning\": \"Named in the opening.\"}, {\"book_id\": \"00000002-0000-4000-8000-000000000002\", \"confidence\": 0.6, \"reasoning\": \"Named again at the close.\"}]",
    notes:
      "⛔ THE MODEL SAID IT TWICE, SO THE DECODER REPORTS IT TWICE — and this item " <>
        "found a LIVE DEFECT once it stopped lying. It used to expect one id because " <>
        "the eval de-duplicated in its own code, while `op.post_book_associations` " <>
        "had no unique index and `associate_book/3` inserted unconditionally: a reader " <>
        "whose post discussed one book in two registers got TWO identical " <>
        "associations. Measured, then fixed with a unique index and a " <>
        "`unique_constraint`. The de-duplication is now tested where it happens."
  },
  %{
    name: "book_id_not_a_uuid",
    stratum: :hallucination,
    body: "A post naming a book.",
    candidates: [
      "00000007-0000-4000-8000-000000000007"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "the one about the house"
    ],
    response:
      "[{\"book_id\": \"the one about the house\", \"confidence\": 0.8, \"reasoning\": \"Named by description.\"}]",
    notes:
      "A non-UUID where an id belongs. The decoder passes the string through — `book_id` " <>
        "is required to be a binary and nothing more — and the cast to `:binary_id` " <>
        "refuses it at the changeset, which is where a malformed id should die."
  },
  %{
    name: "confidence_well_above",
    stratum: :confidence,
    body: "A post naming The Lathe of Heaven, with model confidence 0.95.",
    candidates: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    response:
      "[{\"book_id\": \"0000000d-0000-4000-8000-00000000000d\", \"confidence\": 0.95, \"reasoning\": \"Named.\"}]",
    notes:
      "Confidence is RECORDED, not used as a filter here — the reader confirms or dismisses. A corpus item per band is what would catch a threshold being introduced silently."
  },
  %{
    name: "confidence_just_above",
    stratum: :confidence,
    body: "A post naming The Lathe of Heaven, with model confidence 0.55.",
    candidates: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    response:
      "[{\"book_id\": \"0000000d-0000-4000-8000-00000000000d\", \"confidence\": 0.55, \"reasoning\": \"Named.\"}]",
    notes:
      "Confidence is RECORDED, not used as a filter here — the reader confirms or dismisses. A corpus item per band is what would catch a threshold being introduced silently."
  },
  %{
    name: "confidence_mid",
    stratum: :confidence,
    body: "A post naming The Lathe of Heaven, with model confidence 0.5.",
    candidates: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    response:
      "[{\"book_id\": \"0000000d-0000-4000-8000-00000000000d\", \"confidence\": 0.5, \"reasoning\": \"Named.\"}]",
    notes:
      "Confidence is RECORDED, not used as a filter here — the reader confirms or dismisses. A corpus item per band is what would catch a threshold being introduced silently."
  },
  %{
    name: "confidence_low_but_present",
    stratum: :confidence,
    body: "A post naming The Lathe of Heaven, with model confidence 0.11.",
    candidates: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    response:
      "[{\"book_id\": \"0000000d-0000-4000-8000-00000000000d\", \"confidence\": 0.11, \"reasoning\": \"Named.\"}]",
    notes:
      "Confidence is RECORDED, not used as a filter here — the reader confirms or dismisses. A corpus item per band is what would catch a threshold being introduced silently."
  },
  %{
    name: "confidence_zero",
    stratum: :confidence,
    body: "A post naming The Lathe of Heaven, with model confidence 0.0.",
    candidates: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000d-0000-4000-8000-00000000000d"
    ],
    response:
      "[{\"book_id\": \"0000000d-0000-4000-8000-00000000000d\", \"confidence\": 0.0, \"reasoning\": \"Named.\"}]",
    notes:
      "Confidence is RECORDED, not used as a filter here — the reader confirms or dismisses. A corpus item per band is what would catch a threshold being introduced silently."
  },
  %{
    name: "confidence_out_of_range_high",
    stratum: :confidence,
    body: "A post naming Autumn, with confidence 1.4.",
    candidates: [
      "00000011-0000-4000-8000-000000000011"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000011-0000-4000-8000-000000000011"
    ],
    response:
      "[{\"book_id\": \"00000011-0000-4000-8000-000000000011\", \"confidence\": 1.4, \"reasoning\": \"Named.\"}]",
    notes:
      "Above 1.0. The association is real; the number is not, and clamping versus dropping is a decision this item makes visible."
  },
  %{
    name: "confidence_negative",
    stratum: :confidence,
    body: "A post naming Winter, with confidence -0.2.",
    candidates: [
      "00000012-0000-4000-8000-000000000012"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000012-0000-4000-8000-000000000012"
    ],
    response:
      "[{\"book_id\": \"00000012-0000-4000-8000-000000000012\", \"confidence\": -0.2, \"reasoning\": \"Named.\"}]",
    notes: "Below 0. Same decision, opposite end."
  },
  %{
    name: "confidence_as_string",
    stratum: :confidence,
    body: "A post naming Beloved, confidence sent as a string.",
    candidates: [
      "00000007-0000-4000-8000-000000000007"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000007-0000-4000-8000-000000000007"
    ],
    response:
      "[{\"book_id\": \"00000007-0000-4000-8000-000000000007\", \"confidence\": \"0.9\", \"reasoning\": \"Named.\"}]",
    notes: "A JSON string where a number belongs — a real and common model slip."
  },
  %{
    name: "reasoning_empty_string",
    stratum: :reasoning,
    body: "A post naming Sula.",
    candidates: [
      "00000008-0000-4000-8000-000000000008"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000008-0000-4000-8000-000000000008"
    ],
    response:
      "[{\"book_id\": \"00000008-0000-4000-8000-000000000008\", \"confidence\": 0.8, \"reasoning\": \"\"}]",
    notes: "Empty reasoning. The association stands; the owner sees nothing explaining it."
  },
  %{
    name: "reasoning_very_long",
    stratum: :reasoning,
    body: "A post naming Strange & Norrell at length.",
    candidates: [
      "00000010-0000-4000-8000-000000000010"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000010-0000-4000-8000-000000000010"
    ],
    response:
      "[{\"book_id\": \"00000010-0000-4000-8000-000000000010\", \"confidence\": 0.85, \"reasoning\": \"Noooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo\"}]",
    notes:
      "⚠️ A 1,800-character reasoning. The 500-char cap that broke this path was a column limit that travelled from another caller; this item is what notices if one returns."
  },
  %{
    name: "reasoning_with_quotes_and_newlines",
    stratum: :reasoning,
    body: "A post quoting a passage.",
    candidates: [
      "00000014-0000-4000-8000-000000000014"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000014-0000-4000-8000-000000000014"
    ],
    response:
      "[{\"book_id\": \"00000014-0000-4000-8000-000000000014\", \"confidence\": 0.9, \"reasoning\": \"The post quotes \\\"I was the shadow of the waxwing slain\\\"\\nand then returns to it.\"}]",
    notes: "Embedded quotes and newlines. JSON handles them; a hand-rolled extractor would not."
  },
  %{
    name: "fence_uppercase_json",
    stratum: :fence,
    body: "A post naming The Dispossessed.",
    candidates: [
      "0000000c-0000-4000-8000-00000000000c"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "0000000c-0000-4000-8000-00000000000c"
    ],
    response:
      "```JSON\n[\n  {\n    \"book_id\": \"0000000c-0000-4000-8000-00000000000c\",\n    \"confidence\": 0.9,\n    \"reasoning\": \"Named.\"\n  }\n]\n```",
    notes: "```JSON in caps."
  },
  %{
    name: "fence_with_trailing_prose",
    stratum: :fence,
    body: "A post naming Jazz.",
    candidates: [
      "00000009-0000-4000-8000-000000000009"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000009-0000-4000-8000-000000000009"
    ],
    response:
      "```json\n[\n  {\n    \"book_id\": \"00000009-0000-4000-8000-000000000009\",\n    \"confidence\": 0.9,\n    \"reasoning\": \"Named.\"\n  }\n]\n```\n\nLet me know if you'd like more detail.",
    notes: "The model adding a sentence after the fence — chatty models do this constantly."
  },
  %{
    name: "fence_with_leading_prose",
    stratum: :fence,
    body: "A post naming Baudolino.",
    candidates: [
      "00000006-0000-4000-8000-000000000006"
    ],
    # Labelled from the post text above, not from the response below.
    expect: [
      "00000006-0000-4000-8000-000000000006"
    ],
    response:
      "Here are the associations I found:\n\n```json\n[\n  {\n    \"book_id\": \"00000006-0000-4000-8000-000000000006\",\n    \"confidence\": 0.88,\n    \"reasoning\": \"Named.\"\n  }\n]\n```",
    notes: "And before it."
  },
  %{
    name: "whitespace_only_response",
    stratum: :broken,
    body: "A post naming nothing.",
    candidates: [
      "00000003-0000-4000-8000-000000000003"
    ],
    # Labelled from the post text above, not from the response below.
    expect: :unreadable,
    response: "   \n\n  ",
    notes:
      "Whitespace. Must be unparseable rather than an empty answer — 'the model said nothing' is not 'the model found nothing'."
  }
]
