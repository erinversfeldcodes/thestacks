# Seed fixtures for development and dbt testing.
# Run with: mix run apps/core/priv/repo/seeds.exs
# Or via:   just test-dbt  (which resets the DB first)
#
# Dev logins:
#   owner@thestacks.app / dev-password-123  (owner role)
#   user@thestacks.app  / dev-password-456  (user role — for IDOR/E2E tests)

alias Core.Repo

defmodule Seeds do
  @doc "Generate a deterministic UUID from a zero-padded integer suffix."
  def uuid(n) do
    suffix = n |> Integer.to_string() |> String.pad_leading(12, "0")
    Ecto.UUID.dump!("a1b2c3d4-0000-0000-0000-#{suffix}")
  end

  @doc """
  Strip edition suffixes to get a canonical title for grouping.
  "Circe (PB)" → "Circe", "The Secret History (Penguin)" → "The Secret History"
  """
  def canonical_title(title) do
    title
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> String.trim()
  end

  @doc "E2E test suite definitions: {user_uuid_index, slug, display_name}"
  def e2e_suites do
    [
      {10, "age-gate", "E2E Age Gate"},
      {11, "auth", "E2E Auth"},
      {12, "book-detail", "E2E Book Detail"},
      {13, "book-interaction", "E2E Book Interaction"},
      {14, "bookshelf", "E2E Bookshelf"},
      {15, "catalogue", "E2E Catalogue"},
      {16, "editions", "E2E Editions"},
      {17, "looking-for-home", "E2E Looking For Home"},
      {18, "navigation", "E2E Navigation"},
      {19, "reading-pile", "E2E Reading Pile"},
      {20, "reading-pile-hover", "E2E Reading Pile Hover"},
      {21, "search", "E2E Search"},
      {22, "settings", "E2E Settings"},
      {23, "shelf-actions", "E2E Shelf Actions"},
      {24, "upload", "E2E Upload"}
    ]
  end
end

# ── Timestamps ──────────────────────────────────────────────────────────────

jan_01 = ~U[2026-01-01 00:00:00.000000Z]
jan_05 = ~U[2026-01-05 00:00:00.000000Z]
jan_10 = ~U[2026-01-10 00:00:00.000000Z]
jan_15 = ~U[2026-01-15 00:00:00.000000Z]
jan_20 = ~U[2026-01-20 00:00:00.000000Z]
feb_01 = ~U[2026-02-01 00:00:00.000000Z]
feb_14 = ~U[2026-02-14 00:00:00.000000Z]
mar_01 = ~U[2026-03-01 00:00:00.000000Z]

# ── Users ───────────────────────────────────────────────────────────────────

e2e_users =
  Enum.map(Seeds.e2e_suites(), fn {idx, slug, display} ->
    %{
      id: Seeds.uuid(idx),
      email: "e2e-#{slug}@thestacks.test",
      display_name: display,
      password_hash: Argon2.hash_pwd_salt("e2e-password"),
      role: "user",
      profile_visibility: "owner",
      age_verified: true,
      age_verified_at: jan_01,
      country_code: "ZA",
      city: "Test City",
      consent_analytics: true,
      consent_analytics_at: jan_01,
      created_at: jan_01,
      updated_at: jan_01
    }
  end)

Repo.insert_all(
  "users",
  [
    %{
      id: Seeds.uuid(1),
      email: "owner@thestacks.app",
      display_name: "Platform Owner",
      password_hash: Argon2.hash_pwd_salt("dev-password-123"),
      role: "owner",
      profile_visibility: "owner",
      age_verified: true,
      age_verified_at: jan_01,
      country_code: "ZA",
      city: "Johannesburg",
      consent_analytics: true,
      consent_analytics_at: jan_01,
      created_at: jan_01,
      updated_at: jan_01
    },
    %{
      id: Seeds.uuid(2),
      email: "user@thestacks.app",
      display_name: "Test User",
      password_hash: Argon2.hash_pwd_salt("dev-password-456"),
      role: "user",
      profile_visibility: "owner",
      age_verified: false,
      country_code: "ZA",
      city: "Cape Town",
      consent_analytics: false,
      created_at: jan_01,
      updated_at: jan_01
    }
  ] ++ e2e_users,
  prefix: "op",
  on_conflict: :nothing
)

# ── Authors ─────────────────────────────────────────────────────────────────

authors_data = [
  {101, "Ursula K. Le Guin"},
  {102, "Plato"},
  {103, "Donna Tartt"},
  {104, "Umberto Eco"},
  {105, "Kazuo Ishiguro"},
  {106, "Jorge Luis Borges"},
  {107, "Fyodor Dostoevsky"},
  {108, "Virginia Woolf"},
  {109, "Gabriel Garcia Marquez"},
  {110, "Toni Morrison"},
  {111, "Haruki Murakami"},
  {112, "Octavia E. Butler"},
  {113, "Milan Kundera"},
  {114, "Italo Calvino"},
  {115, "Margaret Atwood"},
  {116, "Ray Bradbury"},
  {117, "Chimamanda Ngozi Adichie"},
  {118, "Carlos Ruiz Zafon"},
  {119, "Madeline Miller"},
  {120, "Patrick Rothfuss"}
]

author_rows =
  Enum.map(authors_data, fn {idx, name} ->
    %{
      id: Seeds.uuid(idx),
      name: name,
      created_at: jan_01,
      updated_at: jan_01
    }
  end)

Repo.insert_all("authors", author_rows, prefix: "op", on_conflict: :nothing)

# ── Books ───────────────────────────────────────────────────────────────────
# {book_index, isbn, title, author_index, page_count, year, subjects, visibility_tier}

