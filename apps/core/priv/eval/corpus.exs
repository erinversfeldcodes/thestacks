crystal_city_ol_docs = [
  %{
    isbn: "9781429964500",
    meta: %{
      title: "The Crystal City",
      subtitle: nil,
      author: "Orson Scott Card",
      subjects: [
        "Alvin Maker (Fictitious character)",
        "Fiction",
        "Magic",
        "Frontier and pioneer life",
        "Fiction, fantasy, general"
      ],
      source: :open_library
    }
  },
  %{
    isbn: "9780505521453",
    meta: %{
      title: "The Crystal City",
      subtitle: nil,
      author: "Janice Tarantino",
      subjects: [],
      source: :open_library
    }
  },
  %{
    isbn: "9781451693669",
    meta: %{
      title: "The train to Crystal City",
      subtitle: nil,
      author: "Jan Jarboe Russell",
      subjects: [
        "Concentration camps",
        "German Americans",
        "World War, 1939-1945",
        "Crystal City Internment Camp (Crystal City, Tex.)",
        "Evacuation of civilians"
      ],
      source: :open_library
    }
  },
  %{
    isbn: "9780590354653",
    meta: %{
      title: "The crystal city",
      subtitle: nil,
      author: "Nancy Etchemendy",
      subjects: ["Science fiction", "Children's fiction"],
      source: :open_library
    }
  }
]

crystal_city_junk_doc = %{
  isbn: "0812444647",
  meta: %{
    title: "Crystal City-CC",
    subtitle: nil,
    author: nil,
    subjects: [],
    source: :open_library
  }
}

[
  %{
    id: "crystal_city_june",
    description:
      "June baseline: VLM absorbs the subtitle into the title and invents " <>
        "the author; Russell's internment-camp subjects must beat Card's " <>
        "exact-prefix title (the failure candidate scoring was built for)",
    signals: %{
      title: "The Crystal City: The Tragedy of America's First Internment Camp",
      author: "Doris Akers",
      raw_text: "THE CRYSTAL CI IT IS ABOUT F DRS"
    },
    candidates: crystal_city_ol_docs,
    expected: "9781451693669",
    known_failure: false
  },
  %{
    id: "crystal_city_july_tramps",
    description:
      "July garbage read (\"The Tramp's Crystal City\", no author): no " <>
        "candidate explains the 'tramps' token — an honest :not_found beats " <>
        "committing to anything. KNOWN OPEN: Russell scores 5.0 (its " <>
        "subjects legitimately contain 'crystal city') and wins under every " <>
        "floor <= 3.5; fixing this needs an unexplained-signal-token lever, " <>
        "not a floor/penalty change.",
    signals: %{
      title: "The Tramp's Crystal City",
      author: nil,
      raw_text: "THE TRAMP'S CRYSTAL CITY"
    },
    candidates: crystal_city_ol_docs ++ [crystal_city_junk_doc],
    expected: :not_found,
    known_failure: true
  },
  %{
    id: "crystal_city_july_tragedy",
    description:
      "July variant with a salvageable read: 'tragedy' + raw_text fragments " <>
        "must still land on Russell via subjects evidence, junk record present",
    signals: %{
      title: "The Tragedy of the Crystal City",
      author: "Drs. R.",
      raw_text: "THE TRA CRYSTAL CI IT IS ABOUT F DRS."
    },
    candidates: crystal_city_ol_docs ++ [crystal_city_junk_doc],
    expected: "9781451693669",
    known_failure: false
  },
  %{
    id: "crystal_city_junk_only",
    description:
      "Production-faithful reduction of the July junk-pick: when the junk " <>
        "record is the only surviving candidate (score 3.0 = subset title " <>
        "overlap + raw_text, nothing else), it must not win. KNOWN OPEN: " <>
        "3.0 is also the exact score of a LEGITIMATE cut-off-title pick " <>
        "with no corroboration ('Gatsby' vs 'The Great Gatsby'), so raising " <>
        "the floor past 3.0 trades this fix for broken partial-title " <>
        "resolution (see isbn_resolver_test 'with single-word title...').",
    signals: %{
      title: "The Tramp's Crystal City",
      author: nil,
      raw_text: "THE TRAMP'S CRYSTAL CITY"
    },
    candidates: [crystal_city_junk_doc],
    expected: :not_found,
    known_failure: true
  },
  %{
    id: "klara_study_guide",
    description:
      "GB derivative edition ('Study Guide: ...' with the author mislabelled " <>
        "as Ishiguro himself) displaces the real work: the derivative title " <>
        "absorbs the author tokens (raw_text 4/4 vs 2/4) AND collects the " <>
        "author bonus. The derivative-title penalty must flip the pick.",
    signals: %{
      title: "Klara and the Sun",
      author: "Kazuo Ishiguro",
      raw_text: "KLARA AND THE SUN KAZUO ISHIGURO"
    },
    candidates: [
      %{
        isbn: "9780571364879",
        meta: %{
          title: "Klara and the Sun",
          subtitle: nil,
          author: "Kazuo Ishiguro",
          subjects: ["Fiction", "Science fiction"],
          source: :google_books
        }
      },
      %{
        isbn: "9798767950103",
        meta: %{
          title: "Study Guide: Klara and the Sun by Kazuo Ishiguro",
          subtitle: nil,
          author: "Kazuo Ishiguro",
          subjects: ["Study Aids"],
          source: :google_books
        }
      }
    ],
    expected: "9780571364879",
    known_failure: false
  },
  %{
    id: "born_again_bodies",
    description:
      "Easy-case regression guard: single matching candidate " <>
        "(screenshot_mildly_obscured.jpg E2E fixture) must keep resolving. " <>
        "raw_text reconstructs the cover read from the production run.",
    signals: %{
      title: "Born Again Bodies: Flesh and Spirit in American Christianity",
      author: "R. Marie Griffith",
      raw_text:
        "BORN AGAIN BODIES Flesh and Spirit in American Christianity " <>
          "R. MARIE GRIFFITH author of God's Daughters"
    },
    candidates: [
      %{
        isbn: "9780520242401",
        meta: %{
          title: "Born again bodies",
          subtitle: nil,
          author: "R. Marie Griffith",
          subjects: [
            "Christianity",
            "History of doctrines",
            "Human body",
            "Religious aspects",
            "Flesh (Theology)"
          ],
          source: :open_library
        }
      }
    ],
    expected: "9780520242401",
    known_failure: false
  },
  %{
    id: "garbage_floor_guard",
    description:
      "July 'Crystal Warriors' case: GB-only fuzzy garbage for a corrupted " <>
        "query — everything must land under the plausibility floor",
    signals: %{
      title: "The Tragedy of the Crystal City",
      author: "Drs. R.",
      raw_text: "THE TRA CRYSTAL CI IT IS ABOUT F DRS."
    },
    candidates: [
      %{
        isbn: "0380752727",
        meta: %{
          title: "The Crystal Warriors",
          subtitle: nil,
          author: "William R. Forstchen",
          subjects: ["Fiction"],
          source: :google_books
        }
      },
      %{
        isbn: "0380760215",
        meta: %{
          title: "The Crystal Sorcerers",
          subtitle: nil,
          author: "William R. Forstchen",
          subjects: ["Fiction"],
          source: :google_books
        }
      },
      %{
        isbn: "9780345542748",
        meta: %{
          title: "The Essential Guide to Warfare: Star Wars",
          subtitle: nil,
          author: "Jason Fry, Paul R. Urquhart",
          subjects: ["Fiction"],
          source: :google_books
        }
      }
    ],
    expected: :not_found,
    known_failure: false
  }
]
