# Model Cascades and Routers for Cost Reduction in Production Vision/Multimodal Systems

> **Sourcing caveat that applies throughout.** Several of the most on-point papers are 2026 arXiv preprints whose PDFs could not be parsed by the fetch tool (raw FlateDecode streams returned). Where that happened the numbers come from a search-engine summary of the paper rather than from the paper itself, and are marked **[summary-only, unverified]**. Preprints are also flagged as such. The one paper read in full-text form is the book-collection matching paper (arXiv 2407.19812), via ar5iv.

---

## Q1 — The missing middle: what tiers do comparable production systems put between a cheap deterministic decoder and an expensive generative model?

### Takeaway

No published production architecture in shelf-product recognition, book scanning, or receipt processing puts a VLM directly behind a failed deterministic decoder. The standard middle is **restore → read → match-against-a-catalog**: geometric/photometric restoration feeding the *same* cheap decoder, then a text or embedding retrieval tier whose output is a *catalog identifier*, not a description. The generative model, where it appears at all, is a last tier and is reported to sometimes make quality *worse*, not just cost more.

### Cited Findings

**Retail shelf recognition (closest structural analogue — many small rigid products, a large churning catalog)**

- The canonical staged design is: product detection (one box per facing) → SKU recognition by **embedding-based retrieval** → OCR for small print and price labels → post-processing — [A deep learning pipeline for product recognition on store shelves (arXiv 1810.01733)](https://arxiv.org/pdf/1810.01733)
- Embedding + k-NN is preferred over a trained classifier specifically *because the catalog changes constantly*; a paper on grocery recognition argues for learning a strong image embedding and relying on K-NN rather than retraining classifiers as products turn over — [Domain invariant hierarchical embedding for grocery products recognition (arXiv 1902.00760)](https://arxiv.org/pdf/1902.00760)
- A 2026 paper recasts the task as **open-set, cross-domain retrieval**, projecting real shelf crops and clean catalog reference images into a shared embedding space, and argues that off-the-shelf foundation models lack sufficient discriminatory power across that domain gap, so it uses multi-stage contrastive fine-tuning — [Bridging the Catalog-to-Real Gap (arXiv 2607.09888)](https://arxiv.org/pdf/2607.09888) **[summary-only, unverified; preprint]**
- A commercial deployment (Microblink) reports an embedding-and-retrieval system over a database of millions of store photos, with **inference under 10 ms per product**, running the embedding on-device so images never reach the backend — [Microblink commerce blog](https://microblink.com/commerce-resources/blog/grocery-stores-through-the-eyes-of-ai-building-real-time-product-recognition/) *(vendor blog)*
- A self-published production case study reports a pipeline of GroundingDINO localization → Qwen3-Embedding for text queries → Qdrant cosine retrieval at top-20 depth → ArcFace-style metric retrieval, with explicit **price-tag rejection and "retrieval-evidence gates"**, moving F1 from 0.68 to 0.91 — [swd07/retail-shelf-detection](https://github.com/swd07/retail-shelf-detection) *(self-reported metrics, unverified)*

**Books specifically (spine/cover → catalog)**

- The strongest published book-to-catalog result uses **no VLM at all**: SAM segments spines, commercial OCR reads the spine text, CLIP's *text* encoder embeds both the OCR string and the catalog's author+title, and the match is a cosine-similarity argmax. Matching-only accuracy on a 15,229-title library list: **CLIP 0.939 exact / 0.915 library vs. fuzzy Levenshtein string matching 0.783 / 0.742** — [Image-text matching for large-scale book collections (arXiv 2407.19812)](https://ar5iv.labs.arxiv.org/html/2407.19812)
- **Catalog size inverts the ranking.** Against an open ~2.3M-title GoodReads list, CLIP falls to **0.449** while plain fuzzy string matching holds at **0.505** — same paper, Table 2.
- End-to-end (detection *and* matching) accuracy is much lower than matching alone: 0.617 on the library list, 0.241 on the 2.3M list (CLIP); 0.573 / 0.389 (string matching) — same paper, Table 3.
- Adding a one-to-one assignment constraint (Hungarian algorithm over the similarity matrix) raises exact-match accuracy to **0.984**, but is explicitly infeasible at the 2.3M scale on time and memory — same paper.
- Dataset scale for context: 285 shelf images, 7,536 books — same paper.
- Published spine-OCR accuracy ranges roughly 90–97%: a 2025 study tuning PaddleOCR reports **96.8% single-book recognition accuracy** in real bookshelf scenarios ([MDPI Electronics 14(23):4689](https://www.mdpi.com/2079-9292/14/23/4689)); an older Tesseract-based inventory system reports about **90%** ([Book Spine Recognition Based on OpenCV and Tesseract](https://www.researchgate.net/publication/338450698_Book_Spine_Recognition_Based_on_OpenCV_and_Tesseract)); accuracy degrades once spines tilt beyond ~15° or the background is very dark.
- A purely visual (non-OCR) spine-matching study reports 99.18% top-1 / 99.91% top-5, but in *simulated* conditions recognising 3.6k IDs from 5.6k spines — not comparable to open-catalog text matching — [Image-text matching for large-scale book collections (ResearchGate record)](https://www.researchgate.net/publication/382654559_Image-text_matching_for_large-scale_book_collections)
- Earlier book-cover work: a mobile cover-retrieval dataset of 101 covers expanded with 100K+ distractor covers shows retrieval rates fall materially once distractors are included, and that text matching helps alongside visual features — [Efficient Media Retrieval from Non-Cooperative Queries (arXiv 1411.5307)](https://arxiv.org/pdf/1411.5307)
- A triplet-loss cover-recognition system over a 762-image cover dataset reported only "over 60%" accuracy — [Library Automation System: Book cover recognition using deep learning](https://www.researchgate.net/publication/339907127_Library_Automation_System_Book_cover_recognition_using_deep_learning)

**Receipt / document processing (the industry with the most published tiering discipline)**

- A 2026 paper on **pre-inference routing** for document field extraction finds **30–58% of receipt documents genuinely need the large model**; on SROIE, F1 was **0.828 (small) vs 0.896 (large)**, on CORD **0.395 vs 0.473**. Critically, it reports that escalation is *not uniformly beneficial*: always-large sacrifices quality on some documents because the large model over-generates or departs from the target schema — [Pre-Inference Routing for Cost-Efficient Document Field Extraction (arXiv 2608.06607)](https://arxiv.org/pdf/2608.06607) **[summary-only, unverified; preprint]**
- A reference economic model for SME invoice automation gives the tier cost stack as: OCR $0.005–0.015/page → small-model LLM $0.02–0.05/invoice for **80–85%** of volume → large-model $0.10–0.30/invoice for the remaining **15–20%** → infrastructure $0.05/invoice — [Reducing the Cost of Invoice Processing in SMEs](https://www.researchgate.net/publication/408084875_Reducing_the_Cost_of_Invoice_Processing_in_Small_and_Medium_Enterprises_A_Reference_Architecture_and_Economic_Model_for_LLM-Powered_Accounts_Payable_Automation) **[summary-only; preprint]**
- The terminal tier in production document AI is a human, not a bigger model: thresholds below ~0.70 route to human review, with straight-through-processing rates of **60–75% after about three months of tuning** — [Parseur HITL best practices](https://parseur.com/blog/hitl-best-practices), [Airparser](https://airparser.com/blog/human-in-the-loop-document-extraction) *(vendor blogs)*

### Inferences

- The middle tier that these systems actually build is **"produce a catalog identifier by retrieval", not "produce a description by generation"**. A VLM that answers "this is a book" is structurally the wrong artefact: the tier's job is to emit a *candidate key*, which is what makes a downstream verifier possible.
- For the hostile-barcode stratum there are two independent middles available from the same photograph, and comparable systems use both: (a) a **digit-string path** — restore the barcode region and re-decode, or read the OCR-B human-readable digits printed beneath it; (b) a **catalog-retrieval path** — OCR the cover's title/author block and match it against Open Library. These are structurally what shelf-recognition's "SKU retrieval" and "OCR the small print" tiers are.
- The catalog-size inversion in arXiv 2407.19812 (CLIP 0.939 → 0.449, string matching 0.783 → 0.505 as the target list grows from 15k to 2.3M) is a direct warning for a system matching against Open Library's tens of millions of editions: **unconstrained embedding similarity over the full catalog is weaker than its small-catalog numbers suggest.** Constrain the candidate set first (a cheap text query to the OL/GB search API using the OCR'd title tokens) and use similarity only to rank inside the returned set.
- The digit path is by far the stronger middle for this project *because its output space is 13 digits with an arithmetic gate* (see Q4), while the cover-text path's output is free text with no gate.

### Gaps

- No published, numbered, end-to-end production architecture for "consumer phone photo → ISBN" with per-stratum accuracy. The nearest neighbours are library shelf-scanning research (controlled capture) and retail SKU recognition (controlled catalog imagery).
- The 2026 preprints above could not be read in full; their internal methodology is unverified.

---

## Q2 — Cascade design: how is the deferral decision actually made, and how is it calibrated?

### Takeaway

Production and published cascades have largely moved off raw model confidence. The three live designs are: a **learned scorer over (input, output)** predicting correctness; a **calibrated** confidence (isotonic/conformal) with a threshold chosen by explicit cost minimisation; and **pre-inference routing** that decides from input features before any model runs. Every serious source states that an uncalibrated model-internal confidence is a poor deferral signal, and the practitioner literature adds a trap that matters acutely here: *the gate itself has a cost*.

### Cited Findings

- **FrugalGPT** does not use model confidence: it fine-tunes a DistilBERT scorer that predicts answer correctness from the (query, response) pair, with a fixed per-stage threshold. Headline results: matching the best individual LLM (e.g. GPT-4) with **up to 98% cost reduction**, or **+4% accuracy at the same cost** — [FrugalGPT (arXiv 2305.05176)](https://arxiv.org/pdf/2305.05176)
- **Conformal Cascade** replaces the confidence threshold with **conformal prediction-set size** as the deferral rule, arguing explicitly that raw LLM confidence scores are miscalibrated and that thresholds must be tuned per model pair and per domain. Expected cost is a closed-form function of the error level and the calibration-set acceptance rate; calibration costs K·n·N inference calls; reported to beat the strongest calibration-tuned heuristic cascade on most of 18 benchmarks — [Conformal Cascade (arXiv 2607.25018)](https://arxiv.org/abs/2607.25018) **[summary-only; preprint]**
- **UCCI** maps token-level uncertainty to a per-query error probability via isotonic regression, then picks the escalation threshold by constrained cost minimisation; proves threshold policies on the *calibrated* score are cost-optimal under three assumptions. Reported: expected calibration error **0.12 → 0.03**, cost down **~31%** — [UCCI (arXiv 2605.18796)](https://arxiv.org/pdf/2605.18796) **[summary-only; preprint]**
- **CAUC** uses independently calibrated confidence as a shared decision interface across heterogeneous models and reports avoiding **~47% of strong-model calls** across six benchmarks — [Calibration-Aware Uncertainty Cascades (arXiv 2609.11446)](https://arxiv.org/html/2609.11446v1) **[summary-only; preprint]**
- A post-hoc calibrated deferral threshold is reported to cut use of the strongest LLM by **up to 82.5%** — Jung et al. as cited in [From Deferral to Learning (arXiv 2509.22984)](https://arxiv.org/pdf/2509.22984) **[second-hand citation]**
- **Pre-inference routing**: decide from document features *before* running even the cheap model, rather than running cheap-then-gating — [arXiv 2608.06607](https://arxiv.org/pdf/2608.06607) **[summary-only; preprint]**
- **Adding abstention to a cascade doubles the tuning burden**: abstention thresholds alongside deferral thresholds make grid search slow as early as three tiers; the paper reports early abstention (abstaining at earlier tiers rather than only at the final model) lowers test loss by **2.2% on average across six benchmarks** — [Cost-Saving LLM Cascades with Early Abstention (arXiv 2502.09054)](https://arxiv.org/pdf/2502.09054) **[summary-only]**
- **Conformal abstention policies** tuned by reinforcement learning let the system answer, return a candidate set, or abstain, for LLMs and VLMs — [Learning Conformal Abstention Policies (arXiv 2502.06884)](https://arxiv.org/html/2502.06884v1)
- **The gate's own cost can dominate.** A practitioner replication of a FrugalGPT-style cascade with a self-confidence gate matched always-cheap accuracy (0.844) at **18% of always-strong cost**, but at **2.4× the cost of bare-cheap**, because the gating call itself is a model call — [llm-model-routing-benchmark L3a](https://github.com/dennisonbertram/llm-model-routing-benchmark/tree/main/03-pocs/L3a-frugalgpt-cascade) *(self-reported)*
- Production document-AI thresholding conventions: field-level **0.90** to auto-accept, **0.70–0.89** secondary check, **<0.70** human review, and **0.95** as the starting threshold for high-consequence fields, with straight-through only when *every* chunk clears — [Unsiloed](https://www.unsiloed.ai/blog/confidence-score-thresholds-document-automation), [LandingAI](https://landing.ai/blog/introducing-confidence-scores-surface-parsing-uncertainty-before-it-becomes-a-problem) *(vendor blogs; practitioner rules of thumb, not audited benchmarks)*
- Instead of abstaining on a low-confidence answer, **ReCoVERR** seeks additional visual evidence to support the prediction before deciding — [Selective "Selective Prediction" (arXiv 2402.15610)](https://arxiv.org/abs/2402.15610), [ACL Findings 2024](https://aclanthology.org/2024.findings-acl.767.pdf)

### Inferences

- In a scale-to-zero serverless GPU economy where cost is dominated by the *idle scaledown tail* rather than tokens, the cascade literature's cost model does not transfer directly. The relevant unit is **"did this request wake the GPU", not "how many tokens did it burn"** — which makes the gate-cost trap above decisive: any gate that itself requires a GPU call destroys the whole saving. Only CPU-resident gates (checksum arithmetic, a catalog HTTP lookup, a retrieval margin over a local index) are free in this regime.
- **Pre-inference routing is the right shape here.** Cheap CPU-computable image features (barcode-region detection score, blur/Laplacian variance, glare fraction, whether any structurally valid digit string was extracted) can decide whether to wake the GPU at all — unlike confidence-gating, this never pays a GPU wake-up to learn that it was not needed.
- The one calibration result that transfers cleanly is the methodological one: **choose the threshold by explicit cost minimisation on a held-out set with your own asymmetric costs** (error ≫ abstention here), not by picking 0.9 because it is a round number.

### Gaps

- The cascade/routing literature is overwhelmingly text-LLM. No vision-specific cascade with published *cost* numbers and a learned deferral rule was found.
- No published treatment of cascade economics under a fixed per-wake-up cost model (serverless GPU with an idle tail) rather than a per-token model. This appears genuinely unaddressed in the literature.

---

## Q3 — Confidence signals that measure "did I read the right thing", not "did I read clearly"

### Takeaway

The project's measured finding is the literature's consensus, stated bluntly in a patent and reproduced in evaluations: engine confidence is a **self-assessment of decodability**, not of correctness or relevance, and high confidence on a bad input means the model *committed* to a wrong answer. Every signal that actually measures relevance is **external to the reader**: structural validity of the extracted string, resolution against an authority, a retrieval *margin* (ratio, not distance), a region/type prior about where the right text can be, and agreement between independently-failing readers.

### Cited Findings

**Why engine confidence measures legibility**

- "The confidence score is a self-assessment by the OCR algorithm of the reliability of the output. In practice, the OCR confidence score does not always provide a reliable prediction of whether the OCR output matches the ground truth." — [USPTO 9384423, System and method for OCR output verification](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9384423)
- Confidence scores are not probabilities: a score of 60 does not imply a 60% likelihood of correctness, and no OCR engine perfectly correlates confidence with correctness — [TDWI, Using OCR: How Accurate is Your Data?](https://tdwi.org/articles/2018/03/05/diq-all-how-accurate-is-your-data.aspx)
- A PaddleOCR evaluation records a case at **99.6% confidence and 0% accuracy**, and concludes that high confidence on a bad image means the model committed to a wrong answer; the author recommends pairing confidence with image-quality checks and post-OCR validation — [PaddleOCR evaluation](https://medium.com/@niharikam1711/i-evaluated-paddleocr-on-6-real-document-types-here-is-exactly-where-it-works-and-where-it-fails-d8fac9ee4cc1) *(practitioner write-up)*
- A word-level score is a single number for a whole word, so one misread character drags the rest down — and engines are reported to be overconfident on adversarial input — [theneuralbase, confidence-aware processing](https://theneuralbase.com/ocr-for-ai/learn/advanced/confidence-aware-processing/) *(vendor guide)*
- OCR has no error correction and no checksum, so it trades no-reads for **silent misreads**; 2D codes with Reed–Solomon ECC either decode correctly or report a no-read — [Keyence, OCR vs 2D Code Reading](https://www.keyence.com/blog/ocr-vs-2d-code-reading.jsp) *(vendor)*

**Signals that do measure relevance**

- **Nearest-Neighbour Distance Ratio (NNDR / OSNN)**: threshold the *ratio* of the distance to the nearest neighbour of one class over the distance to the nearest neighbour of a different class, rejecting as "unknown" above the threshold. The original work reports that thresholds on the *ratio* outperform thresholds on raw distance in open-set scenarios — [Nearest neighbors distance ratio open-set classifier (Mendes Júnior et al.)](https://www.researchgate.net/publication/311930507_Nearest_neighbors_distance_ratio_open-set_classifier); summarised in [Recent Advances in Open Set Recognition: A Survey (arXiv 1811.08581)](https://arxiv.org/pdf/1811.08581)
- The rejection threshold should be set according to the **openness** of the specific problem, tuned on a validation set under simulated open-set conditions; extensions add K-neighbour variants and extreme-value-theory tail modelling of the ratio distribution — same survey.
- Production retail pipelines add explicit **type/region rejection** rather than relying on scores: "price-tag rejection and retrieval-evidence gates" — [swd07/retail-shelf-detection](https://github.com/swd07/retail-shelf-detection) *(self-reported)*
- **Ensembles of weak verifiers** beat any single verifier: a cheap non-reasoning generator (Llama 3.3 70B) plus a weak-verifier ensemble reaches roughly o3-mini-level accuracy, and distilling the ensemble cuts verification inference cost by **99.97%** — [Shrinking the Generation-Verification Gap with Weak Verifiers (arXiv 2506.18203)](https://arxiv.org/pdf/2506.18203)
- **Self-verification is nearly free and shares every blind spot with the generator** — [When AI Has to Show Its Work](https://daicelabs.com/insight/when-ai-has-to-show-its-work) *(commentary)*; and independence "is not established merely by the use of a second model" — [arXiv 2609.30219](https://arxiv.org/pdf/2609.30219) **[summary-only; preprint]**
- **Negative result worth carrying:** in the book-matching paper, a BERT re-ranker over the top-10 CLIP candidates *with an explicit "no match" abstention index* **did not beat plain CLIP in any setting** (0.836 vs 0.939 exact; 0.310 vs 0.449 on the open list, falling below even fuzzy string matching) — [arXiv 2407.19812](https://ar5iv.labs.arxiv.org/html/2407.19812)
- That paper's failure modes are instructive and all relevance failures, not legibility failures: series names matching the wrong title (three books in a series all matched to the first), partial author/title on a spine, and **non-book text such as section signs detected as books** — same paper.

### Inferences

- **The Tesseract-at-0.95-reading-social-media-chrome failure was not a confidence failure.** It was two missing things, neither of which is a model: (a) a *region hypothesis* — OCR was allowed to read the entire frame instead of only a detected barcode/ISBN block or cover region; (b) a *type check* — the output was accepted as a candidate without having to be the right *kind* of string. UI chrome read at 0.95 confidence produces no 13-digit 978/979 string that passes mod-10, so a structural grammar would have rejected it at zero cost regardless of the engine's confidence.
- The general rule the sources support: **confidence answers "did I read clearly"; a grammar answers "is this the right kind of thing"; an authority answers "is this a real thing"; a margin answers "is this better than the alternatives"; agreement answers "would an independent reader agree".** Only the last four are relevance signals, and three of the four are free on CPU.
- For the cover-retrieval tier specifically, **NNDR is the signal to use, not raw cosine similarity.** "How much better is the best match than the runner-up" is exactly the open-set abstention question, and the book-matching paper's series-name failure (three different books all matching the series' first title) is precisely a case where raw similarity is high and the margin is low.
- The failed BERT abstention head is a caution against building a learned abstention model for the middle tier: on this very task a learned "no match" head underperformed a plain similarity argmax and both underperformed a *structural* method (fuzzy matching) on the large catalog. **A structural gate beat a learned gate in the one directly comparable published experiment.**

### Gaps

- No study found that measures OCR confidence's correlation with *relevance* (right region) as distinct from *correctness* (right characters). The available statements are qualitative or anecdotal single cases.
- No published calibration curve for Tesseract/PaddleOCR confidence against ground-truth correctness on consumer photographs.

---

## Q4 — Verification as a tier: cheap generator proposes, external authority disposes

### Takeaway

The generation-verification literature identifies a **sound external verifier as the scarce resource** and shows that when one exists, a cheap generator plus the verifier reaches expensive-model accuracy. The ISBN hard gate is that scarce resource, and it is actually two independent verifiers composed: an arithmetic check digit (free, catches all single-digit errors) and a catalog resolution (catches checksum-valid strings that are not books). Together they change the requirement on the middle tier from **precision** to **recall-within-k** — the generator only has to put the right identifier somewhere in a small candidate set, and abstention becomes automatic when nothing in the set resolves.

### Cited Findings

**The generator/verifier architecture**

- The generation-verification gap is defined as **Pass@K − Success Rate**: correct answers the generator produced that the selector failed to pick — [generator-verifier-gap analysis](https://github.com/madhavamshahi/generator-verifier-gap) *(self-published)*
- **Whether a cheap check exists is the dominant variable.** The same generator behaves completely differently by task: on MBPP, a program verifier converts most of the Pass@K headroom into success; on a logic task, the same model judging its own answers ends up *below* a single sample — same source.
- A cheap non-reasoning generator plus an ensemble of weak verifiers reaches roughly o3-mini accuracy; distilling the verifier ensemble cuts inference cost by **99.97%** — [Weaver (arXiv 2506.18203)](https://arxiv.org/pdf/2506.18203)
- "A model cannot climb above the discrimination ability of its judge", and LLM judges/reward models fail under heavy optimisation pressure, which is why sound external verifiers are treated as the scarce resource — [Proof-Carrying Cognition (arXiv 2609.09776)](https://arxiv.org/html/2609.09776v1) **[summary-only; preprint]**
- The prescribed action when the cheap verifier cannot support the claim: escalate to stronger computation, human review, independent validation, sandboxed trial, **or explicit non-acceptance** — [Generate And Verify Separation](https://abstractopedia.org/archetypes/generate_and_verify_separation/) *(encyclopedia-style write-up)*

**What the ISBN gate is actually worth (error-detection properties)**

- **ISBN-10** (mod 11, weights 10→2): single-digit errors are **always detected**, and *all* adjacent transpositions are always detected — because 11 is prime, no two valid ISBN-10s differ only by a transposition of two digits. Two altered non-transposed digits, or three altered digits, *can* produce a valid ISBN — [Wikipedia, ISBN](https://en.wikipedia.org/wiki/ISBN)
- **ISBN-13** (alternating weights 1,3 mod 10): the article states the check "does not catch all errors of adjacent digit transposition" — specifically, **swapping two adjacent digits that differ by 5 is invisible** (e.g. …61… ↔ …16…, both contributing 9 or 19 to the weighted sum, congruent mod 10). No numeric detection probabilities are given — same source. *(The "all single-digit errors are detected" property for ISBN-13 follows from the formula — a single digit changed by δ∈1..9 shifts the sum by δ or 3δ, neither a multiple of 10 — but the Wikipedia article does not state it explicitly.)*
- The checksum-after-OCR pattern is the accept gate in commercial practice: a decoding system maps failed barcode characters to the human-readable text and then "will apply the appropriate checksum algorithm to ensure that the tracking number decoded from the bar code and human readable text appears to be a valid tracking number" — [USPTO 5880451 / EP0978087B1, OCR assisted bar code decoding](https://patents.google.com/patent/EP0978087B1/en)
- Tesseract itself "cannot validate checksum digits", so the validation must be applied by the caller — [Dynamsoft, barcode scanner with Tesseract OCR fallback](https://www.dynamsoft.com/codepool/tesseract-ocr-python-barcode.html) *(vendor)*
- Real implementations get this wrong in a characteristic way: an EAN-8 checksum path wrongly rejecting valid UPC-E codes, because UPC-E's check digit is computed *after* expansion to UPC-A — [PR #1095 / #1159 discussion](https://github.com/rdhforeclosureconqueror-sys/Mufasa.fitness.node/pull/1159) *(incidental, but a concrete symbology pitfall)*

### Inferences

- **The verifier composition is the whole argument.** A random 13-digit string passes mod-10 with probability 0.1 — weak on its own. But the second filter is far stronger: the fraction of checksum-valid 978/979 strings that resolve to a real edition in Open Library/Google Books is small. Composed, the gate is strong enough that the middle tier can be allowed to be *noisy and multi-hypothesis* at essentially no risk.
- Therefore the correct design for the middle tier is **propose k candidates, not one**: digit-level beam over OCR hypotheses (confusable pairs 0/O, 1/l/7, 5/S, 8/B), multiple crops, multiple binarisation settings — then let checksum + catalog select. This is cheap because all k candidates are filtered by arithmetic before any network call, and the catalog lookups are HTTP, not GPU.
- **The accuracy requirement on the generator drops from "right" to "right in top-k, and never wrong in a way the verifier accepts."** This is exactly the Weaver result transplanted: cheap generator, sound verifier, expensive-model accuracy.
- **Abstention becomes the default behaviour, for free.** Nothing in the candidate set resolves → no identification. The project's asymmetry (error ≫ abstention) is satisfied structurally rather than by a tuned threshold — which is the strongest available answer to "a cheap tier that is wrong is worse than one that abstains."
- **The one residual false-accept path is the ISBN-13 transposition blind spot**: two adjacent digits differing by 5, swapped, yields a checksum-valid string that may resolve to a *different real book*. That is precisely the failure that puts a wrong book in a reader's library with full apparent confidence. The cheap mitigation is corroboration from the same photograph: the resolved record's title/author must be consistent with any text read from the cover. The authority's response already carries the title, so this costs nothing extra.
- Composing the two paths this way also recovers an ISBN-10 advantage worth exploiting: for older books whose ISBN-10 is printed, the mod-11 check is strictly stronger (it catches every adjacent transposition). Validating the printed ISBN-10 *and* its ISBN-13 conversion gives two arithmetic checks on the same read.

### Gaps

- No published measurement of the **false-accept rate** of "checksum + catalog resolution" applied to OCR'd ISBNs — i.e. how often an OCR misread produces a checksum-valid string that also resolves to a real, wrong edition. This is the single most load-bearing unknown for the design and would have to be measured locally (it can be: perturb known-good ISBNs with realistic OCR confusions and count how many resolve).
- No numeric error-detection probabilities for ISBN-13 in the cited source.

---

## Q5 — Two cheap models and compare, versus one expensive model

### Takeaway

Published results favour the two-cheap-and-compare design where the two models fail differently: one study reports a two-model cheap panel gated by agreement matching a four-model panel's accuracy on every benchmark, with no further benefit from a third cheap model. The crucial qualifier from the literature is that **independence is not established by using a second model** — agreement is only informative when the two readers have disjoint failure modes. In a scale-to-zero GPU economy the trade-off is also lopsided in a way the papers do not model: two CPU readers are free, so the question is not cost-per-call but whether the second reader adds independent evidence.

### Cited Findings

- **Agreement-gated cascade**: run a cheap two-model panel on every problem; if the two agree, accept at the cost of two calls; only on disagreement escalate to the full four-model panel. Reported to **match the full panel's accuracy on every benchmark**, with a three-model cheap tier giving **no further benefit** over the two-model tier — [LLMs as a Jury (arXiv 2607.10139)](https://arxiv.org/pdf/2607.10139) **[summary-only, unverified; preprint; the search tool flagged the arXiv ID as unusual]**
- Weak-verifier *ensembles* outperform any single verifier, and the ensemble can be distilled to recover the cost (−99.97%) — [Weaver (arXiv 2506.18203)](https://arxiv.org/pdf/2506.18203)
- **Independence caveat**: "independence is not established merely by the use of a second model" — [arXiv 2609.30219](https://arxiv.org/pdf/2609.30219) **[summary-only; preprint]**; and self-verification "shares every blind spot with the generator" — [daicelabs commentary](https://daicelabs.com/insight/when-ai-has-to-show-its-work)
- **Escalating is not free accuracy**: always-large *sacrifices* quality, not just cost, on some receipt documents because the large model over-generates or departs from the schema — [arXiv 2608.06607](https://arxiv.org/pdf/2608.06607) **[summary-only; preprint]**
- Confidence-gated single-cheap-model cascade economics: matched always-cheap accuracy (0.844) at 18% of always-strong cost, but **2.4× bare-cheap cost** because the gate is itself a model call — [L3a FrugalGPT cascade PoC](https://github.com/dennisonbertram/llm-model-routing-benchmark/tree/main/03-pocs/L3a-frugalgpt-cascade) *(self-reported)*
- **Empirical evidence that two cheap readers genuinely fail differently on this exact task**: on the book-matching benchmark, CLIP (semantic) and fuzzy Levenshtein (lexical) *invert* their ranking as catalog size grows — 0.939 vs 0.783 on a 15k list, 0.449 vs 0.505 on a 2.3M list — [arXiv 2407.19812](https://ar5iv.labs.arxiv.org/html/2407.19812)

### Inferences

- The book-matching inversion is the strongest published evidence for the two-cheap design *in this domain*: two methods whose relative accuracy flips with catalog size necessarily have different failure modes, which is exactly the condition under which agreement is informative and disagreement is a useful escalation/abstention trigger.
- For this project the two genuinely independent cheap readers are **not two models of the same kind**. They are two *paths*: (1) the digit-string path (barcode decode, or OCR-B digits → checksum → catalog) and (2) the cover-identity path (title/author OCR or image embedding → catalog search). Blur and glare kill the first; a plain, foreign-language, or textless cover kills the second. Agreement on the same ISBN is strong evidence; disagreement should abstain or escalate.
- This design sidesteps the gate-cost trap entirely: both paths are CPU work plus HTTP lookups, so running both on every hostile image costs nothing against a $50/month budget dominated by GPU idle tails. **"Two cheap vs one expensive" is not a close call in this cost model — the expensive model's marginal cost is a container wake-up, and the cheap ones' is zero.**
- A corollary worth stating plainly: because escalation to the VLM is not reliably accuracy-improving (the receipt-routing finding) *and* on this project's own measurement contributes nothing on the hostile stratum, the VLM should probably be demoted below the catalog-retrieval tier rather than sitting directly behind the decoder.

### Gaps

- The "LLMs as a Jury" cascade result could not be verified beyond a search summary and its arXiv ID was flagged as unusual by the search tool — treat the "matches full-panel accuracy" claim as unconfirmed.
- No published cost/accuracy analysis of two-cheap-vs-one-expensive in a *vision* pipeline, and none under a fixed-wake-up cost model.

---

## Q6 — What production systems do when a barcode will not decode

### Takeaway

The published and shipped playbook, in increasing cost order: **(1) detect and rectify the barcode region; (2) multi-crop / multi-frame / binarisation sweep and re-decode; (3) deblur or super-resolve and re-decode with the same cheap decoder; (4) OCR the human-readable digits and accept only on checksum; (5) ask the user.** Reported decode-rate gains from restoration are large but from low baselines — 32%→65%, +27.2pp with ZBar, +14%, +8.67pp, 0%→73% — and every source notes a residual that restoration cannot recover. Commercial scanners ship step 4 as a named feature.

### Cited Findings

**Restoration before re-decoding (quantified)**

- Motion-blur removal on 138 barcode images with varying camera blur raised the recognition rate **from 32% to 65%**, and let the decoder handle larger blur kernels than it otherwise could — [Yahyanejad et al., Removing Motion Blur from Barcode Images, CVPR 2010 workshop](https://pervasive.uni-klu.ac.at/publications/pdf/Yahyanejad_CVPR2010.pdf)
- Wearable QR scanning on 340 blurred frames: **217 decoded without deblurring, 83 more decoded only after deblurring, 40 still failed** (63.8% → 88.2%; 67.5% of the residual failures recovered) — [Fast Blur Removal for Wearable QR Code Scanners, ACM](https://dl.acm.org/doi/pdf/10.1145/2802083.2808390)
- An edge-feature-guided multi-scale deblurring network raised decoding rates by **27.2% with the ZBar decoder and 10.4% with WeChat**, with the authors noting performance drops under extreme blur or low contrast — [MDPI Electronics 14(7):1298](https://www.mdpi.com/2079-9292/14/7/1298)
- Deep-learning super-resolution for low-resolution QR codes: **+15.7% success rate** over traditional super-resolution algorithms — [PeerJ CS 2841](https://peerj.com/articles/cs-2841.pdf)
- An oriented barcode detector plus DeblurGAN-v2 reported a **14% improvement in decoding rate** over the original images — [Using Deep Learning to Improve Detection and Decoding of Barcodes, IEEE 9897371](https://ieeexplore.ieee.org/document/9897371/) **[summary-only]**
- A 2025 lightweight restoration model for damaged barcodes/QR codes in logistics reports **+8.67 percentage points** decode rate (EG-Restormer), and a separate reported case of **1D barcode decodability rising from 0% to 73%** — [Lightweight Deep Learning Model and Novel Dataset for Restoring Damaged Barcodes and QR Codes](https://www.researchgate.net/publication/393188778_Lightweight_Deep_Learning_Model_and_Novel_Dataset_for_Restoring_Damaged_Barcodes_and_QR_Codes_in_Logistics_Applications) **[summary-only]**
- A DataMatrix read-rate thesis reports **74% decoding-rate improvement** from deep-learning image enhancement, outperforming classical binarization (baseline unclear from the summary) — [Svarnovics, University of Twente](https://essay.utwente.nl/fileshare/file/88947/Svarnovics_MA_EEMCS.pdf) **[summary-only]**
- **Detect-then-warp before decoding**: a fashion-image pipeline detects barcodes with Faster R-CNN and warps the crop before handing it to pyzbar, which lets heavily skewed codes decode; the source does not isolate warping's own contribution — [Barcode Detection and Decoding in On-line Fashion Images](https://library.imaging.org/admin/apis/public/api/ist/website/downloadArticle/ei/31/8/art00010)
- Industrial readers group super-resolution and deblurring together as a way to extend depth of field, most useful at larger reading distances — [USPTO 11170191](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11170191)

**OCR of the printed digits — a shipped commercial tier**

- Scandit lists OCR as a **fallback symbology extension** for several symbologies including **EAN-13/UPC-A** and Code 128 — [Scandit docs, Configure Barcode Symbologies](https://docs.scandit.com/sdks/linux/barcode-capture/configure-barcode-symbologies/)
- Datalogic SnapOCR: "When the scanner cannot decode a barcode, SnapOCR automatically activates to capture the human-readable text, ensuring there is no disruption to the workflow" — [Datalogic Developer Portal](https://developer.datalogic.com/mobile-computers/news/snapocr)
- The recommended structure is SDK-primary / OCR-on-failure, with the caller supplying the checksum validation Tesseract cannot do — [Dynamsoft](https://www.dynamsoft.com/codepool/tesseract-ocr-python-barcode.html)
- The human-readable digits under an EAN-13 are printed in **OCR-B**, a typeface designed for machine readability — [Wikipedia, OCR-B](https://en.wikipedia.org/wiki/OCR-B)
- The checksum-before-accept pattern for OCR-recovered characters is explicit in the OCR-assisted-decoding patent — [EP0978087B1](https://patents.google.com/patent/EP0978087B1/en)

**Ask the user**

- The terminal tier in production document pipelines is human review below the low threshold (~0.70), with straight-through processing of 60–75% after tuning — [Parseur](https://parseur.com/blog/hitl-best-practices), [Unsiloed](https://www.unsiloed.ai/blog/confidence-score-thresholds-document-automation) *(vendor blogs)*

### Inferences

- **Expect restoration to recover roughly half to two-thirds of current decode failures, not all of them.** The wearable-QR study is the cleanest measurement of exactly this situation (deblurring applied only to frames that already failed): 83 of 123 residual failures recovered, 40 irrecoverable. Applied to a 15% hostile stratum that is currently near-total failure, that shape suggests a realistic post-restoration target well short of the 95% clean-barcode bar — restoration narrows the gap, it does not close it.
- **The OCR-B digit tier is the highest-value single addition for this project**, because it is the one tier whose output is both (a) structurally constrained to 13 digits in a machine-readable typeface and (b) verifiable for free by checksum + the ISBN hard gate. It also fails *independently* of the barcode decoder: the bars and the digits are degraded differently by glare, partial occlusion, and low resolution (a barcode needs sub-bar-width resolution; the digits are much larger features).
- Ordering by cost in this project's economics puts all of steps 1–4 **inside the existing fixed container cost** — detection, rectification, binarisation sweeps, and OCR are CPU work, and even a small deblur/SR network can run on CPU or ONNX. None of them should wake the GPU. That makes the entire published playbook affordable within the $50/month budget, in contrast to any tier that adds GPU time.
- A retry-with-guidance UX tier ("move closer", "reduce glare", "flatten the cover") is the cheapest tier in existence and is effectively what the commercial scanners automate with continuous multi-frame capture — worth placing *before* escalation, not after.
- Symbology arithmetic must be implemented per-symbology (the UPC-E-expanded-to-UPC-A check-digit pitfall is a documented real-world bug), and for books both the ISBN-10 (mod 11) and ISBN-13 (mod 10) checks should be applied where both are printed, since the mod-11 check is strictly stronger against transpositions.

### Gaps

- **No head-to-head benchmark of deblurring vs super-resolution on blurry EAN-13 barcodes.** Most quantified results are QR or DataMatrix; the strongest 1D result (32%→65%) is from 2010.
- No published figures for OCR-of-printed-digits recovery rate on barcodes that failed to decode — the commercial vendors ship the feature but publish no decode-recovery numbers.
- No published cost-per-recovery numbers for any restoration tier, and nothing at all on restoration economics under serverless/scale-to-zero constraints.