books_data = [
  # ── Le Guin (101) ──
  {1001, "9780061120084", "The Left Hand of Darkness", 101, 304, 1969,
   ["Science Fiction", "Fiction"], "public"},
  {1002, "9780061470769", "The Dispossessed", 101, 387, 1974, ["Science Fiction", "Fiction"],
   "public"},
  {1003, "9780060512750", "The Lathe of Heaven", 101, 184, 1971, ["Science Fiction", "Fiction"],
   "public"},
  {1004, "9780689845345", "A Wizard of Earthsea", 101, 183, 1968, ["Fantasy", "Fiction"],
   "public"},
  {1005, "9780060766382", "The Tombs of Atuan", 101, 163, 1971, ["Fantasy", "Fiction"], "public"},
  {1006, "9780151014781", "Lavinia", 101, 279, 2008, ["Historical Fiction", "Fiction"], "public"},
  {1007, "9780060512743", "The Telling", 101, 264, 2000, ["Science Fiction", "Fiction"],
   "public"},
  {1008, "9780060766399", "The Farthest Shore", 101, 197, 1972, ["Fantasy", "Fiction"], "public"},
  {1009, "9780553382563", "Tehanu", 101, 226, 1990, ["Fantasy", "Fiction"], "public"},
  {1010, "9780156027786", "The Other Wind", 101, 246, 2001, ["Fantasy", "Fiction"], "public"},

  # ── Plato (102) ──
  {1011, "9780140449280", "The Republic", 102, 416, -380, ["Philosophy", "Classic"], "public"},
  {1012, "9780140455113", "Phaedrus", 102, 103, -370, ["Philosophy", "Classic"], "public"},
  {1013, "9780872201798", "Symposium", 102, 128, -385, ["Philosophy", "Classic"], "public"},
  {1014, "9780199537761", "The Republic (Oxford)", 102, 416, -380, ["Philosophy", "Classic"],
   "public"},
  # Use different editions / translations for Plato
  {1015, "9780199535767", "Meno and Other Dialogues", 102, 224, -390, ["Philosophy", "Classic"],
   "public"},
  {1016, "9780140440409", "The Last Days of Socrates", 102, 256, -399, ["Philosophy", "Classic"],
   "public"},
  {1017, "9780872206335", "Five Dialogues", 102, 156, -380, ["Philosophy", "Classic"], "public"},
  {1018, "9780872204928", "Gorgias", 102, 128, -380, ["Philosophy", "Classic"], "public"},
  {1019, "9780199537525", "Theaetetus", 102, 240, -369, ["Philosophy", "Classic"], "public"},
  {1020, "9780140449273", "Timaeus and Critias", 102, 160, -360, ["Philosophy", "Classic"],
   "public"},

  # ── Donna Tartt (103) ──
  {1021, "9780679410324", "The Secret History", 103, 559, 1992,
   ["Literary Fiction", "Dark Academia"], "public"},
  {1022, "9780316258784", "The Goldfinch", 103, 771, 2013, ["Literary Fiction", "Fiction"],
   "public"},
  {1023, "9781400031702", "The Little Friend", 103, 555, 2002, ["Literary Fiction", "Mystery"],
   "public"},
  {1024, "9780140169881", "The Secret History (Penguin)", 103, 559, 1992,
   ["Literary Fiction", "Dark Academia"], "public"},
  {1025, "9780316055437", "The Goldfinch (Paperback)", 103, 771, 2013,
   ["Literary Fiction", "Fiction"], "public"},
  {1026, "9780375508455", "The Secret History (Vintage)", 103, 559, 1992,
   ["Literary Fiction", "Dark Academia"], "public"},
  {1027, "9780316066525", "The Goldfinch (Mass Market)", 103, 771, 2013,
   ["Literary Fiction", "Fiction"], "public"},
  {1028, "9780679421313", "The Secret History (Modern)", 103, 559, 1992,
   ["Literary Fiction", "Dark Academia"], "public"},
  {1029, "9780316058933", "The Goldfinch (HB)", 103, 771, 2013, ["Literary Fiction", "Fiction"],
   "public"},
  {1030, "9780141006314", "The Little Friend (Penguin)", 103, 555, 2002,
   ["Literary Fiction", "Mystery"], "public"},

  # ── Umberto Eco (104) ──
  {1031, "9780156030410", "The Name of the Rose", 104, 536, 1980,
   ["Historical Fiction", "Mystery"], "public"},
  {1032, "9780151006908", "Baudolino", 104, 528, 2000, ["Historical Fiction", "Fiction"],
   "public"},
  {1033, "9780156032971", "The Mysterious Flame of Queen Loana", 104, 480, 2004,
   ["Fiction", "Mystery"], "public"},
  {1034, "9780544133563", "The Book of Legendary Lands", 104, 480, 2013,
   ["Non-Fiction", "Fiction"], "public"},
  {1035, "9780156028028", "Foucault's Pendulum", 104, 641, 1988, ["Fiction", "Mystery"],
   "public"},
  {1036, "9780156029766", "The Island of the Day Before", 104, 515, 1994,
   ["Historical Fiction", "Fiction"], "public"},
  {1037, "9780547539553", "The Prague Cemetery", 104, 464, 2010,
   ["Historical Fiction", "Fiction"], "age_gated"},
  {1038, "9780544133556", "Numero Zero", 104, 208, 2015, ["Fiction", "Mystery"], "public"},
  {1039, "9780156030830", "Travels in Hyperreality", 104, 320, 1986,
   ["Non-Fiction", "Philosophy"], "public"},
  {1040, "9780253213396", "A Theory of Semiotics", 104, 354, 1976, ["Non-Fiction", "Philosophy"],
   "public"},

  # ── Ishiguro (105) ──
  {1041, "9780571258093", "The Remains of the Day", 105, 245, 1989,
   ["Literary Fiction", "Classic"], "public"},
  {1042, "9780571225385", "Never Let Me Go", 105, 288, 2005,
   ["Science Fiction", "Literary Fiction"], "public"},
  {1043, "9780525559474", "Klara and the Sun", 105, 303, 2021,
   ["Science Fiction", "Literary Fiction"], "public"},
  {1044, "9780571283637", "The Buried Giant", 105, 317, 2015, ["Fantasy", "Literary Fiction"],
   "public"},
  {1045, "9780571209132", "When We Were Orphans", 105, 313, 2000, ["Literary Fiction", "Mystery"],
   "public"},
  {1046, "9780679735878", "An Artist of the Floating World", 105, 206, 1986,
   ["Literary Fiction", "Fiction"], "public"},
  {1047, "9780571283644", "A Pale View of Hills", 105, 183, 1982, ["Literary Fiction", "Fiction"],
   "public"},
  {1048, "9780571283668", "The Unconsoled", 105, 535, 1995, ["Literary Fiction", "Fiction"],
   "public"},
  {1049, "9780571311569", "Nocturnes", 105, 221, 2009, ["Literary Fiction", "Fiction"], "public"},
  {1050, "9780571364879", "Klara and the Sun (PB)", 105, 303, 2021,
   ["Science Fiction", "Literary Fiction"], "public"},

  # ── Borges (106) ──
  {1051, "9780802130303", "Labyrinths", 106, 240, 1962, ["Fiction", "Magic Realism"], "public"},
  {1052, "9780142437889", "Collected Fictions", 106, 565, 1998, ["Fiction", "Magic Realism"],
   "public"},
  {1053, "9780811216999", "The Book of Sand", 106, 125, 1975, ["Fiction", "Magic Realism"],
   "public"},
  {1054, "9780525567110", "The Library of Babel", 106, 112, 1941, ["Fiction", "Philosophy"],
   "public"},
  {1055, "9780811218078", "A Universal History of Iniquity", 106, 160, 1935,
   ["Fiction", "Magic Realism"], "public"},
  {1056, "9780811217644", "The Aleph and Other Stories", 106, 224, 1949,
   ["Fiction", "Magic Realism"], "public"},
  {1057, "9780141184845", "Fictions", 106, 178, 1944, ["Fiction", "Magic Realism"], "public"},
  {1058, "9780811214643", "Dreamtigers", 106, 95, 1960, ["Fiction", "Poetry"], "public"},
  {1059, "9780811214254", "Other Inquisitions", 106, 205, 1952, ["Non-Fiction", "Philosophy"],
   "public"},
  {1060, "9780811217477", "Selected Non-Fictions", 106, 576, 1999, ["Non-Fiction", "Philosophy"],
   "public"},

  # ── Dostoevsky (107) ──
  {1061, "9780140449136", "Crime and Punishment", 107, 671, 1866, ["Literary Fiction", "Classic"],
   "public"},
  {1062, "9780140449228", "The Idiot", 107, 656, 1869, ["Literary Fiction", "Classic"], "public"},
  {1063, "9780140449242", "Demons", 107, 733, 1872, ["Literary Fiction", "Classic"], "age_gated"},
  {1064, "9780486454115", "Notes from Underground", 107, 96, 1864,
   ["Literary Fiction", "Classic"], "public"},
  {1065, "9780374528379", "The Brothers Karamazov", 107, 796, 1880,
   ["Literary Fiction", "Classic"], "public"},
  {1066, "9780140449266", "The Gambler", 107, 208, 1867, ["Literary Fiction", "Classic"],
   "public"},
  {1067, "9780140443882", "The House of the Dead", 107, 304, 1862,
   ["Literary Fiction", "Classic"], "public"},
  {1068, "9780140444551", "Humiliated and Insulted", 107, 384, 1861,
   ["Literary Fiction", "Classic"], "public"},
  {1069, "9780679734505", "Crime and Punishment (Vintage)", 107, 671, 1866,
   ["Literary Fiction", "Classic"], "public"},
  {1070, "9780199536368", "The Adolescent", 107, 587, 1875, ["Literary Fiction", "Classic"],
   "public"},

  # ── Virginia Woolf (108) ──
  {1071, "9780156030472", "Mrs Dalloway", 108, 194, 1925, ["Literary Fiction", "Classic"],
   "public"},
  {1072, "9780156907392", "To the Lighthouse", 108, 209, 1927, ["Literary Fiction", "Classic"],
   "public"},
  {1073, "9780156628709", "Orlando", 108, 333, 1928, ["Literary Fiction", "Classic"], "public"},
  {1074, "9780156949606", "The Waves", 108, 297, 1931, ["Literary Fiction", "Classic"], "public"},
  {1075, "9780199536610", "To the Lighthouse (Oxford)", 108, 209, 1927,
   ["Literary Fiction", "Classic"], "public"},
  {1076, "9780156030358", "A Room of One's Own", 108, 112, 1929, ["Non-Fiction", "Classic"],
   "public"},
  {1077, "9780156907279", "Jacob's Room", 108, 176, 1922, ["Literary Fiction", "Classic"],
   "public"},
  {1078, "9780156034722", "Between the Acts", 108, 219, 1941, ["Literary Fiction", "Classic"],
   "public"},
  {1079, "9780156949705", "The Years", 108, 435, 1937, ["Literary Fiction", "Classic"], "public"},
  {1080, "9780156031493", "Flush", 108, 188, 1933, ["Fiction", "Classic"], "public"},

  # ── Garcia Marquez (109) ──
  {1081, "9780060883287", "One Hundred Years of Solitude", 109, 417, 1967,
   ["Magic Realism", "Fiction"], "public"},
  {1082, "9780060531041", "Love in the Time of Cholera", 109, 368, 1985,
   ["Magic Realism", "Romance"], "public"},
  {1083, "9780060932589", "Chronicle of a Death Foretold", 109, 122, 1981,
   ["Magic Realism", "Fiction"], "public"},
  {1084, "9780060114183", "The Autumn of the Patriarch", 109, 269, 1975,
   ["Magic Realism", "Fiction"], "public"},
  {1085, "9780060919726", "The General in His Labyrinth", 109, 285, 1989,
   ["Historical Fiction", "Fiction"], "public"},
  {1086, "9780060932664", "Leaf Storm", 109, 146, 1955, ["Magic Realism", "Fiction"], "public"},
  {1087, "9780060924829", "No One Writes to the Colonel", 109, 170, 1961,
   ["Literary Fiction", "Fiction"], "public"},
  {1088, "9780060751166", "Living to Tell the Tale", 109, 483, 2002, ["Memoir", "Non-Fiction"],
   "public"},
  {1089, "9780307389732", "Memories of My Melancholy Whores", 109, 115, 2004,
   ["Fiction", "Romance"], "age_gated"},
  {1090, "9780060153465", "Collected Stories", 109, 311, 1984, ["Magic Realism", "Fiction"],
   "public"},

  # ── Toni Morrison (110) ──
  {1091, "9781400033416", "Beloved", 110, 324, 1987, ["Literary Fiction", "Classic"], "public"},
  {1092, "9781400078653", "Song of Solomon", 110, 337, 1977, ["Literary Fiction", "Classic"],
   "public"},
  {1093, "9780452282193", "The Bluest Eye", 110, 215, 1970, ["Literary Fiction", "Classic"],
   "age_gated"},
  {1094, "9781400033430", "Sula", 110, 174, 1973, ["Literary Fiction", "Classic"], "public"},
  {1095, "9780679745204", "Jazz", 110, 229, 1992, ["Literary Fiction", "Classic"], "public"},
  {1096, "9780679775474", "Paradise", 110, 318, 1997, ["Literary Fiction", "Classic"], "public"},
  {1097, "9780307264169", "A Mercy", 110, 167, 2008, ["Historical Fiction", "Fiction"], "public"},
  {1098, "9780307594167", "Home", 110, 147, 2012, ["Literary Fiction", "Fiction"], "public"},
  {1099, "9780307740922", "God Help the Child", 110, 178, 2015, ["Literary Fiction", "Fiction"],
   "public"},
  {1100, "9781400032747", "Tar Baby", 110, 306, 1981, ["Literary Fiction", "Classic"], "public"},

  # ── Murakami (111) ──
  {1101, "9780375718946", "Kafka on the Shore", 111, 467, 2002, ["Fiction", "Magic Realism"],
   "public"},
  {1102, "9780679775430", "The Wind-Up Bird Chronicle", 111, 607, 1994,
   ["Fiction", "Magic Realism"], "public"},
  {1103, "9780375414596", "Norwegian Wood", 111, 296, 1987, ["Fiction", "Romance"], "public"},
  {1104, "9780099448792", "1Q84", 111, 925, 2009, ["Fiction", "Science Fiction"], "public"},
  {1105, "9780375719462", "Sputnik Sweetheart", 111, 210, 1999, ["Fiction", "Romance"], "public"},
  {1106, "9780679776109", "South of the Border, West of the Sun", 111, 213, 1992,
   ["Fiction", "Romance"], "public"},
  {1107, "9780375726507", "After Dark", 111, 191, 2004, ["Fiction", "Mystery"], "public"},
  {1108, "9780099458326", "What I Talk About When I Talk About Running", 111, 180, 2007,
   ["Memoir", "Non-Fiction"], "public"},
  {1109, "9780375413056", "Dance Dance Dance", 111, 393, 1988, ["Fiction", "Magic Realism"],
   "public"},
  {1110, "9780307762672", "Colorless Tsukuru Tazaki", 111, 298, 2013,
   ["Fiction", "Literary Fiction"], "public"},

  # ── Octavia E. Butler (112) ──
  {1111, "9780807083697", "Kindred", 112, 264, 1979, ["Science Fiction", "Fiction"], "public"},
  {1112, "9781538751480", "Parable of the Sower", 112, 345, 1993, ["Science Fiction", "Dystopia"],
   "public"},
  {1113, "9780446676977", "Parable of the Talents", 112, 365, 1998,
   ["Science Fiction", "Dystopia"], "public"},
  {1114, "9780446603775", "Wild Seed", 112, 320, 1980, ["Science Fiction", "Afrofuturism"],
   "public"},
  {1115, "9780446603782", "Mind of My Mind", 112, 224, 1977, ["Science Fiction", "Afrofuturism"],
   "public"},
  {1116, "9780446606721", "Clay's Ark", 112, 201, 1984, ["Science Fiction", "Horror"],
   "age_gated"},
  {1117, "9780446611972", "Dawn", 112, 248, 1987, ["Science Fiction", "Afrofuturism"], "public"},
  {1118, "9780446603768", "Adulthood Rites", 112, 277, 1988, ["Science Fiction", "Afrofuturism"],
   "public"},
  {1119, "9780446603799", "Imago", 112, 264, 1989, ["Science Fiction", "Afrofuturism"], "public"},
  {1120, "9781583226988", "Fledgling", 112, 310, 2005, ["Science Fiction", "Horror"],
   "age_gated"},

  # ── Kundera (113) ──
  {1121, "9780060932145", "The Unbearable Lightness of Being", 113, 314, 1984,
   ["Literary Fiction", "Philosophy"], "public"},
  {1122, "9780060932190", "The Book of Laughter and Forgetting", 113, 298, 1979,
   ["Literary Fiction", "Fiction"], "public"},
  {1123, "9780060845520", "The Joke", 113, 317, 1967, ["Literary Fiction", "Fiction"], "public"},
  {1124, "9780060997014", "Immortality", 113, 345, 1988, ["Literary Fiction", "Philosophy"],
   "public"},
  {1125, "9780060928414", "The Art of the Novel", 113, 165, 1986,
   ["Non-Fiction", "Literary Fiction"], "public"},
  {1126, "9780060997021", "Life Is Elsewhere", 113, 288, 1973, ["Literary Fiction", "Fiction"],
   "public"},
  {1127, "9780060932169", "Laughable Loves", 113, 242, 1969, ["Literary Fiction", "Fiction"],
   "public"},
  {1128, "9780060997007", "Slowness", 113, 156, 1995, ["Literary Fiction", "Fiction"], "public"},
  {1129, "9780060841805", "Identity", 113, 153, 1998, ["Literary Fiction", "Fiction"], "public"},
  {1130, "9780061992100", "Ignorance", 113, 176, 2000, ["Literary Fiction", "Fiction"], "public"},

  # ── Calvino (114) ──
  {1131, "9780156453806", "If on a winter's night a traveler", 114, 260, 1979,
   ["Literary Fiction", "Fiction"], "public"},
  {1132, "9780156457101", "Invisible Cities", 114, 165, 1972, ["Literary Fiction", "Fiction"],
   "public"},
  {1133, "9780544340862", "The Complete Cosmicomics", 114, 416, 1965,
   ["Science Fiction", "Fiction"], "public"},
  {1134, "9780156047593", "The Baron in the Trees", 114, 217, 1957, ["Fiction", "Fantasy"],
   "public"},
  {1135, "9780156030328", "Mr Palomar", 114, 130, 1983, ["Literary Fiction", "Fiction"],
   "public"},
  {1136, "9780156046503", "Italian Folktales", 114, 763, 1956, ["Fiction", "Fantasy"], "public"},
  {1137, "9780156027717", "The Nonexistent Knight", 114, 152, 1959, ["Fiction", "Fantasy"],
   "public"},
  {1138, "9780156014403", "Difficult Loves", 114, 282, 1970, ["Literary Fiction", "Fiction"],
   "public"},
  {1139, "9780547222776", "Six Memos for the Next Millennium", 114, 124, 1988,
   ["Non-Fiction", "Literary Fiction"], "public"},
  {1140, "9780156029872", "The Path to the Spiders' Nests", 114, 189, 1947,
   ["Literary Fiction", "Historical Fiction"], "public"},

  # ── Margaret Atwood (115) ──
  {1141, "9780385490818", "The Handmaid's Tale", 115, 311, 1985, ["Dystopia", "Fiction"],
   "public"},
  {1142, "9780385543781", "The Testaments", 115, 419, 2019, ["Dystopia", "Fiction"], "public"},
  {1143, "9780771008795", "Alias Grace", 115, 468, 1996, ["Historical Fiction", "Mystery"],
   "public"},
  {1144, "9780385539104", "The Heart Goes Last", 115, 308, 2015, ["Science Fiction", "Fiction"],
   "public"},
  {1145, "9780385490832", "Cat's Eye", 115, 462, 1988, ["Literary Fiction", "Fiction"], "public"},
  {1146, "9780385503853", "Oryx and Crake", 115, 374, 2003, ["Science Fiction", "Dystopia"],
   "public"},
  {1147, "9780307400840", "The Year of the Flood", 115, 434, 2009,
   ["Science Fiction", "Dystopia"], "public"},
  {1148, "9780385528788", "MaddAddam", 115, 394, 2013, ["Science Fiction", "Dystopia"], "public"},
  {1149, "9780771008801", "The Blind Assassin", 115, 521, 2000, ["Literary Fiction", "Fiction"],
   "public"},
  {1150, "9780385541350", "Hag-Seed", 115, 293, 2016, ["Fiction", "Literary Fiction"], "public"},

  # ── Ray Bradbury (116) ──
  {1151, "9781451673319", "Fahrenheit 451", 116, 194, 1953, ["Science Fiction", "Dystopia"],
   "public"},
  {1152, "9780380977260", "The Martian Chronicles", 116, 222, 1950,
   ["Science Fiction", "Fiction"], "public"},
  {1153, "9780380729401", "Something Wicked This Way Comes", 116, 293, 1962,
   ["Horror", "Fantasy"], "public"},
  {1154, "9780380789665", "The Illustrated Man", 116, 275, 1951, ["Science Fiction", "Fiction"],
   "public"},
  {1155, "9780380973712", "Dandelion Wine", 116, 267, 1957, ["Fiction", "Classic"], "public"},
  {1156, "9780060594534", "Zen in the Art of Writing", 116, 176, 1990, ["Non-Fiction", "Memoir"],
   "public"},
  {1157, "9780345342966", "I Sing the Body Electric!", 116, 305, 1969,
   ["Science Fiction", "Fiction"], "public"},
  {1158, "9780345342027", "The October Country", 116, 276, 1955, ["Horror", "Fiction"],
   "age_gated"},
  {1159, "9780380729425", "A Medicine for Melancholy", 116, 240, 1959,
   ["Science Fiction", "Fiction"], "public"},
  {1160, "9780380730391", "R is for Rocket", 116, 233, 1962, ["Science Fiction", "Fiction"],
   "public"},

  # ── Chimamanda Ngozi Adichie (117) ──
  {1161, "9780307455925", "Americanah", 117, 477, 2013, ["Literary Fiction", "Fiction"],
   "public"},
  {1162, "9781400095209", "Half of a Yellow Sun", 117, 541, 2006,
   ["Historical Fiction", "Fiction"], "public"},
  {1163, "9780865478053", "We Should All Be Feminists", 117, 64, 2014,
   ["Non-Fiction", "Political Science"], "public"},
  {1164, "9780307271082", "Purple Hibiscus", 117, 307, 2003, ["Literary Fiction", "Fiction"],
   "public"},
  {1165, "9780525657606", "Notes on Grief", 117, 80, 2021, ["Memoir", "Non-Fiction"], "public"},
  {1166, "9781400044016", "Half of a Yellow Sun (HB)", 117, 541, 2006,
   ["Historical Fiction", "Fiction"], "public"},
  {1167, "9780007232161", "Purple Hibiscus (4th Est)", 117, 307, 2003,
   ["Literary Fiction", "Fiction"], "public"},
  {1168, "9780008306045", "Dear Ijeawele", 117, 80, 2017, ["Non-Fiction", "Political Science"],
   "public"},
  {1169, "9781616202415", "The Thing Around Your Neck", 117, 218, 2009,
   ["Literary Fiction", "Fiction"], "public"},
  {1170, "9780307455932", "Americanah (PB)", 117, 477, 2013, ["Literary Fiction", "Fiction"],
   "public"},

  # ── Carlos Ruiz Zafon (118) ──
  {1171, "9780143034902", "The Shadow of the Wind", 118, 487, 2001, ["Gothic", "Mystery"],
   "public"},
  {1172, "9780062199546", "The Prisoner of Heaven", 118, 281, 2011, ["Gothic", "Mystery"],
   "public"},
  {1173, "9780061284649", "The Angel's Game", 118, 531, 2008, ["Gothic", "Mystery"], "public"},
  {1174, "9780062668691", "The Labyrinth of the Spirits", 118, 821, 2016, ["Gothic", "Mystery"],
   "public"},
  {1175, "9780316044776", "Marina", 118, 311, 1999, ["Gothic", "Fiction"], "public"},
  {1176, "9780316044783", "The Prince of Mist", 118, 198, 1993, ["Gothic", "Fantasy"], "public"},
  {1177, "9780316044790", "The Midnight Palace", 118, 284, 1994, ["Gothic", "Fantasy"], "public"},
  {1178, "9780316044769", "The Watcher in the Shadows", 118, 278, 1995, ["Gothic", "Mystery"],
   "public"},
  {1179, "9780143126393", "The Shadow of the Wind (PB)", 118, 487, 2001, ["Gothic", "Mystery"],
   "public"},
  {1180, "9780062668684", "The Labyrinth of the Spirits (HB)", 118, 821, 2016,
   ["Gothic", "Mystery"], "public"},

  # ── Madeline Miller (119) ──
  {1181, "9780316556347", "Circe", 119, 393, 2018, ["Fantasy", "Mythology"], "public"},
  {1182, "9780062060624", "The Song of Achilles", 119, 369, 2011, ["Fantasy", "Mythology"],
   "public"},
  {1183, "9780316388672", "Circe (PB)", 119, 393, 2018, ["Fantasy", "Mythology"], "public"},
  {1184, "9780062060617", "The Song of Achilles (HB)", 119, 369, 2011, ["Fantasy", "Mythology"],
   "public"},
  {1185, "9780062356031", "The Song of Achilles (Reissue)", 119, 369, 2012,
   ["Fantasy", "Mythology"], "public"},
  {1186, "9780316556323", "Circe (HB)", 119, 393, 2018, ["Fantasy", "Mythology"], "public"},
  {1187, "9781526610140", "Circe (Bloomsbury)", 119, 393, 2018, ["Fantasy", "Mythology"],
   "public"},
  {1188, "9781408891384", "The Song of Achilles (UK)", 119, 369, 2012, ["Fantasy", "Mythology"],
   "public"},
  {1189, "9780316334754", "Circe (Trade PB)", 119, 393, 2018, ["Fantasy", "Mythology"], "public"},
  {1190, "9780316556330", "Circe (LP)", 119, 393, 2018, ["Fantasy", "Mythology"], "public"},

  # ── Patrick Rothfuss (120) ──
  {1191, "9780756404741", "The Name of the Wind", 120, 662, 2007, ["Fantasy", "Fiction"],
   "public"},
  {1192, "9780756407919", "The Wise Man's Fear", 120, 994, 2011, ["Fantasy", "Fiction"],
   "public"},
  {1193, "9780756405892", "The Name of the Wind (PB)", 120, 662, 2007, ["Fantasy", "Fiction"],
   "public"},
  {1194, "9780756407124", "The Name of the Wind (Mass)", 120, 662, 2008, ["Fantasy", "Fiction"],
   "public"},
  {1195, "9780756407896", "The Wise Man's Fear (HB)", 120, 994, 2011, ["Fantasy", "Fiction"],
   "public"},
  {1196, "9780575081406", "The Name of the Wind (UK)", 120, 662, 2007, ["Fantasy", "Fiction"],
   "public"},
  {1197, "9780756404079", "The Name of the Wind (1st)", 120, 662, 2007, ["Fantasy", "Fiction"],
   "public"},
  {1198, "9780756404468", "The Name of the Wind (Anniv)", 120, 662, 2007, ["Fantasy", "Fiction"],
   "public"},
  {1199, "9780575108431", "The Wise Man's Fear (UK)", 120, 994, 2011, ["Fantasy", "Fiction"],
   "public"},
  {1200, "9780756409142", "The Slow Regard of Silent Things", 120, 159, 2014,
   ["Fantasy", "Fiction"], "public"}
]

