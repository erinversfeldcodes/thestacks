# Legally-obtainable book-cover and related training imagery (as of November 2026)

Scope note: this covers licence posture on **pixels**, not metadata. Every entry states explicitly
whether the images themselves are licensed. Where a source's terms are unstated, mutable, or
unilaterally revocable, that is flagged — the project has already rejected Meta's DINOv3 on exactly
that basis, and the same bar is applied here.

Verification caveat applied throughout: several primary terms pages are JavaScript-rendered or
behind redirects and could not be retrieved directly. Those are marked as second-hand and should be
re-read before anything is relied on.

---

## Q1. Open Library / Internet Archive covers API — licence on the COVER IMAGES specifically

### Takeaway
Open Library publishes **no licence at all** for the cover images. The CC0 grant that Open Library is
known for covers its bibliographic **metadata dumps**, not the cover pixels; the covers are
community uploads of publisher artwork, hosted by an organisation that explicitly disclaims any
guarantee of their copyright status. Bulk download via archive.org tar files is explicitly offered,
but "available in bulk" is a distribution fact, not a licence grant. **The pixels are unlicensed.**

### Cited Findings
- The Covers API documentation contains no licence or copyright statement for the images; it
  describes them only as "available in the Open Library Covers Repository" —
  [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers)
- Open Library's own description of provenance: "all covers and author images are contributed by the
  Open Library community" through "an easy to use interface", and "images can be uploaded at any
  resolution" — [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers) (retrieved via
  search summary of the same page; the direct fetch of the page returned only the "Covers Repository"
  phrasing, so treat the exact wording as second-hand)
- Rate limit, verbatim: "The cover access by ids other than CoverID and OLID are rate-limited" and
  "Currently only 100 requests/IP are allowed for every 5 minutes." Exceeding it returns HTTP 403 —
  [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers)
- Crawling, verbatim: "The covers API is intended for displaying covers on public facing websites and
  not for bulk download." / "Please, do not crawl our cover API." / "If you do, we may decide to
  block your crawl." — [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers)
- Bulk access IS offered, but off-API via archive.org items. Verbatim: "Each of these archive.org
  items have 100 tar files, each containing 10K images in each." Items listed on the API page:
  `s_covers_0000`–`s_covers_0006` (small), `m_covers_0000`–`m_covers_0006` (medium),
  `l_covers_0000`–`l_covers_0006` (large), `covers_0000`–`covers_0005` (original) —
  [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers)
