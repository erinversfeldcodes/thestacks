# Model Provenance & Chip Huyen's `aie-book` — Research Notes

*Researched 2026-11-13. Two tasks: (1) what the public `aie-book` repo actually contains for a
production multi-stage vision pipeline; (2) training-data provenance due diligence on the VLMs this
system uses.*

---

## Q1. What is actually in `chiphuyen/aie-book`, and what is relevant to a multi-stage vision pipeline?

### Takeaway

The repo is **a curated reading list plus narrative chapter summaries, and not much else** — five of
its eleven markdown files are empty "Coming soon" placeholders, including the two that would have
mattered most here (`case-studies.md`, and the prompt-attack / defensive-prompt sections of
`prompt-examples.md`). It contains **zero** substantive content on cascades, routing, prompts-as-global-state,
or few-shot leakage; the value is `resources.md` (a genuinely good ~200-link bibliography) and
`prompt-examples.md` (six real production prompts).

### Cited Findings

**Repo inventory** (via GitHub API, `git/trees/main?recursive=1`, retrieved 2026-11-13) — 18,297 stars,
description `"[WIP] Resources for AI engineers. Also contains supporting materials for the book AI
Engineering (Chip Huyen, 2025)"`, last push `2026-07-03` — [github.com/chiphuyen/aie-book](https://github.com/chiphuyen/aie-book)

| File | Size | Status |
|---|---|---|
| `README.md` | 15,767 B | Book marketing, reviews, purchase links, file index |
| `ToC.md` / `ToC.pdf` | 17.6 KB / 180 KB | Table of contents |
| `resources.md` | 34,959 B | **Substantive** — the curated bibliography |
| `chapter-summaries.md` | 33,980 B | **Substantive** — narrative summaries, no technique detail |
| `prompt-examples.md` | 8,054 B | **Partly substantive** — 6 real prompts; 2 sections empty |
| `translations.md` | 9,008 B | Translation editions |
| `study-notes.md` | 1,301 B | Links to 3rd-party readers' notes |
| `appendix.md` | 180 B | ⬛ `"_Coming soon_"` |
| `misalignment.md` | 89 B | ⬛ `"_Coming soon_"` |
| `case-studies.md` | 14 B | ⬛ `"_Coming soon._"` — literally the entire file |
| `scripts/ai-heatmap.ipynb` | 223 KB | Unrelated (ChatGPT/Claude conversation heatmap) |

- The last five commits are link fixes and translation-page updates (`2026-06-09` and `2026-07-03`); there is no sign of the placeholder files being filled since the book shipped — [commits API](https://api.github.com/repos/chiphuyen/aie-book/commits)

**Keyword sweep across every markdown file in the repo** (`grep -rniE` for cascade / rout(e|ing) /
fallback / "global state" / few-shot / guardrail / "structured output" / slice / strat(um|a|ified) /
"regression suite" / "constrained decoding" / "cost per"):

- `cascade` — **0 hits**
- `routing` / `route` — **0 hits**
- `fallback` — **0 hits**
- `global state` — **0 hits**
- `few-shot` — **0 hits** (the phrase appears only inside a `resources.md` *link title*, "Language Models are Few-Shot Learners")
- `guardrail` — **1 hit**, `chapter-summaries.md` line 225, and it is about component placement, not design: *"guardrails can be implemented in the inference service, the model gateway, or as a standalone component"*
- `structured output` — **0 hits**; `constrained decoding` appears only as a `resources.md` link title
- `slice` / `stratum` / `stratified` / `regression suite` — **0 hits** (the one `slice` match is `.slice()` in a JavaScript code sample in Cursor's prompt)

**What `chapter-summaries.md` does say on evaluation** (Ch. 3–4), which is the closest the repo gets
to pipeline-evaluation discipline:

- AI judges are *"unreliable as benchmarks to track an application's changes over time"* because the judge itself is iterated on, so its judgments change — [chapter-summaries.md](https://github.com/chiphuyen/aie-book/blob/main/chapter-summaries.md)
- *"Scores aimed to measure the same quality by different AI judges might not be comparable."* — ibid.
- AI judges *"should be supplemented with exact evaluation, human evaluation, or both."* — ibid.
- Public benchmarks are *"likely contaminated, as their data is included in the training data of many models"*; they *"can help you weed out bad models, but won't help you find the best models for your applications."* — ibid.
- *"It's impossible to capture the ability of a high-dimensional system using one- or few-dimensional scores."* — ibid.
- Model selection is framed as *"creating a private leaderboard to rank models based on your needs."* — ibid.

**What `prompt-examples.md` contains** — six real production prompts contributed by their developers:
Brex (financial assistant), Cursor (task-or-not classifier), Grab (data entity classification),
Pinterest (text-to-SQL), Thoughtworks (product-ideation co-pilot), Whatnot (content moderation).
The headings `## Prompt attack examples` and `## Defensive prompt examples` exist with **no content
under them**; the file's own index marks both `Coming soon ...` — [prompt-examples.md](https://github.com/chiphuyen/aie-book/blob/main/prompt-examples.md)

**`resources.md` entries worth following up for this use case.** The file is organised by book chapter.
Mapped against the five areas asked about:

*Inference economics / cost (Ch. 9 section — the strongest section for this purpose):*
- Beyond Chinchilla-Optimal: Accounting for Inference in Language Model Scaling Laws — [arXiv 2401.00448](https://arxiv.org/abs/2401.00448)
- Optimizing AI Inference at Character.AI — [research.character.ai](https://research.character.ai/optimizing-inference/)
- Mastering LLM Techniques: Inference Optimization (NVIDIA) — [developer.nvidia.com](https://developer.nvidia.com/blog/mastering-llm-techniques-inference-optimization/)
- Transformer Inference Arithmetic — [kipp.ly](https://kipp.ly/transformer-inference-arithmetic/) · Transformer Math 101 — [blog.eleuther.ai](https://blog.eleuther.ai/transformer-math/)
- DistServe: Disaggregating Prefill and Decoding for Goodput-optimized LLM Serving — [arXiv 2401.09670](https://arxiv.org/abs/2401.09670)
- Accelerating LLM Decoding with Speculative Sampling — [arXiv 2302.01318](https://arxiv.org/abs/2302.01318)
- Techniques for KV Cache Optimization — [omrimallis.com](https://www.omrimallis.com/posts/techniques-for-kv-cache-optimization/)

*Evaluation methodology (Ch. 3–4 section):*
- Challenges in evaluating AI systems (Anthropic) — [anthropic.com](https://www.anthropic.com/news/evaluating-ai-systems)
- Holistic Evaluation of Language Models (HELM) — [arXiv 2211.09110](https://arxiv.org/abs/2211.09110) — the one entry that is genuinely about multi-metric, multi-scenario (i.e. per-stratum) evaluation
- Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena — [arXiv 2306.05685](https://arxiv.org/abs/2306.05685)
- LLM Task-Specific Evals that Do & Don't Work (Eugene Yan) — [eugeneyan.com](https://eugeneyan.com/writing/evals/)
- Your AI Product Needs Evals (Hamel Husain) — [hamel.dev](https://hamel.dev/blog/posts/evals/)
- Stop Uploading Test Data in Plain Text (benchmark contamination) — [arXiv 2305.10160](https://arxiv.org/abs/2305.10160)
- Siren's Song in the AI Ocean: Survey on Hallucination in LLMs — [arXiv 2309.01219](https://arxiv.org/abs/2309.01219)
- alopatenko/LLMEvaluation (meta-list) — [github.com](https://github.com/alopatenko/LLMEvaluation)

*Prompt engineering discipline:*
- How I think about LLM prompt engineering (François Chollet) — [fchollet.substack.com](https://fchollet.substack.com/p/how-i-think-about-llm-prompt-engineering)
- Larger language models do in-context learning differently — [arXiv 2303.03846](https://arxiv.org/abs/2303.03846) — the nearest thing in the whole repo to the few-shot-contamination question: it studies how larger models override semantic priors with in-context exemplars
- Brex's prompt engineering guide — [github.com/brexhq/prompt-engineering](https://github.com/brexhq/prompt-engineering)

*Guardrails / structured outputs / defensive prompting:*
- Llama Guard: LLM-based Input-Output Safeguard — [arXiv 2312.06674](https://arxiv.org/abs/2312.06674)
- The Instruction Hierarchy: Training LLMs to Prioritize Privileged Instructions — [arXiv 2404.13208](https://arxiv.org/abs/2404.13208)
- Not what you've signed up for: … Indirect Prompt Injection — [arXiv 2302.12173](https://arxiv.org/abs/2302.12173)
- A Guide to Structured Generation Using Constrained Decoding — [aidancooper.co.uk](https://www.aidancooper.co.uk/constrained-decoding/)
- Fast JSON Decoding with Compressed Finite State Machine (LMSYS) — [lmsys.org](https://lmsys.org/blog/2024-02-05-compressed-fsm/)
- How fast can grammar-structured generation be? (dottxt) — [blog.dottxt.co](https://blog.dottxt.co/how-fast-cfg.html)
- garak — [github.com/leondz/garak](https://github.com/leondz/garak/) · PyRIT — [github.com/Azure/PyRIT](https://github.com/Azure/PyRIT)
- OWASP AI Exchange security overview — [owaspai.org](https://owaspai.org/docs/ai_security_overview/#threat-model)

*Cascades / routing — the gap:* the only two entries anywhere near it are
Chameleon: Plug-and-Play Compositional Reasoning with LLMs — [arXiv 2304.09842](https://arxiv.org/abs/2304.09842)
and the Berkeley Function Calling Leaderboard — [gorilla.cs.berkeley.edu](https://gorilla.cs.berkeley.edu/leaderboard.html).
Both are about **tool selection**, not cost-tiered model cascades. OpenRouter's rankings
([openrouter.ai/rankings](https://openrouter.ai/rankings)) are listed, but under evaluation, not routing.

### Inferences

- ⬛ **Answering the task's framing directly: the repo IS mostly a reading list, and should be treated as one.** The substantive treatment of cascades, prompts-as-global-state, and few-shot leakage that the question anticipates is in the *book* (O'Reilly, 2025), not in the public repo. The repo will not be a source for it.
- The six production prompts in `prompt-examples.md` are the highest-value *original* artefact in the repo for a vision pipeline — Whatnot's content-moderation prompt and Grab's entity-classification prompt are both single-purpose classifier prompts with explicit output contracts, which is the shape a cascade stage wants.
- The two evaluation claims most transferable to a multi-stage vision pipeline are (a) an AI judge drifts, so it cannot double as a regression baseline, and (b) a single aggregate score cannot characterise a high-dimensional system. Both argue for a fixed, versioned, per-stratum regression corpus with exact (not judged) metrics wherever an exact metric exists — which, for ISBN identification, it does: the answer is a string that either matches or does not.
- `resources.md` has not been meaningfully updated since the book shipped; the inference-optimisation and evaluation sections skew 2023–2024. Treat it as a foundations bibliography, not a current-practice survey.

### Gaps

- I did not read the book itself, so I cannot confirm or deny that it covers prompts-as-global-state or few-shot leakage into outputs; I can only report that the public repo does not.
- `README.md` could not be reproduced verbatim (fetch declined on copyright grounds), so the file index above is from the GitHub tree API rather than the README's own description.

---

## Q2a. Qwen2.5-VL-7B-Instruct — licence and disclosed training data

### Takeaway

Apache 2.0, and the **model card discloses nothing at all about training data**. The technical report
does disclose a fair amount at the level of data *types* and *synthesis methods*, but names almost no
sources; notably, its pre-training data section **does not mention books at all** — document data is
described as synthesised. There is **no public finding that Qwen2.5-VL was trained on pirated books**;
the position is non-disclosure, which is a different thing.

### Cited Findings

- **Licence: `apache-2.0`**, stated on the model card — [huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct)
- The model card has **no training-data section whatsoever** — no datasets, sources, token counts, or provenance statements. It cites three earlier Qwen papers and YaRN, and reports benchmarks. — ibid.
- Technical report: **Qwen2.5-VL Technical Report**, Qwen Team / Alibaba — [arXiv 2502.13923](https://arxiv.org/abs/2502.13923), full text at [arxiv.org/html/2502.13923v1](https://arxiv.org/html/2502.13923v1)
- §2.2.1 Pre-Training Data: *"Our pre-training dataset was constructed through a combination of methods, including cleaning raw web data, synthesizing data."* — ibid.
- Corpus scale: grown *"from 1.2 trillion tokens to approximately 4 trillion tokens"*; Table 1 lists **4.1T trained tokens**; Table 2 splits it 1.5T visual pre-training / 2T multimodal / 0.6T long-context — ibid.
- Data **types** listed: image captions, interleaved image-text, OCR data, visual knowledge (celebrity / landmark / flora / fauna), multimodal academic questions, localization, document parsing, video descriptions, video localization, agent interaction — ibid.
- **Named sources** (the complete list in that section): **DataComp** (Gadre et al., 2023) *plus "some in-house datasets"* to initialise the vision encoder; **PixMo** (Deitke et al., 2024) for public pointing and counting data; **Grounding DINO** and **SAM** used to *synthesise* grounding data; **matplotlib / seaborn / plotly** to render ~1M synthetic chart samples; **OmniCorpus** cited for standard interleaved-data cleaning — ibid.
- **Document / OCR data:** document data is *synthesised*, with layouts rendered in HTML. OCR data comes from *"a visual text generation engine"*, a multilingual OCR dataset, and **6 million real-world table samples** filtered by an offline table-recognition model for low confidence, overlap and low cell density — ibid.
- ⬛ **Books / PDF corpora: not mentioned anywhere in the pre-training data section.** — ibid.
- Filtering: interleaved data passes a four-stage scoring system on text-only quality, image-text relevance, complementarity, and information-density balance — ibid.
- **No licensing or provenance statement** in the data section. It mentions *"open-source data"* for agent trajectories and *"publicly available and synthetic data"* for pointing. The **SFT** section separately refers to *"curated purchased datasets"* — unnamed third-party commercial data — ibid.
- **Provenance risk inherited via DataComp:** an audit of **DataComp CommonPool** by University of Washington and Carnegie Mellon researchers found personal information at scale — credit card numbers, passport numbers, and an estimated **142,000 images of individuals' resumes**; the curators' face-blurring tool is estimated to have **missed ~102 million images of real faces**; no filters were applied for PII strings such as emails. The audit sampled only 0.1% of the 12.8B-sample pool and extrapolates PII-bearing images into the hundreds of millions. The authors warn that *"downstream models trained on DataComp CommonPool may share problematic behavior, including the potential leakage of personally-identifiable information."* — [A Common Pool of Privacy Problems, arXiv 2506.17185](https://arxiv.org/html/2506.17185v1); secondary coverage at [CO/AI](https://getcoai.com/news/study-reveals-12-8b-image-ai-dataset-contains-millions-of-personal-documents/)

### Inferences

- ⬛ The precise status is **"not disclosed", not "known tainted"**. Alibaba has published more about Qwen2.5-VL's data than most closed labs publish, but it is a description of *methods and types*, not of *sources*. No court record, audit, or credible report places pirated book corpora in Qwen2.5-VL.
- The DataComp link is the most concrete, citable provenance concern — and note the honest caveat: the audit is of **CommonPool**, the raw 12.8B-sample pool, from which **DataComp-1B** is derived by filtering. The report says only "DataComp", so the exact subset used is unknown. This is a **privacy/GDPR** concern rather than a copyright one, but for a GDPR-by-default book platform it is the more relevant of the two.
- "Curated purchased datasets" in the SFT stage is the single least-traceable line in the report: purchased data has a contract behind it that a downstream user cannot see, and whose upstream provenance Alibaba itself may not have audited.
- For a book platform, the practically reassuring fact is that Qwen2.5-VL's pre-training section describes document data as *synthesised from HTML layouts*, not scraped from book scans. That is a weak signal (absence of mention is not absence of data) but it is the only signal available.

### Gaps

- Licences can differ per model size within a Qwen family; I verified `apache-2.0` for **Qwen2.5-VL-7B-Instruct** specifically and did not check 3B/72B. Verify per size before relying on it.
- The last ~8.7K characters of the Qwen2.5-VL HTML report were not read; a residual data statement could exist in the appendix.
- I found no third-party audit of Qwen2.5-VL's own training data (as distinct from DataComp's).

---

## Q2b. Qwen3-VL-4B — does it exist, and what does it disclose?

### Takeaway

Yes — Qwen3-VL-4B shipped **15 October 2025** under **Apache 2.0**, and its technical report
(**arXiv 2511.21631**, 27 Nov 2025) discloses **substantially more** than Qwen2.5-VL's did: named public
datasets, 3M Common Crawl PDFs, and — the one that matters here — an explicit mention of
**"book-scale interleaved data"**. The report says how those books were *processed*; it does **not** say
where they came from.

### Cited Findings

- **Family and release dates**, from the official repo's news section: 235B-A22B (2025-09-23), 30B-A3B (2025-10-04), **4B and 8B (2025-10-15)**, 2B and 32B (2025-10-21); each in Instruct and Thinking editions — [github.com/QwenLM/Qwen3-VL](https://github.com/QwenLM/Qwen3-VL)
- Abstract confirms the family: dense at **2B, 4B, 8B, 32B**, MoE at 30B-A3B and 235B-A22B — [arXiv 2511.21631](https://arxiv.org/abs/2511.21631)
- **Licence: `apache-2.0`** on the model card; the GitHub repo is also listed Apache-2.0 — [huggingface.co/Qwen/Qwen3-VL-4B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct); [github.com/QwenLM/Qwen3-VL](https://github.com/QwenLM/Qwen3-VL). One secondary aggregator (Codesota) instead labels it "Qwen License" — [codesota.com](https://www.codesota.com/model/qwen3-vl-4b) — which conflicts with both primary pages and is most likely a labelling error.
- **Model card discloses no training data** — no datasets, sources, token counts, provenance or filtering. Only *"Broader, higher-quality pretraining is able to 'recognize everything'"* — [huggingface.co/Qwen/Qwen3-VL-4B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct)
- **Technical report**: Qwen3-VL Technical Report, v2, 27 Nov 2025, 42 pages, 64 authors — [arXiv 2511.21631](https://arxiv.org/abs/2511.21631), full text [arxiv.org/html/2511.21631v2](https://arxiv.org/html/2511.21631v2)

**What §3.2 of the Qwen3-VL report actually discloses:**

- **Named public datasets:** COCO, Objects365, OpenImages, RefCOCO/+/g (grounding); **PixMo** (pointing and counting); Omni3D with ARKitScenes, Hypersim, SUN RGB-D (3D grounding) — ibid.
- **Web/PDF sources:** *"we collect 3 million PDFs from Common Crawl, evenly distributed across 10 document types"*, plus **4 million internal documents** for parsing; also *"recent Chinese and English websites"* — ibid.
- **OCR:** *"we curate a dataset of 30 million in-house collected samples using a coarse-to-fine pipeline"* (no human annotation), plus ~**30 million synthesised multilingual OCR samples** covering 29 additional languages — ibid.
- ⬛ **Books:** *"For book-scale interleaved data, we employ a fine-tuned Qwen2.5-VL-7B model"* for multimodal parsing, *"merging consecutive pages into sequences of up to 256K tokens"* for ultra-long-context training — ibid. **The report does not state the source of those books.**
- **Synthetic data:** a synthetic HTML corpus converted to Markdown for document parsing; 6M programmatically rendered diagram captions, 1M point-grounding samples, 2M perception VQA pairs; ~12M synthesised long-chain-of-thought multimodal reasoning samples; synthesised GUI trajectories, function-calling data and 3D captions — ibid.
- **Filtering:** a domain classifier removes *"advertisements, promotional content, and clickbait"*; caption deduplication by semantic similarity; rule-based and model-based verification plus rejection sampling for reasoning data — ibid.
- **Token counts (Table 1):** S0 alignment ~67B; S1 multimodal pre-training ~1T; S2 long-context ~1T; S3 ultra-long-context ~100B — ibid.
- **Vision encoder:** *"We utilize the SigLIP-2 architecture"*, *"initialized from official pretrained checkpoints"* and continually trained at dynamic resolution. Default SigLIP2-SO-400M; **SigLIP2-Large (300M) for the 2B and 4B models** — ibid.
- **No licensing or provenance statement.** Sources are described only generally: web, Common Crawl, open-source, internal — ibid.

### Inferences

- ⬛ **Qwen3-VL is the first model in this lineage to state on the record that it trained on book pages.** For a book platform this cuts both ways: it is exactly the capability you want (a model that has read many book interiors and covers will identify them better), and it is exactly the provenance you cannot verify. "Book-scale interleaved data" with no stated source is the single most important undisclosed item in either report.
- Still **"not disclosed", not "known tainted"** — there is no finding, audit or litigation placing Books3/LibGen/Z-Library/Anna's Archive in any Qwen model. Do not state otherwise.
- **The 4B is a different provenance profile from the 7B you run today.** Qwen2.5-VL's encoder came from DataComp (audited, PII-laden); Qwen3-VL-4B's comes from Google's SigLIP-2 checkpoint. Switching to the 4B swaps one undisclosed-upstream encoder for another, but moves away from the specific corpus with a published privacy audit against it.
- Disclosure quality improved markedly between the two reports. That is a real, if small, argument in the 4B's favour on provenance grounds, independent of the cost/latency case.

### Gaps

- **SigLIP-2's own training corpus** (Google's WebLI, as far as I know) is not documented in the Qwen3-VL report and I did not verify it against a Google source. That is the next link in the provenance chain for the 4B and remains unchecked here.
- Only the first 100K characters of the Qwen3-VL HTML were read; the remaining ~76K may contain further data statements or a data-licensing appendix.
- No technical report is linked from the Qwen3-VL-4B model card itself — the card links the text-only Qwen3 report (arXiv 2505.09388) and the older VL reports. A reader going by the model card alone would never find arXiv 2511.21631.

---

## Q2c. State of knowledge and litigation on pirated books in training sets (Nov 2026)

### Takeaway

Two US cases have now put shadow libraries squarely in the court record: Anthropic **settled for $1.5bn**
(final approval July 2026, first payments due mid-to-late November 2026) over *retained pirated copies*,
not over training itself; Meta **won** on fair use in June 2025 but on narrow grounds and now faces an
amended contributory-infringement claim over its BitTorrent seeding of LibGen. The EU AI Act's
training-data disclosure obligation became **enforceable on 2 August 2026** — and as of the first
enforcement-day audit, **only one Chinese provider (MiniMax) had published a summary at all**.

### Cited Findings

**Books3**
- Derived from the **Bibliotik** shadow library; included in EleutherAI's **The Pile**; used to train Meta's **LLaMA** and **BloombergGPT** — [TorrentFreak via Gizmodo](https://gizmodo.com/anti-piracy-group-takes-ai-training-dataset-books3-off-1850743763)
- Taken offline in **mid-July / August 2023** after the Danish anti-piracy group **Rights Alliance** sent a DMCA request to its host (The Eye); the original link now 404s — ibid.; [Gigazine](https://gigazine.net/gsc_news/en/20230821-books-3-ai-data-set)
- **Removal was not effective** — copies persist via the Internet Archive's Wayback Machine and mirror links — ibid.
- Bloomberg said it would not use Books3 for future BloombergGPT training — ibid.

**Bartz v. Anthropic** (N.D. Cal., 4:24-cv-05417-AMO)
- The court held that training on copyrighted books was fair use, but that **storing pirated copies was not** — [Authors Guild](https://authorsguild.org/advocacy/artificial-intelligence/what-authors-need-to-know-about-the-anthropic-settlement/)
- **$1.5bn settlement; final approval granted July 2026** by Judge Araceli Martínez-Olguín, who cut the named plaintiffs' service awards to **$15,000 each**, calling the original amounts unreasonable — [The Next Web](https://thenextweb.com/news/anthropic-1-5-billion-copyright-settlement-approved?type=AI); [Writer Beware](https://writerbeware.blog/2026/07/23/anthropic-settlement-update-final-settlement-approved/)
- Class counsel's **2 September 2026 status report**: the first scheduled payment of **$450 million was paid on 19 August 2026**; one remaining scheduled payment of **$450 million plus interest** outstanding; estimated **~$2,203.56 per work** net of fees; distributions to start by early November and **no later than 15 November 2026** — [status report PDF, dckt 688](https://blog.taaonline.net/wp-content/uploads/2026/09/2026-09-02-BartzAnthropicStatus-Report-dckt-688_0.pdf)
- The Authors Guild reports **initial payments to claimants going out the week of 23 November 2026** — [Authors Guild](https://authorsguild.org/advocacy/artificial-intelligence/what-authors-need-to-know-about-the-anthropic-settlement/)
- **Several appeals of final approval have been filed** — [Writer Beware](https://writerbeware.blog/2026/07/23/anthropic-settlement-update-final-settlement-approved/)
- Opt-out authors filed a **separate copyright suit in May 2026** demanding a jury trial — ibid.

**Kadrey v. Meta** (N.D. Cal., 3:23-cv-03417-VC)
- **Summary judgment for Meta on fair use, 25 June 2025** (*Kadrey v. Meta Platforms*, 788 F.Supp.3d 1026) — [Taft](https://www.taftlaw.com/news-events/law-bulletins/two-federal-judges-rule-in-separate-cases-that-training-ai-models-using-copyrighted-works-is-fair-use/)
- Judge Chhabria expressly narrowed it: the ruling *"does not stand for the proposition that Meta's use of copyrighted materials to train its language models is lawful. It stands only for the proposition that these plaintiffs made the wrong arguments and failed to develop a record in support of the right one."* — ibid.
- **March 2026:** the court allowed plaintiffs to amend to assert **contributory infringement based on Meta's use of BitTorrent** (i.e. seeding pirated books while downloading them) — [Polsinelli / NatLawReview](https://natlawreview.com/article/ai-vs-authors-update-court-approves-historic-anthropic-settlement-while-meta)
- **8 June 2026:** plaintiffs moved to certify the 2025 partial summary judgment for **interlocutory appeal to the Ninth Circuit**; Meta opposed; **no ruling found** as of this research — [chatgptiseatingtheworld.com](https://chatgptiseatingtheworld.com/2026/06/09/kadrey-asks-judge-chhabria-to-certify-for-interlocutory-appeal-to-9th-circuit-the-judges-2025-summary-judgment-re-metas-downloading-from-shadow-libraries-for-the-purpose-of-ai-training/)
- The fair-use ruling binds only the **13 named plaintiffs** — [AI copyright update, Nov 2026](https://www.nortonrosefulbright.com/en/knowledge/publications/ce8eaa5f/ai-in-litigation-series-an-update-on-ai-copyright-cases-in-2026)

**Wider US litigation, as of mid-November 2026**
- **OpenAI/Microsoft (SDNY, Judge Stein):** 56 amicus briefs admitted **6 November 2026**; the court intends to rule on fair use for AI training **on summary judgment, without a trial**; replies due **20 November 2026** — [aimatterin.substack.com](https://aimatterin.substack.com/p/new-turn-in-openai-copyright-lawsuit)
- **xAI/Grok:** three copyright suits from two publishers and a group of authors over alleged use of pirated books, reported **6 November 2026** — [Law360](https://www.law360.com/technology/articles/2547420)
- A separate suit (*Carreyrou et al.*) by high-profile Bartz opt-outs names several AI companies including xAI and Perplexity — ibid.
- Volume: trackers disagree — one counts **72 AI copyright suits filed in 2026 (65 active)** ([ailawsuittracker.com](https://ailawsuittracker.com/copyright/2026/)), another **113 of 127 pending as of 8 October 2026** ([axis-intelligence.com](https://axis-intelligence.com/ai-copyright-lawsuits-tracker/)). ⚠️ Both are secondary aggregators of unclear editorial quality; treat the numbers as indicative only.

**EU AI Act — Article 53(1)(d) training-content summary**
- The AI Office published the **mandatory template on 24 July 2025**; providers of GPAI models must publish a *"sufficiently detailed"* public summary of training content using it — [European Commission](https://digital-strategy.ec.europa.eu/en/news/commission-presents-template-general-purpose-ai-model-providers-summarise-data-used-train-their)
- The template is **binding**, unlike the Guidelines and the GPAI Code of Practice — [Mayer Brown](https://www.mayerbrown.com/en/insights/publications/2025/08/eu-ai-act-news-rules-on-general-purpose-ai-start-applying-guidelines-and-template-for-summary-of-training-data-finalized)
- Obligations apply from **2 August 2025** to all GPAI providers, **proprietary and open-source alike**; models already on the market before that date have until **2 August 2027** — ibid.; [WilmerHale](https://wilmerhale.com/en/insights/blogs/wilmerhale-privacy-and-cybersecurity-law/european-commission-releases-mandatory-template-for-public-disclosure-of-ai-training-data)
- **Commission enforcement powers began 2 August 2026** — ibid.
- The template's largest section *"requires providers to detail specific sources of data used to train the GPAI model"* — [Shoosmiths](https://www.shoosmiths.com/insights/articles/ai-confessions-what-your-model-did-last-summer)
- ⚠️ A penalty cap of the greater of €15M or 3% of turnover is reported by one blog but was not verified against the Act text — [pebblous.ai](https://blog.pebblous.ai/blog/eu-training-data-summary-gap/en/)

**Actual compliance, measured on enforcement day**
- The **AI Accountability Lab (Trinity College Dublin)**, post dated **7 August 2026**: **39 public summaries found, 38 evaluated, 20 models considered missing a summary** (excluding those whose obligations start in 2027) — [aial.ie](https://aial.ie/research/gpai-training-transparency/blog/003-enforcement-day)
- ⬛ *"We could find only one Chinese AI model provider's published summary (MiniMax)."* The post names **DeepSeek, Alibaba, Baidu, Tencent, Xiaomi and Huawei** as having recently released models, **none of which it reports as having a summary** — ibid.
- Quality problems among those who did file: **xAI's** Grok summary does not mention CSAM removal; **Mistral** did not give its crawler identifier; **OpenAI** has a summary for one GPT-5.6 variant but not the other; **Google** covers whole families in one document — ibid.
- A French-language report frames it as Beijing keeping Qwen's and DeepSeek's training data sealed while the AI Act demands it — [actuia.com](https://www.actuia.com/actualite/qwen-et-deepseek-pekin-scelle-leurs-donnees-dentrainement-lai-act-les-reclame/) (⚠️ headline-level only; body not read)

**China's own regime**
- The **Interim Measures for the Management of Generative AI Services**, issued by the CAC and six other departments on **10 July 2023**, apply to services offered to the public in China and **exclude non-public R&D** — [Bird & Bird](https://www.twobirds.com/en/insights/2023/china/what-you-need-to-know-about-china’s-new-generative-ai-measures)
- The draft contained an explicit clause requiring description of *"the sources, scale, types, and quality"* of pre-training data; **the final rules are narrower** — providers must supply the **source, scale and type of training data, labelling rules and algorithmic mechanism to regulators** and support inspections — ibid.; [Conventus Law](https://conventuslaw.com/report/what-you-need-to-know-about-chinas-new-generative-ai-measures/)
- Providers must *"ensure the legality of the sources"* of pre-training and optimisation data and take *"effective measures to improve the quality of training data"* — ibid.
- ⚠️ A single low-quality aggregator claims the framework expanded in **April 2026** to require disclosure of core training-data sources and model architectures at CAC registration; **no official CAC text confirms this** — [techjacksolutions.com](https://techjacksolutions.com/?p=44693). Do not rely on it.

### Inferences

- ⬛ **The distinction the reader asked for, stated plainly:** Anthropic (Books3/LibGen, admitted and settled) and Meta (LibGen via BitTorrent, in the court record) are *known* to have ingested pirated books. Alibaba's Qwen models are *undisclosed*. There is no evidence placing them in the first category, and treating non-disclosure as proof of piracy would be wrong.
- The legal centre of gravity has moved from *"is training fair use?"* to *"how did you obtain the copy?"*. Alsup's split in Bartz — training lawful, pirate-library retention not — is the rule that produced a $1.5bn settlement, and Kadrey's amendment to contributory infringement over BitTorrent *seeding* follows the same logic. Acquisition method, not training, is the exposed surface.
- **This matters very little to a downstream user of open weights.** Both theories attack the *trainer's acquisition and retention* of copies. A person running released weights has copied no books and seeded no torrents.
- China's regime is a **regulator-facing disclosure duty, not a public one**, and it expressly exempts non-public R&D. So there is no mechanism by which a self-hosting foreign developer could obtain Qwen's data manifest, even in principle, under Chinese law.
- The EU AI Act *is* in principle that mechanism — it binds any provider placing a GPAI model on the EU market, including open-source. But the enforcement-day audit shows Chinese providers have essentially not engaged with it. Whether the Commission acts against a provider with no EU establishment is the open question, and the first enforcement outcome will be the signal worth watching.
- ⚠️ Nothing in the EU regime creates a duty or a liability for a **downstream self-hoster**; Article 53 obligations sit on the *provider* of the GPAI model.

### Gaps

- I could not confirm from a primary docket that Bartz payments actually went out; the latest hard evidence is a September 2026 forecast plus an Authors Guild statement. Court docket 4:24-cv-05417-AMO (N.D. Cal.) is the authority.
- No ruling found on the Kadrey interlocutory-appeal certification motion (docket 3:23-cv-03417-VC).
- No enforcement action or fine under EU AI Act Article 53 was found; enforcement powers exist since 2 Aug 2026 but I found no case.
- I found **no 2026-specific reporting on Books3** at all — the coverage is all 2023. Whether the dataset is still in active circulation in 2026 is unestablished.
- I did not locate an Alibaba EU training-content summary, but I also did not check Alibaba Cloud's own EU compliance pages directly. Absence from a third-party audit is suggestive, not conclusive.

---

## Q2d. What can a downstream user actually do?

### Takeaway

**Apache 2.0 gives you permissive use and explicitly no indemnity** — indemnity is a paid-hosted-API
feature, and self-hosting trades it away. The genuinely documented-corpus alternatives exist
(Common Pile, OLMo, Molmo/PixMo) but **none is a drop-in VLM replacement at this quality and size**, and
the only one with open *vision-language* training data — Molmo — is open in its fine-tuning data while
its backbones are not. For a solo developer the realistic posture is **informed acceptance plus
architectural containment**, not model substitution.

### Cited Findings

- **Self-hosted open weights carry no provider indemnification.** Cooley (12 Aug 2026): self-hosted open-weight deployments *"may lack provider indemnification or related contractual and technical protections"*, both for infringing outputs and more broadly; open-weight models *"also raise IP questions that courts and regulators are still working through"* — [Cooley](https://www.cooley.com/news/insight/2026/2026-08-12-unlocking-the-weights-what-enterprises-should-know-before-deploying-open-weight-ai-models)
- Open-weight licences, *"including MIT-style and Apache 2.0 licenses, broadly disclaim warranties and liability"* — and this *"does not necessarily mean the model infringes more"* — [Vondran Legal](https://www.vondranlegal.com/open-vs-closed-ai-models-understanding-the-copyright-risks-for-businesses-deploying-artificial-intelligence)
- One vendor-side guide states flatly that **no open-weight licence indemnifies you for outputs or infringement claims**, and that **indemnity is a paid-API feature some cloud providers offer** — [llmconfigurator.com](https://llmconfigurator.com/en/enterprise/open-llm-licenses-for-business) ⚠️ vendor source; directionally consistent with Cooley but stated more absolutely
- With open-weight models *"there's typically no visibility into training data"* — [Reed Smith](https://www.reedsmith.com/our-insights/blogs/viewpoints/102ne55/whos-liable-if-your-ai-model-generates-infringing-content-it-can-depend-on-whic/)

**Documented / audited-corpus options**

- **The Common Pile v0.1** (EleutherAI et al., NeurIPS 2025): an **8TB dataset of public-domain and openly licensed text** from **30 sources**, built specifically *"to address legal and ethical concerns about training on unlicensed web content"*. Every source had to meet the **Open Definition 2.1** — CC BY, CC BY-SA, CC0, or permissive software licences like MIT/BSD — with per-document metadata requirements including authorship or IP ownership. Models released: **Comma v0.1-1T** and **v0.1-2T** — [blog.eleuther.ai/common-pile](https://blog.eleuther.ai/common-pile/); [the-decoder](https://the-decoder.com/researchers-build-massive-ai-training-dataset-using-only-openly-licensed-sources/)
- Common Pile's limitations are acknowledged by its own authors: personal stories, blogs and non-English text are *"still missing or underrepresented"*, and results were weaker on everyday-language tasks than on scientific and programming tasks — ibid. **It is text-only.**
- **OLMo (Ai2)** is *"released under an Apache-2.0 license along with all training data, training/evaluation/adaptation code, checkpoints, training logs, and more"* — [Cameron Wolfe](https://cameronrwolfe.substack.com/i/141461162/the-evaluation-process). ⚠️ EleutherAI characterises OLMo's **Dolma** corpus as *"ODC-BY collection license, but three of four main components are proprietary — insufficient for our purposes"*; that is a partisan assessment from a competing project. **Also text-only.**
- **Molmo + PixMo (Ai2)** — *Molmo and PixMo: Open Weights and Open Data for State-of-the-Art Vision-Language Models*, CVPR 2025 oral — [arXiv 2409.17146](https://arxiv.org/abs/2409.17146); [github.com/allenai/molmo](https://github.com/allenai/molmo)
  - Released model weights **and** vision-language training data *"without any reliance on synthetic data from other VLMs, including proprietary ones"* — ibid.
  - The caption data was collected **from human speech**, with *"an audio receipt to show no VLM was used"* for each description — ibid.
  - Datasets: **PixMo-Cap** (pre-training and fine-tuning), **PixMo-AskModelAnything** (instruction tuning), **PixMo-Count**; *"All datasets were constructed without the use of VLMs"* — ibid.
  - ⬛ The authors describe a *separate, planned* **"100% fully open" Molmo** on a **MetaCLIP** encoder and **OLMo** LLM *"for which every bit of training data is publicly available"* — i.e. the headline Molmo releases are **not** fully open in that sense; their backbones carry third-party provenance — ibid.
  - **Licence not confirmed** in my sources — the GitHub page shows a badge whose terms the search result did not surface.

### Inferences

These are reasoned conclusions, not sourced claims. Flagged as such.

- **There is currently no open-weight VLM with genuinely documented end-to-end training data at Qwen2.5-VL-7B quality.** Molmo is the closest, and its openness covers the *vision-language* data, not the LLM backbone or (in the shipped models) the vision encoder. That is a real improvement in auditability and still not a clean chain.
- **Indemnity is not purchasable at this budget.** The vendors that indemnify (hosted APIs) charge per token and would not be self-hostable on Modal; the models that are self-hostable disclaim liability by licence. For a $50/month self-hosted pipeline the indemnity option does not exist, so it should be struck from the decision rather than agonised over.
- ⬛ **The exposure for this specific use case is unusually low, and that is the most useful finding.** The copyright theories that have actually produced liability attack *acquisition and retention of pirated copies by the trainer*. A downstream user of released weights has acquired nothing and retains nothing. And the pipeline's output is **an ISBN verified against Open Library or Google Books** — an identifier, not generated prose. A model cannot infringe a book by correctly naming it. The infringement surface of a generative book-identification pipeline is close to nil, which is not true of, say, a summarisation or writing-assistant stage over the same corpus.
- **The live risk is privacy, not copyright, and it is the DataComp finding.** A model whose encoder was initialised on a corpus with hundreds of millions of PII-bearing images, run over reader-uploaded photographs, is the concern that actually touches this project's GDPR posture. It argues for keeping the existing retention discipline (~24h for the photograph, 30 days for the record) and for never letting a raw VLM transcription of a photograph land in `event_log` or the warehouse — a photographed bookshelf can contain a passport on the shelf beside the books.
- **Practical ranking for a solo developer, cheapest first:**
  1. **Record the position.** Write down, per model, licence + what the report does and does not disclose, with the arXiv section cited. This is the whole of "due diligence" at this scale, and it is 20 minutes of work. It also converts an unbounded worry into a dated artefact.
  2. **Prefer the model with better disclosure when other factors tie.** Qwen3-VL's report names sources; Qwen2.5-VL's does not. That is a tiebreaker, not a reason to migrate on its own.
  3. **Contain architecturally.** Verify every generative output against an external authority (already the ISBN hard gate); never surface raw model text as content; keep image retention short. This neutralises more risk than any model choice.
  4. **Watch one signal, not the whole field:** the first EU AI Act Article 53 enforcement action against a non-EU provider. If the Commission moves on a Chinese lab, disclosure improves across the board; if it does not, non-disclosure is the stable equilibrium and no amount of waiting will produce a manifest.
  5. **Do not migrate to an open-data model for provenance reasons.** At this quality tier it would cost accuracy on the core task for a legal benefit that does not accrue to a downstream self-hoster.

### Gaps

- **Molmo's licence terms** (weights and PixMo datasets) were not confirmed; check the Hugging Face model and dataset cards directly before treating it as a usable option.
- I did not benchmark Molmo or any open-data VLM against Qwen2.5-VL-7B on book-spine/cover identification, so "quality tier" above is an assumption, not a measurement. The eval corpus in this repo could settle it cheaply.
- Whether any hosted inference provider offers IP indemnification *for open-weight models they serve* (as opposed to their own) was not established; the sources cover first-party models.
- All of Q2d's legal sourcing is law-firm, consultancy and vendor commentary rather than primary legal text. The Apache 2.0 licence's own §7 (warranty disclaimer) and §8 (limitation of liability) are the primary text and should be read directly — it is two paragraphs.
- ⬛ **None of this is legal advice and none of the sources are a substitute for counsel.** Flagged because the reader explicitly has no legal team.