# ── Group editions into works ─────────────────────────────────────────────
# Group by canonical title + author to consolidate editions of the same work.
# The first edition in each group is the primary; the rest are secondary.
# Works get the UUID of the first (primary) edition's index.

work_groups =
  books_data
  |> Enum.group_by(fn {_idx, _isbn, title, author_idx, _pages, _year, _subj, _vis} ->
    {Seeds.canonical_title(title), author_idx}
  end)

# Build a mapping from each edition's index to its parent work index.
# The work index = the first edition's index in the group.
{work_rows, edition_rows, edition_to_work_map} =
  Enum.reduce(work_groups, {[], [], %{}}, fn {_key, editions},
                                             {works_acc, editions_acc, map_acc} ->
    [{primary_idx, _isbn, _title, author_idx, _pages, _year, subjects, vis} | _rest] = editions

    canonical = Seeds.canonical_title(elem(Enum.at(editions, 0), 2))

    work = %{
      id: Seeds.uuid(primary_idx),
      title: canonical,
      author_id: Seeds.uuid(author_idx),
      language: "en",
      subjects: subjects,
      visibility_tier: vis,
      created_at: jan_01,
      updated_at: jan_01
    }

    {new_editions, new_map} =
      Enum.with_index(editions, fn {idx, isbn, title, _author, pages, year, _subj, _vis}, i ->
        is_primary = i == 0

        format_label =
          case Regex.run(~r/\(([^)]+)\)\s*$/, title) do
            [_, label] -> label
            _ -> if is_primary, do: nil, else: "Edition #{i + 1}"
          end

        edition = %{
          id: Seeds.uuid(3000 + idx),
          book_id: Seeds.uuid(primary_idx),
          isbn: isbn,
          format_label: format_label,
          page_count: pages,
          publication_year: year,
          is_primary: is_primary,
          created_at: jan_01,
          updated_at: jan_01
        }

        {{edition, {idx, primary_idx}}, nil}
      end)
      |> Enum.unzip()

    edition_structs = Enum.map(new_editions, fn {ed, _} -> ed end)
    idx_mappings = Enum.map(new_editions, fn {_, mapping} -> mapping end)
    new_map_entries = Map.new(idx_mappings, fn {ed_idx, work_idx} -> {ed_idx, work_idx} end)

    {[work | works_acc], editions_acc ++ edition_structs, Map.merge(map_acc, new_map_entries)}
  end)