- The developer dumps page gives a **different and larger** item range: "Most covers are in
  archive.org items `covers_0000` through `covers_0014`", with `covers_0006` and `covers_0007`
  "presently unavailable" — [Open Library data dumps](https://openlibrary.org/developers/dumps)
- The dumps page also states: "We do not yet have rolling monthly dumps of our book covers, despite a
  shared desire for their existence." — [Open Library data dumps](https://openlibrary.org/developers/dumps)
- The dumps page states no licence for the dumps themselves on the retrieved content; it links out to
  the archive.org Terms of Service rather than asserting a licence over covers —
  [Open Library data dumps](https://openlibrary.org/developers/dumps)
- Scale signal: the archive.org item `covers_0005` is listed at roughly 765 GB —
  [archive.org covers_0005](https://archive.org/details/covers_0005)
- Attribution is requested, not required: "A courtesy link back to Open Library is appreciated." —
  [Open Library Covers API](https://openlibrary.org/dev/docs/api/covers)
- Internet Archive (the host and sponsor) disclaims copyright status: the Archive "does not make
  guarantees as to the copyright status of items on archive.org and cannot guarantee information
  posted on item details or collection pages regarding copyright or other intellectual property
  rights"; its Terms "require that users make use of the Internet Archive's Collections at their own
  risk and ensure that such use is non-infringing and in accordance with all applicable laws" —
  [Internet Archive rights help page](https://help.archive.org/help/rights/)
- An Internet Archive blog post on the Terms of Use states that users certify their use "will be
  noncommercial and limited to noninfringing or fair use" —
  [IA blog: Update to Terms of Use](https://blog.archive.org/2014/12/30/update-to-terms-of-use/)
  (second-hand via search summary; the live Terms page could not be fetched — see Gaps)
- Some covers shown on Open Library are served from Internet Archive's own cover service rather than
  Open Library's repository, i.e. provenance is not uniform —
  [openlibrary issue #9064](https://github.com/internetarchive/openlibrary/issues/9064)

### Inferences
- The CC0 reputation of Open Library is a **metadata** fact that does not transfer to covers. The
  covers are user-contributed reproductions of publisher cover art; the underlying copyright sits
  with the publisher or cover artist and Open Library never acquired it, so it cannot sublicense it.
  This is structurally the same trap as COCO's annotations-vs-images split.
- Item naming (`covers_0000`–`covers_0014`, 10k images per tar, 100 tars per item) implies a cover-ID
  space of roughly 15 million. That is an inference from the naming scheme, not a published count;
  the real number of populated IDs will be lower.
- The two published item ranges (0000–0005 on the API page vs 0000–0014 on the dumps page) conflict;
  the dumps page is the more recently maintained of the two. Neither has a dated changelog.
- Bulk access here is "permitted" only in the weak sense that the files are deliberately published.
  There is no affirmative grant, and the host's own terms push the rights determination onto the
  downloader. For a source-available project that must **name** a licence, this fails the bar.
- A practical, defensible use remains: Open Library covers as a *runtime* lookup for display
  (which is exactly what the API says it is for), and as an *evaluation* corpus held locally and
  never redistributed. Neither is a training-set redistribution grant.

### Gaps
- No published total count of distinct cover images. Not stated on the API page, the dumps page, or
  any Open Library blog post I could retrieve.
- The live archive.org Terms of Use could not be fetched (`archive.org/about/terms.php` returned the
  site title only; `help.archive.org/help/terms-of-use/` returned HTTP 404). The user-responsibility
  and no-warranty language above comes from the Archive's rights help page and a 2014 blog post,
  both of which are Archive-authored but not the Terms themselves.
- Whether Open Library performs any rights check on cover uploads, and what its takedown process is,
  is not documented on any page I retrieved.

---

## Q2. Google Books API cover thumbnails — retention and reuse

### Takeaway
Google Books thumbnails cannot be stored for training. The Books-specific terms are short and defer
to the general Google APIs Terms of Service, which **expressly prohibit** scraping, building
databases, creating permanent copies, creating derivative works, and keeping cached copies longer
than the cache header allows — and require deletion of cached content on termination. Google also
reserves the right to modify the terms unilaterally. This is a hard no for training data, and it
also trips the "mutable terms" criterion the project applied to DINOv3.

### Cited Findings
- The Books API terms themselves are only three clauses — no fee charging, mandatory content removal
  on request, and a privacy notice obligation — and incorporate the general Google APIs Terms of
  Service by reference — [Google Books APIs Terms of Service](https://developers.google.com/books/terms)
- Books API ToS §2, verbatim: "You must remove from your site or application any content provided
  through the Books API" (on request) — [Google Books APIs Terms of Service](https://developers.google.com/books/terms)
- Google APIs ToS §5(e)(1), verbatim prohibitions: "Scrape, build databases, or otherwise create
  permanent copies of such content," and "keep cached copies longer than permitted by the cache
  header;" — [Google APIs Terms of Service](https://developers.google.com/terms)
- Google APIs ToS §5(e)(2), verbatim: "create a derivative work of," —
  [Google APIs Terms of Service](https://developers.google.com/terms)
- Google APIs ToS §8(b), on termination, verbatim: "delete any cached or stored content that was
  permitted by the cache header under Section 5." — [Google APIs Terms of Service](https://developers.google.com/terms)
- Google APIs ToS §10(a), unilateral modification, verbatim: "We may modify the Terms or any portion
  to, for example, reflect changes to the law or changes to our APIs." Changes "will not apply
  retroactively and will become effective no sooner than 30 days after they are posted." —
  [Google APIs Terms of Service](https://developers.google.com/terms)
- Neither document mentions machine learning or model training anywhere —
  [Google APIs Terms of Service](https://developers.google.com/terms)

### Inferences
- "Scrape, build databases, or otherwise create permanent copies" is directly on point: a training
  corpus of downloaded thumbnails is a permanent copy and a database. The absence of an explicit
  ML clause does not help — the general prohibition already covers the act of assembling the set.
- A model whose weights were fit on those thumbnails is arguably "a derivative work of" the content
  under §5(e)(2); that is contested ground generally, but a source-available project cannot ship on
  a contested reading when the collection step is already prohibited outright.
- The 30-day unilateral modification clause is the same category of objection raised against
  DINOv3's unilateral-modification term, with the added problem that Google can also demand removal
  of already-served content under Books ToS §2.
- Permitted use is narrow and runtime-only: fetch a thumbnail, display it, honour the cache header,
  delete it. That is viable for the product's display path and useless for training.

### Gaps
- I did not find a Books-API-specific clause naming thumbnails or cover images, nor a published
  cache-header TTL value for the `imageLinks` thumbnail URLs. The restriction is inherited from the
  general API ToS rather than stated per-resource.
- The Google Books branding/attribution requirements page was not retrieved.

---

## Q3. The pixels-vs-labels licence trap, applied source by source

### Takeaway
The trap is confirmed and near-universal in this space: the published licence attaches to the
annotation layer, which the publisher created and therefore owns, while the pixels remain under
whatever terms the original photographer or publisher imposed. The only sources where the **pixels**
are genuinely licensed are those built from Creative-Commons Flickr photography (Open Images,
YFCC100M, and by inheritance TextOCR and HierText) and a small number of institutional
public-domain releases.

### Cited Findings
- COCO: annotations are CC BY 4.0 and belong to the COCO Consortium; image use "is governed by the
  Flickr Terms of Use" and users take "full responsibility for use of the dataset, including copies
  of copyrighted images" — reported consistently across mirrors of the COCO terms, e.g.
  [HuggingFaceM4/COCO dataset card](https://huggingface.co/datasets/HuggingFaceM4/COCO/blob/main/README.md)
  and [shunk031/MSCOCO card](https://huggingface.co/datasets/shunk031/MSCOCO/raw/main/README.md).
  **Second-hand:** the official `cocodataset.org/#termsofuse` page is JS-rendered and returned only
  navigation on fetch, so the canonical wording was not read directly.
- Open Images splits the two explicitly, verbatim: "The annotations are licensed by Google LLC under
  CC BY 4.0 license." / "The images are listed as having a CC BY 2.0 license." And it disclaims:
  "we make no representations or warranties regarding the license status of each image" and "you
  should verify the license for each image yourself." —
  [Open Images V7 facts and figures](https://storage.googleapis.com/openimages/web/factsfigures_v7.html)
- The uchidalab book-cover dataset (the canonical "Judging a Book by its Cover" set) carries no open
  licence: its README states the cover images are hosted by and copyright Amazon.com, Inc., and
  asserts the use is fair use for academic purposes — a self-assessment, not a grant —
  [uchidalab/book-dataset](https://github.com/uchidalab/book-dataset)
- HierText applies one licence to "the dataset" without separating layers: "The HierText dataset are
  released under CC BY-SA 4.0 license." Its 11,639 images are "selected from the Open Images dataset"
  and hosted by CVDF — [google-research-datasets/hiertext](https://github.com/google-research-datasets/hiertext)
- TextOCR's README states "Data is available under CC BY 4.0 license" and sources images from the
  OpenImages train/test sets; the CVPR 2021 paper separately footnotes that "all images are licensed
  under CC BY 2.0" —
  [TextOCR paper (CVPR 2021)](https://openaccess.thecvf.com/content/CVPR2021/papers/Singh_TextOCR_Towards_Large-Scale_End-to-End_Reasoning_for_Arbitrary-Shaped_Scene_Text_CVPR_2021_paper.pdf);
  [TextOCR dataset card mirror](https://huggingface.co/datasets/yunusserhat/TextOCR-Dataset)
- A second, independent layer of the trap exists for photographs: Wikimedia Commons treats "a
  photograph of a copyrighted item" as "a derivative work in US jurisdiction", and generally refuses
  "Scans or reproductive photographs of copyrighted artwork, especially book covers, album/CD covers,
  etc." — [Commons:Licensing](https://commons.wikimedia.org/wiki/Commons:Licensing)

### Inferences
- There are **two** stacked traps for this specific task, not one. (1) The annotation/pixel split.
  (2) Even when the pixels are properly CC-licensed, a photograph of a bookshelf embeds copyrighted
  cover artwork as a derivative work — the photographer's CC grant cannot reach the publisher's
  copyright in the cover design. Commons' refusal policy is the clearest third-party confirmation
  that this is a real distinction and not an over-reading.
- Consequence: no source can give this project cover **artwork** under an open licence at scale,
  except public-domain artwork. CC sources can give it *books as physical objects in natural
  conditions* — geometry, lighting, occlusion, spine layout, shelf context — which is the
  render-to-photograph gap, not the identity signal.
- HierText's single CC BY-SA 4.0 statement over "the dataset" is ambiguous in exactly the way the
  brief warns about. Since its images come from Open Images (CC BY 2.0, per-image), the safe reading
  is annotations CC BY-SA 4.0, images CC BY 2.0 — not that Google relicensed someone else's photos.
  Also note CC BY-SA on the annotation layer is viral and may be an awkward fit for a
  source-available model release.
- The TextOCR CC BY 4.0 / CC BY 2.0 discrepancy is almost certainly the same split (annotations 4.0,
  inherited images 2.0) rather than a conflict, but it is stated badly enough that it should be
  re-verified against the per-image Open Images metadata before any redistribution.

### Gaps
- Official COCO terms page not read directly.
- ICDAR / Robust Reading Competition dataset licences could not be established. Searches returned
  papers and catalogue entries but no licence text; the terms are behind per-competition registration
  on `rrc.cvc.uab.es` and differ by edition. **Treat ICDAR data as unusable until the registration
  terms are read**, and expect research-only restrictions. I found no evidence either way.
- COCO-Text specifically (an ICDAR-adjacent layer over COCO images) was not separately verified; by
  construction it inherits COCO's image position, i.e. unlicensed pixels.

---

## Q4. Open datasets repurposable for cover recognition

### Takeaway
Nothing exists that is both at-scale book covers and licensed on the pixels. The usable material is
in adjacent shapes: scene-text datasets built on CC BY 2.0 Flickr photography (for the OCR/text
pathway), and a small CC0 book-spine segmentation set (for the shelf/spine pathway).

### Cited Findings
- **Open Images V7** — ~9M images; 9,011,219 train / 41,620 val / 125,436 test. ~16M bounding boxes
  over 600 classes on 1.9M images. Images CC BY 2.0, annotations CC BY 4.0, with Google's explicit
  no-warranty disclaimer —
  [Open Images V7 facts and figures](https://storage.googleapis.com/openimages/web/factsfigures_v7.html);
  box totals via [Roboflow's Open Images overview](https://blog.roboflow.com/open-images-dataset/)
- Open Images has a `Book` class; a LearnOpenCV table for **V4** lists a `Book` row with figures
  41280 / 698 / 2147 (column headers not shown in the retrieved content, so the meaning of each is
  unconfirmed) — [LearnOpenCV Open Images V4 downloader](https://learnopencv.com/fast-image-downloader-for-open-images-v4/).
  Caveat from the same source: "If there are multiple objects of the same class in one image, only
  one has been boxed", so per-class counts understate instances.
- **TextOCR** — 28,134 images drawn from TextVQA/OpenImages; annotations CC BY 4.0; images CC BY 2.0
  by inheritance —
  [TextOCR dataset card mirror](https://huggingface.co/datasets/yunusserhat/TextOCR-Dataset);
  [hyper.ai TextOCR listing](https://hyper.ai/en/datasets/20131)
- **HierText** — 11,639 images from Open Images, hosted by CVDF, "released under CC BY-SA 4.0
  license"; hierarchical word/line/paragraph annotation —
  [google-research-datasets/hiertext](https://github.com/google-research-datasets/hiertext)
- **Book-spine segmentation (Zhong & Yang, 4TU.ResearchData, 2019-11-25)** — 661 images with manually
  labelled polygon vertices; licence listed as **CC0** —
  [4TU dataset record](https://data.4tu.nl/datasets/12688436)
- **Open Shelves (capjamesg)** — annotated book spines, hosted on Roboflow, licensed
  **CC BY-NC-SA 4.0**; built to train bookshelf-identification vision models —
  [capjamesg/open-shelves](https://github.com/capjamesg/open-shelves)
- **On-shelf book spine dataset for instance segmentation (IEEE DataPort)** — 1,849 high-resolution
  mobile-phone images, polygon labels converted to MS COCO format; licence not shown in retrieved
  content —
  [IEEE DataPort](https://ieee-dataport.org/documents/shelf-book-spine-dataset-instance-segmentation)
- **uchidalab book-dataset** — 207,572 books from the Amazon.com marketplace with cover image, title,
  author and category (the arXiv v2 paper describes 137,788 books in 32 classes — the counts differ
  between repo and paper). Images are Amazon-hosted and Amazon-copyright; no licence grant —
  [uchidalab/book-dataset](https://github.com/uchidalab/book-dataset);
  [arXiv 1610.09204](https://arxiv.org/abs/1610.09204)
- **Amazon Berkeley Objects (ABO)** — product catalogue images plus 3D models. The CVPR 2022 paper
  and Amazon's own announcement state **CC BY-NC 4.0**, i.e. no commercial use —
  [ABO paper](https://arxiv.org/pdf/2110.06199.pdf);
  [Amazon Science announcement](https://amazon.science/blog/amazon-berkeley-release-dataset-of-product-images-and-metadata);
  [AWS Marketplace listing](https://aws.amazon.com/marketplace/pp/prodview-ygocdgcstr7v2).
  Contradicted by a mirror of the ABO index page and the HuggingFace `amazon/ABO-Edit` card, both of
  which say CC BY 4.0 — [amazon/ABO-Edit](https://huggingface.co/datasets/amazon/ABO-Edit).
  The NC reading is better-sourced (original paper + vendor announcement).
- A Kaggle-derived "Book covers dataset" is listed under a Creative Commons Attribution licence on a
  third-party portal, with images sourced from Book Depository —
  [portal listing](https://data.poltekkes-smg.ac.id/dataset/book-covers-dataset). Unverified against
  the original Kaggle page; the CC BY tag is almost certainly the uploader's own tag over scraped
  retailer imagery, i.e. the same trap again.

### Inferences
- The 661-image CC0 book-spine set (4TU) is the single cleanest find in this question: CC0 means no
  attribution obligation, no share-alike, and redistributable — it can go into a published
  source-available repo without qualification. It is small, but spine *geometry and segmentation*
  is exactly the kind of task where a few hundred well-labelled images is a usable starting point,
  and it is the right shape for the shelf-detection stage ahead of per-spine identification.
- Open Shelves (CC BY-NC-SA) should be flagged, not used. NC is incompatible with a project that may
  be deployed by others commercially, and SA is viral into the annotation layer.
- Open Images + TextOCR + HierText together are the defensible scene-text training base: the pixels
  are CC BY 2.0, the provenance chain is documented, and the attribution obligation is satisfiable
  from the per-image metadata files. The catch is that CC BY 2.0 attribution at 9M images is only
  practical if the attribution is shipped as the metadata file rather than as a human-readable
  credits list.
- The uchidalab set is the dataset most likely to be reached for by anyone building this, and it is
  the clearest disqualification: a self-declared fair-use assertion over another company's
  copyrighted images is not a licence that can be named, and "academic purposes" excludes a shipped
  product regardless.
- ABO is ruled out on the NC reading. Even on the disputed CC BY reading, the images are product
  catalogue renders, which is the wrong side of the render-to-photograph gap.

### Gaps
- No licence confirmed for the IEEE DataPort on-shelf spine dataset.
- ICDAR / COCO-Text licences unresolved (see Q3 Gaps).
- I found no book-cover dataset of any size with an affirmative licence on the pixels. That is a
  negative finding, stated as such.
- Document-image datasets (RVL-CDIP, PubLayNet, DocBank) were not investigated in this pass; they
  are document layout rather than cover art and were deprioritised.

---

## Q5. Public-domain book cover sources

### Takeaway
Public-domain digitisations are the only source where the **artwork itself** is free of third-party
copyright, but the corpus is pre-1930 books — decorative bindings and title pages, not modern
jacket design. Useful for diversity and for OCR-on-old-typography, structurally unable to teach
modern cover recognition.

### Cited Findings
- **British Library / Flickr Commons** — over one million public-domain images released December
  2013, extracted by the "Mechanical Curator" from roughly 65,000 digitised books; pages digitised by
  Microsoft. Users have no obligation to credit the British Library. Source-work manifests are on
  GitHub under a public-domain licence. Sources differ on the date range of the books (17th–19th
  century vs 16th–19th century) —
  [Public Domain Review collection](https://publicdomainreview.org/collection/the-british-library-s-mechanical-curator-million/);
  [Flickr blog announcement](https://blog.flickr.net/2013/12/16/welcome-the-british-library-to-the-commons/);
  [Commons:British Library/Mechanical Curator collection](https://commons.wikimedia.org/wiki/Commons:British_Library/Mechanical_Curator_collection)
- **Flickr Commons** generally uses the "no known copyright restrictions" rights statement rather
  than a licence — [Flickr blog](https://blog.flickr.net/2013/12/16/welcome-the-british-library-to-the-commons/)
- **Wikimedia Commons** — accepts only media "explicitly freely licensed" or public domain, and
  requires that "Commercial use of the work must be allowed", "Publication of derivative work must be
  allowed", and "The license must be perpetual (non-expiring) and non-revocable." Non-commercial-only
  licences and fair use are both refused. Critically for this task, it generally refuses "Scans or
  reproductive photographs of copyrighted artwork, especially book covers, album/CD covers, etc." —
  [Commons:Licensing](https://commons.wikimedia.org/wiki/Commons:Licensing)
- **Project Gutenberg** — "The vast majority of Project Gutenberg eBooks are in the public domain in
  the US"; "nobody can grant, or withhold, permission to do with this item as you please"; PG "claims
  no copyright for markup, formatting, spelling modernization, etc." Copyrighted items are
  individually flagged in the eBook header. Separately, "The name 'Project Gutenberg' is a registered
  trademark", "No permission is needed for non-commercial use", and for commercial use trading on the
  name "you need to pay royalties". The page does **not** address cover art specifically; it notes
  front matter and scans from source books may be included, that including front matter is
  "permitted, but not required", and that trademarks appearing in source material are provided "as
  is" — [Project Gutenberg permissions policy](https://www.gutenberg.org/policy/permission.html)
- **HathiTrust** — page images are the most restricted layer. The datasets page lists page images as
  provided only in limited cases and by special approval. The Acceptable Use Policy bars any
  "Attempt by any means to automate download of material from HathiTrust or otherwise attempt to
  obtain material from HathiTrust in bulk (including but not limited to page images, page text, or
  metadata)" apart from specific approved products. Public-domain **text** is downloadable in bulk
  for non-commercial research; page-image download via the Data API is limited to public-domain,
  non-Google-digitised volumes —
  [HathiTrust datasets](https://hathitrust.org/datasets);
  [HathiTrust Acceptable Use Policy](https://hathitrust.org/acceptable-use)
- A secondary source reports that in October 2024 HathiTrust announced it would cease funding and
  data access for the HathiTrust Research Center —
  [CASRAI guide](https://casrai.org/guides/hathitrust-research-center-non-consumptive-text-data-mining).
  **Unverified against an official HathiTrust source.**

### Inferences
- Project Gutenberg's trademark/royalty clause is a genuine wrinkle for a source-available project:
  the texts are free, but commercial use that trades on the PG name attracts royalties. Since the
  project would use images rather than the name, the clause is avoidable — but PG is also the weakest
  image source here, because its "covers" are frequently auto-generated or absent rather than scanned
  original artwork.
- HathiTrust is effectively closed for this purpose. The AUP language explicitly names page images
  among the things that may not be obtained in bulk, and the special-approval route is a negotiated
  licence, not a nameable public one. Rule it out.
- Flickr Commons' "no known copyright restrictions" is a **rights statement, not a licence**. It is a
  statement about the institution's knowledge, revisable if new information emerges. For a project
  that disqualifies sources whose licence cannot be named, this is a softer footing than CC0 —
  usable in practice for pre-1900 material where the underlying copyright has plainly expired, but it
  should be recorded as "public domain by age" rather than "licensed".
- Wikimedia Commons' own refusal of book-cover reproductions means Commons is a source of *books as
  objects and historic bindings*, not of modern cover artwork. Anything in Commons that looks like a
  modern cover is either a licensing error awaiting deletion or an unusually-licensed exception.
- The whole public-domain tier shares one fatal limitation for the core task: an ISBN-era cover
  recognition model needs post-1970 jacket design, and nothing in the public domain supplies it.

### Gaps
- No count of modern book-cover images on Wikimedia Commons; the category structure was not
  enumerated.
- Current status of HathiTrust Research Center services not confirmed against an official source.
- National-library digitisations beyond the British Library (BnF Gallica, Europeana, Library of
  Congress, NYPL, Rijksmuseum) were not individually checked in this pass. Their rights statements
  vary per item and would need per-collection verification.

---

## Q6. CC0 / CC-BY photographic datasets for the render-to-photograph gap

### Takeaway
Yes, and this is the strongest legal position available: Open Images and YFCC100M are built from
per-image Creative-Commons Flickr photography, so the **pixels are licensed**, and both contain
books in natural conditions. The limitation is not legal but semantic — they teach appearance under
real capture conditions, not cover identity.

### Cited Findings
- **Open Images V7** — ~9M images, images listed CC BY 2.0, annotations CC BY 4.0, with a `Book`
  class in the box vocabulary; Google explicitly disclaims warranty on per-image licence status —
  [Open Images V7 facts and figures](https://storage.googleapis.com/openimages/web/factsfigures_v7.html)
- **YFCC100M** — ~100M media objects (~99.2M photos, ~0.8M videos) uploaded to Flickr 2004–2014,
  from 581,099 photographers; "all photos and videos have a Creative Commons license", recorded
  per-item in the metadata. Access to the Yahoo Webscope distribution is governed by a signed
  "Yahoo! Webscope Data Sharing Agreement", distinct from the per-image CC licences —
  [YFCC100M paper (arXiv 1503.01817)](https://arxiv.org/pdf/1503.01817);
  [Flickr code blog](https://code.flickr.net/2014/10/15/the-ins-and-outs-of-the-yahoo-flickr-creative-commons-100-million-dataset/)
- **4TU book-spine set** — 661 images, CC0, polygon-labelled —
  [4TU dataset record](https://data.4tu.nl/datasets/12688436)
- **Unsplash Dataset** — the **Lite** set is described by Unsplash as free for commercial and
  non-commercial usage, with mirrored terms granting a licence "to train machine learning models or
  algorithms for your internal business purposes"; the **Full** set is non-commercial, and
  models "trained with or otherwise processed Non-Commercial Licensed Data must not be used for
  commercial purposes". The repo README states the dataset "is made available for research purposes"
  and "cannot be used to redistribute the images contained within". Unsplash "may suspend or
  terminate your license to the License Data upon immediate notice for non-compliance" —
  [unsplash/datasets](https://github.com/unsplash/datasets); [Unsplash Dataset page](https://unsplash.com/data)

### Inferences
- Open Images is the right backbone for the photographic-conditions problem: licensed pixels, a
  `Book` class, documented provenance, and a disclaimer that is honest rather than restrictive. The
  CC BY 2.0 attribution obligation is satisfiable by shipping the provenance CSV alongside any
  derived artefact.
- YFCC100M adds scale and a far wider range of capture conditions, but its Webscope access agreement
  is an extra, signable contract layered over the CC licences — a second set of terms to name, and a
  distribution channel whose current status was not verified. Prefer Open Images unless the extra
  scale is needed.
- Unsplash should be flagged under the DINOv3 standard, not used. "Internal business purposes" is
  narrower than commercial use, redistribution of the images is expressly forbidden, and the licence
  is terminable on immediate notice — three of the same objections raised against the bespoke
  non-transferable licence the project already rejected. The fact that it is free does not make the
  terms nameable or stable.
- The deeper limitation across this whole tier: a CC BY photo of a bookshelf still embeds copyrighted
  cover artwork (see Q3). Using such photos to learn *detection, geometry, glare, blur, occlusion and
  spine layout* is well inside the photographer's grant. Using them to learn *which cover is which*
  would be relying on the embedded derivative work. The two uses are separable, and the project
  should draw the line there explicitly.

### Gaps
- Exact Open Images V7 `Book`-class image and box counts not confirmed (only an unlabelled V4 table
  row: 41280 / 698 / 2147).
- Retail/product-shelf datasets (SKU-110K, RP2K, Products-10K, Retail-786k, Grocery Store Dataset)
  were not individually licence-checked in this pass. They are the closest analogue to a bookshelf
  and worth a follow-up; the ones I did check in this family (ABO) came back non-commercial, which
  is weak evidence that the family skews NC/research-only.
- Current availability and terms of the YFCC100M image distribution (as opposed to the metadata)
  were not verified.

---

## Q7. Publisher and retailer imagery — the explicit rule-out

### Takeaway
Retailer cover imagery is not merely unlicensed, it is affirmatively prohibited by contract.
Amazon's Product Advertising API forbids storing or caching images at all, permitting only a stored
*link* for up to 24 hours, and the agreement is locale-specific and changeable by Amazon. Rule it out
on the contract, not on an assumption.

### Cited Findings
- Amazon Associates / PA-API, reported clause: "You will not store or cache Product Advertising
  Content consisting of an image, but you may store a link to Product Advertising Content consisting
  of an image for up to 24 hours." —
  [clause archive](https://conductatlas.com/platform/amazon-associates/amazon-associates-program-policies/product-advertising-image-caching-limited-to-24-hours/)
  (**second-hand**; a third-party clause archive, not Amazon's own page)
- Amazon's own best-practices documentation states that "Product Advertising API responses can be
  cached on your end under the guidelines defined in the License Agreement", lists `Images` among
  resources with a **1 day** cache timeout, and states it "is against the Product Advertising API
  Terms and Conditions to cache customer information derived from Amazon" —
  [PA-API 5 best programming practices](https://webservices.amazon.com/paapi5/documentation/best-programming-practices.html)
- Amazon's successor Creators API documentation carries the same caching table, including the 1-day
  timeout on `Images` —
  [Creators API best practices](https://programma-affiliazione.amazon.it/creatorsapi/docs/en-us/concepts/best-programming-practices)
- The licence is locale-specific: Amazon states the licence lives on each country's Associates site,
  and that using the API against a different country's marketplace means that country's terms apply —
  [PA-API: Read the License](https://webservices.amazon.com/paapi5/documentation/read-la.html);
  [Amazon EU Associates Programme IP Licence](https://affiliate-program.amazon.co.uk/help/operating/license)
- The uchidalab research dataset's README concedes the point for scraped retailer imagery: the images
  are "hosted by and copyright Amazon.com, Inc." —
  [uchidalab/book-dataset](https://github.com/uchidalab/book-dataset)
- Wikimedia Commons independently classifies reproductive photographs and scans of book covers as
  derivative works of copyrighted artwork and refuses them —
  [Commons:Licensing](https://commons.wikimedia.org/wiki/Commons:Licensing)

### Inferences
- The rule-out reason to record is contractual, not merely copyright-based: PA-API access is granted
  under an agreement that prohibits image storage outright. Training requires storage. There is no
  configuration of the API that makes a training corpus permissible.
- Scraping retailer sites outside the API does not improve the position — it drops the contract but
  keeps the publisher's copyright in the cover artwork, with no fair-dealing argument available to a
  shipped product. The uchidalab README's "fair use for academic purposes" framing is precisely the
  argument that does not survive productisation.
- Publisher-supplied imagery via a direct feed (ONIX, or a bookshop partner pushing its own
  catalogue) is a different legal shape: the publisher or retailer **can** grant rights it actually
  holds. For this project that maps onto the existing partner-integration model, where terms are
  negotiated per partner. That is the only realistic path to licensed modern cover artwork, and it is
  a business arrangement rather than a data source.

### Gaps
- I could not retrieve the current complete US PA-API Licence Agreement text; the verbatim
  "will not store or cache" clause above comes from a third-party clause archive. Amazon's own
  best-practices page corroborates the 1-day image cache window but does not restate the
  no-storage prohibition in those words. Re-read the live agreement before citing the exact wording.
- Bookshop.org, Ingram, Nielsen/Bowker and other trade-metadata providers' image terms were not
  investigated in this pass.

---

## Cross-cutting summary table

| Source | Pixels licensed? | Licence | Scale | Access | Does NOT grant |
|---|---|---|---|---|---|
| Open Library covers | **No** | None stated | ~15M cover IDs (inferred); `covers_0005` ~765 GB | API (100 req/IP/5min for non-CoverID lookups) or archive.org tar items | Any redistribution or training right; IA disclaims copyright status |
| Google Books thumbnails | **No** | API ToS only | n/a | API, cache-header TTL | Storage, scraping, database-building, derivative works; terms mutable on 30 days |
| uchidalab book-dataset | **No** | None (self-declared fair use) | 207,572 books | GitHub + download script | Anything beyond the authors' own academic assertion |
| COCO / COCO-Text | **No** (annotations only) | Annotations CC BY 4.0 | 330k images | Download | Image rights — governed by Flickr terms |
| Open Images V7 | **Yes** | Images CC BY 2.0, annotations CC BY 4.0 | ~9M images, 600 classes incl. `Book` | Download | Warranty — Google disclaims per-image licence accuracy |
| TextOCR | **Yes** (inherited) | Annotations CC BY 4.0, images CC BY 2.0 | 28,134 images | Download | Clarity — the two licence statements conflict in the published sources |
| HierText | **Yes** (inherited) | Stated CC BY-SA 4.0 over "the dataset"; images from Open Images | 11,639 images | Download (CVDF) | A clean split statement; SA is viral |
| 4TU book-spine (Zhong & Yang) | **Yes** | CC0 | 661 images + polygons | Direct download | Nothing — CC0 is unconditional |
| Open Shelves (capjamesg) | Stated | CC BY-NC-SA 4.0 | not established | Roboflow | Commercial use; SA is viral |
| ABO (Amazon Berkeley Objects) | Stated | CC BY-NC 4.0 (disputed vs CC BY 4.0) | 147k+ products | S3 | Commercial use on the better-sourced reading |
| Unsplash Lite | Stated | Unsplash Dataset terms | ~25k photos (Lite) | GitHub | Redistribution of images; terminable on immediate notice; "internal business purposes" only |
| YFCC100M | **Yes** (per-image CC) | Per-image CC + Webscope agreement | ~100M | Webscope agreement | A single nameable licence — it is per-item, plus a signed access contract |
| Project Gutenberg | **Yes** (PD) | Public domain (US); separate PG trademark licence | ~75k books | Direct | Modern cover artwork; commercial use of the PG *name* attracts royalties |
| British Library / Flickr Commons | Effectively (PD by age) | "No known copyright restrictions" | 1M+ images from ~65k books | Flickr | A licence as such — it is a rights statement, revisable |
| Wikimedia Commons | **Yes** | CC BY / CC BY-SA / CC0 / PD; commercial + derivatives required | n/a | Download/API | Modern book covers — Commons refuses them as derivative works |
| HathiTrust page images | No | Special approval only | ~1M+ PD volumes | Request | Bulk access — AUP explicitly bars automated bulk page-image retrieval |
| Amazon PA-API / retailer | **No** | Contractual prohibition | n/a | API | Image storage of any kind; link storage capped at 24h; locale-specific, changeable |

## Flagged under the DINOv3 standard (free but onerous or mutable)

- **Google Books API** — unilateral modification on 30 days' notice, plus a content-removal demand
  right in the Books-specific terms.
- **Unsplash Dataset** — terminable on immediate notice, redistribution forbidden, scope narrowed to
  "internal business purposes".
- **YFCC100M** — a signed Webscope data-sharing agreement layered over the per-image CC licences.
- **Amazon PA-API** — locale-dependent agreement, changeable by Amazon, with an outright storage ban.
- **Flickr Commons "no known copyright restrictions"** — a knowledge statement rather than a grant;
  not a licence that can be named with confidence for anything recent.
- **HierText / Open Shelves** — ShareAlike terms that propagate into derived annotation layers.
