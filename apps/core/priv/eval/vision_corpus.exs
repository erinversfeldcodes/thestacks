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
    # Identity recovered from `upload.spec.ts`, which both NAMES this fixture
    # ("identifies Flyboys from screenshot_image_reversed.jpg") and asserts
    # the title in its body. ⛔ No `expect_isbn`: a photograph is of one
    # physical copy and this work has many editions, so an ISBN derived from
    # the title would be a guess. That exact guess is already documented
    # above — the plan cited Bird Lake Moon's ISBN for the barcode fixture.
    expect_title: "Flyboys",
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
    # Identity from the spec's test name ("identifies Train to Crystal City
    # from screenshot_image_reversed_and_cut_off.jpg"). ⚠️ Weaker evidence
    # than the Flyboys case: the name records it, the body does not assert
    # it. Recorded because a title in a test name is still the author's
    # statement of what the image shows, and nothing else records it.
    expect_title: "Train to Crystal City",
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
    # Identity from the spec's test name, same standard as above.
    expect_title: "Born Again Bodies",
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
    provenance: %{photographer: "owner", captured: "2026-08-19", source: :owned},
    notes:
      "Competing text in frame. Tests that the model picks the book rather than the loudest string."
  },
  %{
    name: "negative_non_isbn_barcode",
    path: "images/negative_non_isbn_barcode.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{photographer: "generated", captured: "2026-11-09", source: :synthetic},
    notes:
      "⛔ THE SHARPEST NEGATIVE IN THE SET, and the only one that can catch this " <>
        "particular mistake. It is a real, cleanly decodable EAN-13 — verified live, " <>
        "pyzbar reads 0123456789050 — so \"I read a barcode\" is TRUE and \"this is a " <>
        "book\" is FALSE. ISBN-13 lives under the 978/979 Bookland prefixes; this is an " <>
        "ordinary product code. A barcode tier that accepts any EAN-13 as a book passes " <>
        "every other fixture here and fails only this one."
  },
  %{
    name: "negative_text_document",
    path: "images/negative_text_document.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{photographer: "generated", captured: "2026-11-09", source: :synthetic},
    notes:
      "A page of printed text that is not a book cover — a utility statement. Tests " <>
        "that recognising TEXT does not imply recognising a BOOK: OCR succeeds here and " <>
        "the right answer is still no. Verified to carry no barcode at all, so it " <>
        "exercises the far end of the cascade rather than the near end."
  },

  # ═══════════════════════════════════════════════════════════════════════
  # OWNER-AUTHORED PHOTOGRAPHS, 2026-11-12/13 — 114 images, every one shot by
  # the owner or derived from one of those shots.
  #
  # ⛔ The eight fixtures above are SCREENSHOTS, and the first shadow run of
  # the CPU text pass showed what that costs: it read "Add comment" at 0.95
  # confidence off the social-media chrome in `reversed_cutoff`, and scored
  # 0 of 7 correct titles across them. Those fixtures cannot measure a text
  # tier, because the most legible type in frame is never the book. The rows
  # below are photographs of physical books, where that confound is absent.
  #
  # ⚖️ Identity follows each image's own evidence: an ISBN only where its
  # check digit verified off the barcode, a title where the barcode was
  # unreadable but the cover was not, and neither for a rejection case.
  # Nothing was inferred from a title to an ISBN — a photograph is of one
  # edition and most of these works have many, which is the error this
  # corpus already records above.
  #
  # Generated by `mix eval.corpus.intake --rows`, which parses the identity
  # out of each filename and reports anything it could not read rather than
  # guessing at it.
  # ═══════════════════════════════════════════════════════════════════════
  %{
    name: "adjacent-blank-green-notebook",
    path: "images/adjacent-blank-green-notebook.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-board-game-box-propolis",
    path: "images/adjacent-board-game-box-propolis.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-board-game-spines",
    path: "images/adjacent-board-game-spines.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-bookshelf-close",
    path: "images/adjacent-bookshelf-close.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-cookbook-shelf-at-distance",
    path: "images/adjacent-cookbook-shelf-at-distance.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-desk-shelf-at-distance",
    path: "images/adjacent-desk-shelf-at-distance.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-dvd-princess-bride",
    path: "images/adjacent-dvd-princess-bride.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-dvd-spine-stack",
    path: "images/adjacent-dvd-spine-stack.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-lego-box",
    path: "images/adjacent-lego-box.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-moleskine-recipe-journal",
    path: "images/adjacent-moleskine-recipe-journal.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-puzzle-boxes",
    path: "images/adjacent-puzzle-boxes.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "adjacent-winnie-the-pooh-slipcase",
    path: "images/adjacent-winnie-the-pooh-slipcase.jpg",
    stratum: :book_adjacent,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Book-shaped but not a book. The hardest rejection case."
  },
  %{
    name: "clean-9780141192352",
    path: "images/clean-9780141192352.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780141192352",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780141979540",
    path: "images/clean-9780141979540.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780141979540",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780141995106",
    path: "images/clean-9780141995106.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780141995106",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780241472866",
    path: "images/clean-9780241472866.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780241472866",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780375703768",
    path: "images/clean-9780375703768.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780375703768",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780796009814",
    path: "images/clean-9780796009814.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780796009814",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9780869752166",
    path: "images/clean-9780869752166.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9780869752166",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781250056030",
    path: "images/clean-9781250056030.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781250056030",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781431429837",
    path: "images/clean-9781431429837.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781431429837",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781529356021",
    path: "images/clean-9781529356021.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781529356021",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781682193747",
    path: "images/clean-9781682193747.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781682193747",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781776149841",
    path: "images/clean-9781776149841.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781776149841",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781776252473",
    path: "images/clean-9781776252473.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781776252473",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781784873691",
    path: "images/clean-9781784873691.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781784873691",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781802063318",
    path: "images/clean-9781802063318.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781802063318",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781804369999",
    path: "images/clean-9781804369999.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781804369999",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9781918073034",
    path: "images/clean-9781918073034.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9781918073034",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "clean-9789054613893",
    path: "images/clean-9789054613893.jpg",
    stratum: :clean_barcode,
    expect_book: true,
    expect_isbn: "9789054613893",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Back cover, barcode sharp and face-on. The cheap path's control."
  },
  %{
    name: "cover-a-cageful-of-butterflies",
    path: "images/cover-a-cageful-of-butterflies.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "a cageful of butterflies",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-a-child-is-born",
    path: "images/cover-a-child-is-born.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "a child is born",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-bad-pharma",
    path: "images/cover-bad-pharma.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "bad pharma",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-dreaming-the-karoo",
    path: "images/cover-dreaming-the-karoo.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "dreaming the karoo",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-follow-that-unicorn",
    path: "images/cover-follow-that-unicorn.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "follow that unicorn",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-how-science-works",
    path: "images/cover-how-science-works.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "how science works",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-how-to-survive-family-holidays",
    path: "images/cover-how-to-survive-family-holidays.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "how to survive family holidays",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-introducing-aristotle",
    path: "images/cover-introducing-aristotle.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "introducing aristotle",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-on-guerrilla-warfare",
    path: "images/cover-on-guerrilla-warfare.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "on guerrilla warfare",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-secret-prague",
    path: "images/cover-secret-prague.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "secret prague",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-shatterglass",
    path: "images/cover-shatterglass.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "shatterglass",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-art-of-worldly-wisdom",
    path: "images/cover-the-art-of-worldly-wisdom.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the art of worldly wisdom",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-cat-who-saved-books",
    path: "images/cover-the-cat-who-saved-books.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the cat who saved books",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-five-dysfunctions-of-a-team",
    path: "images/cover-the-five-dysfunctions-of-a-team.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the five dysfunctions of a team",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-new-complete-book-of-self-sufficiency",
    path: "images/cover-the-new-complete-book-of-self-sufficiency.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the new complete book of self sufficiency",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-odd-egg",
    path: "images/cover-the-odd-egg.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the odd egg",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-pythons-autobiography",
    path: "images/cover-the-pythons-autobiography.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the pythons autobiography",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-signalman",
    path: "images/cover-the-signalman.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the signalman",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-taggerung",
    path: "images/cover-the-taggerung.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the taggerung",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-tibetan-book-of-the-dead",
    path: "images/cover-the-tibetan-book-of-the-dead.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the tibetan book of the dead",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-the-year-of-magical-thinking",
    path: "images/cover-the-year-of-magical-thinking.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the year of magical thinking",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "cover-trainspotting",
    path: "images/cover-trainspotting.jpg",
    stratum: :clear_cover,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "trainspotting",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Front cover, no barcode. Identification without scanning."
  },
  %{
    name: "hostile-9780312853235-angled",
    path: "images/hostile-9780312853235-angled.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9780312853235",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9780552998055-sticker-over-barcode",
    path: "images/hostile-9780552998055-sticker-over-barcode.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9780552998055",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9780670021291-lowlight",
    path: "images/hostile-9780670021291-lowlight.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9780670021291",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9780722532935-lowlight",
    path: "images/hostile-9780722532935-lowlight.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9780722532935",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9780747597155-thumb-over-barcode",
    path: "images/hostile-9780747597155-thumb-over-barcode.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9780747597155",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9781250322159-rotated90",
    path: "images/hostile-9781250322159-rotated90.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9781250322159",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9781401308773-thumb-over-barcode",
    path: "images/hostile-9781401308773-thumb-over-barcode.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9781401308773",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-9781529050868-angled",
    path: "images/hostile-9781529050868-angled.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: "9781529050868",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-bhagavad-gita-as-it-is",
    path: "images/hostile-bhagavad-gita-as-it-is.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "bhagavad gita as it is",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-blue-bird-picture-book",
    path: "images/hostile-blue-bird-picture-book.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "blue bird picture book",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-families-belong",
    path: "images/hostile-families-belong.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "families belong",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-grey-hardcover-emblems",
    path: "images/hostile-grey-hardcover-emblems.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "grey hardcover emblems",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-heart-of-darkness",
    path: "images/hostile-heart-of-darkness.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "heart of darkness",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-how-to-make-your-first-million",
    path: "images/hostile-how-to-make-your-first-million.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "how to make your first million",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-moon-whales",
    path: "images/hostile-moon-whales.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "moon whales",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-star-wars-a-scanimation-book",
    path: "images/hostile-star-wars-a-scanimation-book.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "star wars a scanimation book",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-the-children-of-mer",
    path: "images/hostile-the-children-of-mer.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the children of mer",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-the-collected-poems-of-emily-dickinson",
    path: "images/hostile-the-collected-poems-of-emily-dickinson.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the collected poems of emily dickinson",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-the-dichotomy-of-leadership",
    path: "images/hostile-the-dichotomy-of-leadership.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the dichotomy of leadership",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "hostile-the-last-days-of-new-paris",
    path: "images/hostile-the-last-days-of-new-paris.jpg",
    stratum: :hostile_barcode,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the last days of new paris",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Barcode present but hard: angled, dim, covered or rotated."
  },
  %{
    name: "illegible-9780141192352-blur",
    path: "images/illegible-9780141192352-blur.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780141192352-dark",
    path: "images/illegible-9780141192352-dark.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780141979540-blur",
    path: "images/illegible-9780141979540-blur.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780141979540-dark",
    path: "images/illegible-9780141979540-dark.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780141995106-blur",
    path: "images/illegible-9780141995106-blur.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780141995106-dark",
    path: "images/illegible-9780141995106-dark.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780241472866-blur",
    path: "images/illegible-9780241472866-blur.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780241472866-dark",
    path: "images/illegible-9780241472866-dark.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780375703768-blur",
    path: "images/illegible-9780375703768-blur.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "illegible-9780375703768-dark",
    path: "images/illegible-9780375703768-dark.jpg",
    stratum: :illegible,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Blurred or underexposed. Must decline rather than guess."
  },
  %{
    name: "mirrored-9780141192352-mirrored",
    path: "images/mirrored-9780141192352-mirrored.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141192352",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141192352-rot180",
    path: "images/mirrored-9780141192352-rot180.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141192352",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141192352-rot90",
    path: "images/mirrored-9780141192352-rot90.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141192352",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141979540-mirrored",
    path: "images/mirrored-9780141979540-mirrored.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141979540",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141979540-rot180",
    path: "images/mirrored-9780141979540-rot180.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141979540",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141979540-rot90",
    path: "images/mirrored-9780141979540-rot90.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141979540",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141995106-mirrored",
    path: "images/mirrored-9780141995106-mirrored.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141995106",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141995106-rot180",
    path: "images/mirrored-9780141995106-rot180.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141995106",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780141995106-rot90",
    path: "images/mirrored-9780141995106-rot90.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780141995106",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "mirrored-9780241472866-mirrored",
    path: "images/mirrored-9780241472866-mirrored.jpg",
    stratum: :hostile_orientation,
    expect_book: true,
    expect_isbn: "9780241472866",
    provenance: %{
      photographer: "generated",
      captured: "2026-11-13",
      source: :synthetic
    },
    notes: "Mirrored or rotated; pyzbar cannot decode a mirrored barcode."
  },
  %{
    name: "multi-9781784873691-9780007266883",
    path: "images/multi-9781784873691-9780007266883.jpg",
    stratum: :multiple_books,
    expect_book: true,
    expect_isbn: "9781784873691",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Several books in one frame."
  },
  %{
    name: "neg-bear-birthday-cake",
    path: "images/neg-bear-birthday-cake.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-bird-on-roof",
    path: "images/neg-bird-on-roof.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-car-bumper-scuff",
    path: "images/neg-car-bumper-scuff.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-cat-on-floorboards",
    path: "images/neg-cat-on-floorboards.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-childs-jacket-on-rail",
    path: "images/neg-childs-jacket-on-rail.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-dog-asleep-on-lap",
    path: "images/neg-dog-asleep-on-lap.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-dog-in-car",
    path: "images/neg-dog-in-car.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-empty-room-with-broom",
    path: "images/neg-empty-room-with-broom.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-foil-covered-tray",
    path: "images/neg-foil-covered-tray.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-garden-centre-rose-sign",
    path: "images/neg-garden-centre-rose-sign.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-jumping-spider-on-vine-leaf",
    path: "images/neg-jumping-spider-on-vine-leaf.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-robot-vacuum-display",
    path: "images/neg-robot-vacuum-display.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-sauce-bottles",
    path: "images/neg-sauce-bottles.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-screenshot-grocery-table",
    path: "images/neg-screenshot-grocery-table.png",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-solar-inverter-wiring",
    path: "images/neg-solar-inverter-wiring.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-strelitzia-plant",
    path: "images/neg-strelitzia-plant.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "neg-tile-samples",
    path: "images/neg-tile-samples.jpg",
    stratum: :negative,
    expect_book: false,
    expect_isbn: nil,
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Not a book. A false accept here is worse than a false reject."
  },
  %{
    name: "typo-alice-in-wonderland",
    path: "images/typo-alice-in-wonderland.jpg",
    stratum: :hostile_typography,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "alice in wonderland",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Title hard to read as text: drawn, decorative or lost in design."
  },
  %{
    name: "typo-roasted",
    path: "images/typo-roasted.jpg",
    stratum: :hostile_typography,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "roasted",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Title hard to read as text: drawn, decorative or lost in design."
  },
  %{
    name: "typo-the-anarchists",
    path: "images/typo-the-anarchists.jpg",
    stratum: :hostile_typography,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the anarchists",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Title hard to read as text: drawn, decorative or lost in design."
  },
  %{
    name: "typo-the-ironwood-tree",
    path: "images/typo-the-ironwood-tree.jpg",
    stratum: :hostile_typography,
    expect_book: true,
    expect_isbn: nil,
    expect_title: "the ironwood tree",
    provenance: %{
      photographer: "owner",
      captured: "2026-11-13",
      source: :owned
    },
    notes: "Title hard to read as text: drawn, decorative or lost in design."
  }
]