Repo.insert_all("books", work_rows, prefix: "op", on_conflict: :nothing)
Repo.insert_all("book_editions", edition_rows, prefix: "op", on_conflict: :nothing)

# ── Bookshelves ─────────────────────────────────────────────────────────────

bookshelf_names = ["antilibrary", "library", "wishlist", "reading_pile", "looking_for_home"]

bookshelf_rows =
  Enum.flat_map([{1, 301}, {2, 306}], fn {user_n, start_idx} ->
    Enum.with_index(bookshelf_names, fn name, i ->
      %{
        id: Seeds.uuid(start_idx + i),
        user_id: Seeds.uuid(user_n),
        name: name,
        visibility: "owner",
        created_at: jan_01,
        updated_at: jan_01
      }
    end)
  end)

Repo.insert_all("bookshelves", bookshelf_rows, prefix: "op", on_conflict: :nothing)

# ── E2E user bookshelves ──────────────────────────────────────────────────
# Each E2E user gets 5 bookshelves. UUID range: 400+ (5 per user, starting at user index * 10).

e2e_bookshelf_rows =
  Enum.flat_map(Seeds.e2e_suites(), fn {user_idx, _slug, _display} ->
    shelf_base = 400 + (user_idx - 10) * 10

    Enum.with_index(bookshelf_names, fn name, i ->
      %{
        id: Seeds.uuid(shelf_base + i),
        user_id: Seeds.uuid(user_idx),
        name: name,
        visibility: "owner",
        created_at: jan_01,
        updated_at: jan_01
      }
    end)
  end)

