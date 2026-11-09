# The vision eval corpus.
#
# ⛔ EVERY IMAGE HERE IS AUTHORED BY THE OWNER OR SYNTHETIC. No real user upload
# may ever be added — not a sample, not "just the ones that failed", not with
# consent bolted on afterwards. The reason outlives any convenience argument: a
# reader photographing a bookshelf may capture other people who never consented
# to being processed by a vision model, and those people cannot be asked. A
# corpus is forever. See docs/vision-eval-corpus-plan.md.
#
# Six fixtures is far too few to carry an ABSOLUTE accuracy threshold: one image
# changing its mind moves the score 16.7 points, which reads as rigour and
# behaves as noise. So the harness gates on NO REGRESSION against a recorded
# baseline instead. docs/vision-eval-corpus-plan.md specifies the ~120-image
# corpus that would make per-stratum thresholds defensible; expanding to it is
# deliberately deferred.
#
# `expect_book: false` is as load-bearing as the true cases — a model that says
# "yes, a book" to everything scores perfectly on books alone.
[
  %{
    name: "barcode",
    path: "images/barcode_isbn_clean.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    # The Name of the Rose (Umberto Eco) — this fixture's actual subject, per
    # `upload.spec.ts` ("identifies The Name of the Rose from
    # barcode_isbn_clean.jpg"). NOT 9780061470769, which is Bird Lake Moon and
    # appears only in the manual-ISBN-entry specs; the corpus plan conflated the
    # two, and the model was right where this label was wrong.
    expect_isbn: "9780156001311",
    expect_rejection: false,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "A clean rear-cover barcode: the easiest case the barcode tier exists to get right. If this one fails, the tier is broken rather than strained."
  },
  %{
    name: "not_a_book",
    path: "images/not_a_book.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    expect_rejection: true,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "A negative. Rejection accuracy is unscorable without these — a model answering \"yes, a book\" to everything scores perfectly on books alone."
  },
  %{
    name: "reversed",
    path: "images/screenshot_image_reversed.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: nil,
    expect_rejection: false,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "Spine away from the camera. Tests whether the cascade falls through to the VLM rather than guessing from a barcode that is not visible."
  },
  %{
    name: "reversed_cutoff",
    path: "images/screenshot_image_reversed_and_cut_off.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: nil,
    expect_rejection: false,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "Reversed AND cropped, so neither barcode nor full cover is available. The hardest orientation case in the set."
  },
  %{
    name: "obscured",
    path: "images/screenshot_mildly_obscured.jpg",
    stratum: :occlusion,
    expect_book: true,
    expect_isbn: nil,
    expect_rejection: false,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "A hand across part of the cover. Occlusion is the commonest real-world failure a reader photographing their own shelf will produce."
  },
  %{
    name: "mixed_text",
    path: "images/screenshot_mixed_text.jpg",
    stratum: :text_clutter,
    expect_book: true,
    expect_isbn: nil,
    expect_rejection: false,
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "Competing text in frame. Tests that the model picks the book rather than the loudest string."
  }
]