Repo.insert_all("bookshelves", e2e_bookshelf_rows, prefix: "op", on_conflict: :nothing)

# ── E2E user placements ──────────────────────────────────────────────────
# Each E2E user gets 5 books on library, 3 on antilibrary, 2 on reading_pile.
# Uses works from the seed data. Placement UUID range: 5000+.

# Collect all work IDs from the edition_to_work_map (unique work indices)
all_work_indices = edition_to_work_map |> Map.values() |> Enum.uniq() |> Enum.sort()

e2e_placement_rows =
  Enum.flat_map(Seeds.e2e_suites(), fn {user_idx, _slug, _display} ->
    shelf_base = 400 + (user_idx - 10) * 10
    place_base = 5000 + (user_idx - 10) * 20
    # Each user gets a different slice of works so they don't collide
    offset = (user_idx - 10) * 10
    user_works = Enum.slice(all_work_indices, offset, 10)

    library_works = Enum.take(user_works, 5)
    antilibrary_works = Enum.slice(user_works, 5, 3)
    reading_pile_works = Enum.slice(user_works, 8, 2)

    library_shelf = Seeds.uuid(shelf_base + 1)
    antilibrary_shelf = Seeds.uuid(shelf_base)
    reading_pile_shelf = Seeds.uuid(shelf_base + 3)

    library_placements =
      Enum.with_index(library_works, fn work_idx, i ->
        %{
          id: Seeds.uuid(place_base + i),
          book_id: Seeds.uuid(work_idx),
          bookshelf_id: library_shelf,
          position: i + 1,
          placed_at: jan_10,
          formats: ["paperback"],
          visibility: "owner",
          created_at: jan_10,
          updated_at: jan_10
        }
      end)

    antilibrary_placements =
      Enum.with_index(antilibrary_works, fn work_idx, i ->
        %{
          id: Seeds.uuid(place_base + 10 + i),
          book_id: Seeds.uuid(work_idx),
          bookshelf_id: antilibrary_shelf,
          position: i + 1,
          placed_at: jan_15,
          formats: ["paperback"],
          visibility: "owner",
          created_at: jan_15,
          updated_at: jan_15
        }
      end)

    reading_pile_placements =
      Enum.with_index(reading_pile_works, fn work_idx, i ->
        %{
          id: Seeds.uuid(place_base + 15 + i),
          book_id: Seeds.uuid(work_idx),
          bookshelf_id: reading_pile_shelf,
          position: i + 1,
          placed_at: mar_01,
          formats: ["paperback"],
          visibility: "owner",
          created_at: mar_01,
          updated_at: mar_01
        }
      end)

    library_placements ++ antilibrary_placements ++ reading_pile_placements
  end)

Repo.insert_all("bookshelf_placements", e2e_placement_rows,
  prefix: "op",
  on_conflict: :nothing
)

# ── Placements ──────────────────────────────────────────────────────────────

# User 1 placement groups: {shelf_uuid_idx, book_range, placed_at, label}
placement_groups = [
  {302, 0..19, jan_10, "library"},
  {301, 20..59, jan_15, "antilibrary"},
  {303, 60..69, feb_01, "wishlist"},
  {304, 70..74, mar_01, "reading_pile"},
  {305, 75..76, jan_20, "looking_for_home"}
]

# Track placement UUID counter
{user1_placements, next_place_idx} =
  Enum.flat_map_reduce(placement_groups, 2001, fn {shelf_idx, range, placed_at, label},
                                                  place_idx ->
    books_slice = Enum.slice(books_data, range)

    {placements, new_idx} =
      Enum.map_reduce(books_slice, place_idx, fn {book_idx, _isbn, _title, _author, _pages, _year,
                                                  _subj, _vis},
                                                 idx ->
        position = idx - place_idx + 1

        # Map edition index to its parent work index
        work_idx = Map.get(edition_to_work_map, book_idx, book_idx)

        base = %{
          id: Seeds.uuid(idx),
          book_id: Seeds.uuid(work_idx),
          bookshelf_id: Seeds.uuid(shelf_idx),
          position: position,
          placed_at: placed_at,
          visibility: "owner",
          created_at: placed_at,
          updated_at: placed_at
        }

        row =
          case label do
            "library" ->
              format =
                case rem(position, 3) do
                  0 -> ["ebook"]
                  1 -> ["paperback"]
                  2 -> ["hardcover"]
                end

              rating = if rem(position, 4) == 0, do: rem(position, 5) + 1, else: nil
              notes = if rem(position, 5) == 0, do: "Re-read candidate", else: nil

              Map.merge(base, %{formats: format, personal_rating: rating, notes: notes})

            "antilibrary" ->
              Map.merge(base, %{formats: ["paperback"]})

            "wishlist" ->
              Map.merge(base, %{formats: []})

            "reading_pile" ->
              Map.merge(base, %{formats: ["paperback"]})

            "looking_for_home" ->
              cond do
                position == 1 ->
                  Map.merge(base, %{
                    formats: ["paperback"],
                    listing_mode: "open_bid"
                  })

                position == 2 ->
                  Map.merge(base, %{
                    formats: ["paperback"],
                    listing_mode: "closed_bid",
                    listing_price_cents: 1500
                  })

                true ->
                  Map.merge(base, %{formats: ["paperback"]})
              end
          end

        {row, idx + 1}
      end)

    {placements, new_idx}
  end)

# User 2 placements: 3 on library (shelf 307), 1 on antilibrary (shelf 306)
user2_placements =
  Enum.with_index(Enum.slice(books_data, 0..2), fn {book_idx, _, _, _, _, _, _, _}, i ->
    work_idx = Map.get(edition_to_work_map, book_idx, book_idx)

    %{
      id: Seeds.uuid(next_place_idx + i),
      book_id: Seeds.uuid(work_idx),
      bookshelf_id: Seeds.uuid(307),
      position: i + 1,
      placed_at: jan_05,
      formats: ["paperback"],
      visibility: "owner",
      created_at: jan_05,
      updated_at: jan_05
    }
  end) ++
    [
      %{
        id: Seeds.uuid(next_place_idx + 3),
        book_id:
          Seeds.uuid(
            Map.get(
              edition_to_work_map,
              elem(Enum.at(books_data, 3), 0),
              elem(Enum.at(books_data, 3), 0)
            )
          ),
        bookshelf_id: Seeds.uuid(306),
        position: 1,
        placed_at: jan_05,
        formats: ["paperback"],
        visibility: "owner",
        created_at: jan_05,
        updated_at: jan_05
      }
    ]

all_placements = user1_placements ++ user2_placements

Repo.insert_all("bookshelf_placements", all_placements, prefix: "op", on_conflict: :nothing)

# ── Placement History ───────────────────────────────────────────────────────

Repo.insert_all(
  "bookshelf_placement_history",
  [
    %{
      id: Seeds.uuid(501),
      book_id: Seeds.uuid(Map.get(edition_to_work_map, 1001, 1001)),
      from_bookshelf: Seeds.uuid(301),
      to_bookshelf: Seeds.uuid(302),
      moved_at: jan_10
    },
    %{
      id: Seeds.uuid(502),
      book_id: Seeds.uuid(Map.get(edition_to_work_map, 1042, 1042)),
      from_bookshelf: Seeds.uuid(303),
      to_bookshelf: Seeds.uuid(302),
      moved_at: jan_15
    },
    %{
      id: Seeds.uuid(503),
      book_id: Seeds.uuid(Map.get(edition_to_work_map, 1071, 1071)),
      from_bookshelf: Seeds.uuid(302),
      to_bookshelf: Seeds.uuid(304),
      moved_at: mar_01
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

# ── Uploaded Image ──────────────────────────────────────────────────────────

Repo.insert_all(
  "uploaded_images",
  [
    %{
      id: Seeds.uuid(601),
      book_id: Seeds.uuid(Map.get(edition_to_work_map, 1001, 1001)),
      storage_path: nil,
      status: "resolved",
      uploaded_at: jan_15,
      expires_at: feb_14,
      created_at: jan_15,
      updated_at: jan_15
    }
  ],
  prefix: "op",
  on_conflict: :nothing
)

# ── Audit Log ───────────────────────────────────────────────────────────────

Repo.insert_all(
  "audit_log",
  [
    %{
      id: Seeds.uuid(701),
      user_id: Seeds.uuid(1),
      action: "user.registered",
      resource_type: "user",
      resource_id: Seeds.uuid(1),
      metadata: nil,
      occurred_at: jan_01
    }
  ],
  prefix: "audit",
  on_conflict: :nothing
)

IO.puts("Seeds loaded successfully.")
