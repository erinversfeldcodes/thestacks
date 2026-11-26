# Constructing a training set for cover identification from reader photographs

Scope note: every number below is from a published source with a URL, except where a line is
explicitly marked as an inference or an assumption. Where a source conflicts with itself or with
another source, that is said in the line rather than silently resolved. The hard constraint —
**no real user uploads, ever, as training or evaluation data** — is treated as fixed, and the
literature is read for what it says about building from owner-authored, synthetic and
openly-licensed material only.

---

## Q1. How do practitioners bridge a clean-render → photograph gap? Evidence from analogous domains

### Takeaway

Four mature analogous domains — museum artwork recognition, retail shelf recognition,
street-to-shop fashion retrieval, and mobile book-cover search — all solve exactly this problem,
and all four converge on the same shape: **train the embedding on the clean catalogue side only,
synthesise the photographic variation, and never require a photograph of every class.** The
measured absolute accuracy on photographic queries is far below same-domain retrieval — roughly
50–85% top-1 depending on index size — so the gap is bridgeable but not closable.

### Cited Findings

**Museum artworks (the closest structural analogue: 224k classes, catalogue training, visitor-photo queries)**

- The Met dataset is built from ~397,121 studio-condition exhibit images covering ~224,408 classes
  (one class per exhibit); testing is on ~20k query images, the Met-related ones being photographs
  taken by 39 museum visitors. 60.8% of classes have exactly one training image. 81.5% of Met query
  images are the only query for their class — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747); [NeurIPS 2021 listing](https://neurips.cc/virtual/2021/poster/29905)
- The authors state the design intent plainly: training is studio-quality, "testing is primarily
  performed on photos taken by museum guests depicting exhibits, which introduces a distribution
  shift between training and testing" — [NeurIPS abstract](https://neurips.cc/virtual/2021/poster/29905)
- Off-the-shelf descriptors on visitor-photo queries (kNN, GAP / GAP- / ACC):
  R18 ImageNet 15.9 / 37.5 / 42.3; R50 ImageNet 22.2 / 41.8 / 46.4; R50 SwAV 22.8 / 45.0 / 49.6;
  R18 SWSL 24.7 / 47.0 / 50.9; R50 SWSL 30.4 / 52.9 / 56.3. Local descriptors (HOW + ASMK)
  25.3 / 47.6 / 50.9 — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- Training contrastively **on the clean catalogue images alone**, with no photographs in training at
  all, lifts R18 ImageNet from 15.9 to 32.5 GAP and the best configuration (R18 SWSL +
  Con-Syn+Real-closest) to 36.1 GAP / 55.0 ACC — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- Parametric classifiers do markedly worse than metric learning + kNN on this task: ArcFace
  16.9 GAP / 36.6 ACC and plain cross-entropy 9.6 / 30.6, versus 32.5 / 50.0 for the contrastive
  kNN variant on the same backbone — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)

**Retail shelf product recognition (one clean packshot per SKU, photographic queries)**

- Tonioni et al. use a class-agnostic detector plus kNN against descriptors computed from **one
  reference image per product**; new products are added by inserting a descriptor, with no
  retraining. The embedder was fine-tuned on ~3,288 reference images (one each), and evaluated
  against 680 in-store query images — [arXiv 1810.01733](https://arxiv.org/pdf/1810.01733)
- Results: learned descriptors alone 27.84% mAP versus 21.49% for a general descriptor; the full
  pipeline reaches 36.02% mAP / 57.07% precision-recall in the "customer" scenario, and
  76.93% mAP / 85.71% PR in the easier "management" scenario (70 queries, 182-product database).
  Scaling the database to ~3,200 products gives 73.50% mAP / 82.66% PR. The paper's prose quotes
  84.75% PR for the management setting, which conflicts with its own table's 85.71% —
  [ar5iv 1810.01733](https://ar5iv.arxiv.org/html/1810.01733)
- The DIHE paper (Tonioni & Di Stefano, 2019) attacks the render→photo gap directly with an
  unpaired GAN that restyles studio reference images into in-store appearance. On Grocery Products
  with a **small randomly-initialised encoder**, 1-NN accuracy goes
  0.301 → 0.454 (Grocery_Food), 0.277 → 0.418 (Grocery_Full), 0.351 → 0.512 (Product8600) —
  roughly doubling — [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- ⚠️ The same paper shows the win **collapses when a strong pretrained backbone is used**. With
  VGG-16: triplet-only 0.799 / 0.775 / 0.765 → +GAN 0.829 / 0.821 / 0.816 (i.e. +0.030 / +0.046 /
  +0.051) → full DIHE 0.853 / 0.842 / 0.827. An untuned MAC descriptor already scores
  0.792 / 0.787 / 0.725 — [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- Datasets: Grocery Products has >8,400 products with exactly one reference image each and 680
  (DIHE reports 938) in-store queries; Product8600 has 8,597 references and 273 in-store queries —
  [arXiv 1810.01733](https://arxiv.org/pdf/1810.01733); [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)

**Street-to-shop fashion (professional shop photo ↔ uncontrolled street photo)**

- "Where to Buy It" defines Exact Street2Shop over 404,683 shop photos from 25 retailers and 20,357
  street photos; shop photos are "captured by professionals in more controlled settings" while
  street photos are uncontrolled — [Kiapour et al., ICCV 2015](https://openaccess.thecvf.com/content_iccv_2015/html/Kiapour_Where_to_Buy_ICCV_2015_paper.html); [PDF](https://tamaraberg.com/papers/street2shop.pdf)
- A later single detect-then-retrieve model reports outperforming domain- and category-specific
  models "by significant margins" on the same benchmark — [Kucer & Murray, CVPRW 2019](https://openaccess.thecvf.com/content_CVPRW_2019/papers/FFSS-USAD/Kucer_A_Detect-Then-Retrieve_Model_for_Multi-Domain_Fashion_Item_Retrieval_CVPRW_2019_paper.pdf)

**Book covers specifically — the one paper that is exactly our problem**

- Shih et al. match mobile phone photographs of book covers against clean catalogue covers: 404
  queries over 101 titles (from the Stanford Mobile Visual Search set) plus **104,132 distractor
  covers taken from openlibrary.org** — [arXiv 1411.5307](https://arxiv.org/pdf/1411.5307)
- Top-1 retrieval, **no distractors**: OCR character-3-gram 0.65, VLAD-on-SURF 0.68, learned
  combination (rankSVM) 0.84, plus RANSAC/HOG reranking of the top 15 → 0.94 —
  [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)
- Top-1 with ~104k distractors: OCR 0.31, VLAD **0.18**, combined 0.60, combined + reranking 0.67.
  Visual matching degrades far more severely with index size (0.68 → 0.18) than text matching
  (0.65 → 0.31) — [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)
- Their stated reasons the match is hard: off-the-shelf OCR assumes horizontal text while query text
  is at arbitrary angle and scale; specularities, distortions, occlusions and background text add
  noise; and VLAD "tends to match covers with similar visual patterns" — the two modalities fail
  differently, which is why combining them helps — [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)

**Current (2025–26) foundation-model baselines on cross-condition instance retrieval**

- ILIAS evaluates frozen backbones for instance-level retrieval: 1,000 object instances, 1,232
  queries on "clean or uniform background", 4,715 positives showing the same objects "in real-world
  conditions, including clutter, occlusions, scale variations, and partial views", plus 100M
  YFCC100M distractors — [ILIAS project page](https://vrg.fel.cvut.cz/ilias/)
- mAP@1k, image-to-image, no adaptation, at 5M / 100M distractors: DINOv3-L 31.1 / 26.5;
  PE-L@336 27.1 / 22.0; DINOv3-B 26.4 / 22.0; SigLIP2-L@512 25.3 / 20.8; SigLIP-L@384 24.2 / 19.6;
  DINOv2-L 18.5 / 15.3; Unicom-L 18.0 / 13.8; OpenAI CLIP-L@336 12.1 / 9.4; supervised ResNet50
  2.3 / 1.7 — [ILIAS project page](https://vrg.fel.cvut.cz/ilias/)
- Re-ranking matters a great deal at scale: AMES + adapted SigLIP over the top-10k reaches 38.9
  mAP@1k at 100M, with an oracle re-ranking ceiling of 56.0 — [ILIAS project page](https://vrg.fel.cvut.cz/ilias/)

### Inferences

- The **dominant architecture across all four domains is identical** and should be the default here:
  class-agnostic detection/segmentation of the object, then a learned global descriptor compared by
  kNN against one-or-few clean catalogue references per class, then a geometric or local-feature
  re-ranking step over the shortlist. None of them trains a classifier over the catalogue.
- The Met result is the single strongest evidence that the hard ethical constraint is survivable:
  **a 224k-class cross-domain recogniser was trained with literally zero photographs in the training
  set and still answers visitor photographs at 55% top-1.** Photographs were needed only to measure.
- The 2014 book paper's distractor collapse (VLAD 0.68 → 0.18 at 104k) is the most important
  single number in this file for architecture choice. The Stacks' index will be far larger than
  104k editions. An evaluation corpus of 122 photographs with no distractor index cannot detect this
  failure mode at all, because the failure is a function of index size, not photograph quality.
- DIHE's collapse from +0.153 to +0.030 when the backbone is pretrained predicts that in 2026, with
  DINOv3/SigLIP2 available frozen, the marginal value of an elaborate photo-simulation pipeline is
  much smaller than the 2019 literature implies. Budget accordingly: measure the frozen baseline
  before building a renderer.

### Gaps

- I found no published book-cover retrieval benchmark with modern (post-2020) descriptors at
  realistic index scale. The 2014 Shih et al. numbers are the best book-specific evidence available
  and use SURF/VLAD and pre-deep OCR, so they bound the *shape* of the problem, not its current
  difficulty.
- ILIAS leaderboard results for DINOv3 on book-like flat printed objects specifically are not broken
  out; ILIAS is multi-domain and I could not isolate a printed-matter slice.

---

## Q2. Can photographs be convincingly simulated from flat renders? Which transforms matter, and what is the residual gap?

### Takeaway

The published evidence is more equivocal than the question assumes. **Generic augmentation of clean
catalogue images produces most of the measured gain — and that gain comes from learning the
fine-grained catalogue domain, not from looking photographic.** Explicit photographic effects
(glare, warp) have their own literatures with real but modest and sometimes negative results, and
the best document-domain work found purely synthetic appearance insufficient and added a small real
captured set.

### Cited Findings

**The strongest quantified decomposition available (The Met)**

- "Con-Syn" trains contrastively where each anchor's positive is an augmented copy of itself. The
  augmentations are only: random crop (scale 0.7–1.0, resized to 500×500), colour jitter with
  p=0.8, and grayscale with p=0.2 — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- Ablation on visitor-photo queries (GAP / GAP- / ACC): R18 ImageNet baseline 15.9 / 37.5 / 42.3 →
  Con-Syn 30.4 / 46.6 / 49.4 → Con-Syn+Real 29.8 / 46.0 / 48.8 → Con-Syn+Real-closest
  32.5 / 47.5 / 50.0. R18 SWSL 24.7 → 36.1 GAP with the best variant —
  [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- ⚠️ "Real" here means *other catalogue images of the same exhibit* (different views/lighting), not
  visitor photographs — 60.8% of classes have only one image, so those always fall back to
  augmentation — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- ⚠️ Naively adding those extra real same-class views **hurt** (29.8 < 30.4). They only helped when
  the positive was chosen as the *most embedding-similar* same-class image (32.5). The authors'
  stated reason is to avoid pairing completely different views of the object —
  [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)

**Explicit photographic-effect simulation: mixed and sometimes negative evidence**

- Specular highlights: an ICCV 2023 workshop paper generated Gaussian specular highlights at varying
  location and size over ImageNet to build ImageNet-AH, found they fool classifiers, and reported
  that **fine-tuning on the specular images "did not improve performance enough"** —
  [Vats et al., ICCVW 2023](https://openaccess.thecvf.com/content/ICCV2023W/AROW/papers/Vats_Adversarial_Examples_with_Specular_Highlights_ICCVW_2023_paper.pdf)
- SHDocs (NeurIPS 2024) released a glare-on-documents dataset with "near-perfect alignment" aimed at
  OCR and detection, and claims models trained on it surpass state-of-the-art highlight removal and
  improve downstream OCR — [NeurIPS 2024](https://proceedings.neurips.cc/paper_files/paper/2024/hash/af9199ef7d5ff267451a667170124c04-Abstract.html)
- Geometric warp: Doc3D is the standard synthetic source for document dewarping; UVDoc was built
  **because Doc3D's appearance is unrealistic**, its authors noting that rendering photorealistic
  paper is hard and 3D scans are noisy, and training on Doc3D **plus** UVDoc gave state-of-the-art
  DocUNet results for most criteria — [UVDoc, arXiv 2302.02887](https://arxiv.org/html/2302.02887v2)
- DocReal rebuilt Doc3D samples with added 3D deformations and noise augmentation specifically to
  close the gap to "real-life images" — [DocReal, WACV 2024](https://openaccess.thecvf.com/content/WACV2024/papers/Yu_DocReal_Robust_Document_Dewarping_of_Real-Life_Images_via_Attention-Enhanced_Control_WACV_2024_paper.pdf)
- A 2026 preprint proposes path-traced rendering (Blender Cycles) with physics-based bending/folding
  and per-pixel albedo/shading/normal/UV annotations, but the page I read did not show a matched
  comparison against Doc3D+UVDoc, so its real-photo advantage is not demonstrated —
  [SyntheticDoc preprint](https://www.alphaxiv.org/abs/2609.15503)
- Learned restyling beats hand-written transforms when the backbone is weak: DIHE's GAN
  (trained with **547 unlabelled real shelf crops**, no identity labels, disjoint from the 938 query
  images) gave +0.153 with a small encoder, +0.030 with VGG-16 —
  [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- Hand-written transforms in the shelf pipeline were deliberately modest: Gaussian blur with random
  σ, random crop, random brightness, random saturation. Notably **no perspective warp, no glare, no
  occlusion** — and the paper provides no ablation isolating the augmentation's contribution —
  [ar5iv 1810.01733](https://arxiv.org/pdf/1810.01733)

### Inferences

- ⛔ **The Met's 15.9 → 30.4 jump is not evidence that photo-simulation works.** Crop + colour
  jitter + grayscale do not simulate perspective, glare, shadow, occlusion or blur. The gain is
  from teaching the backbone to discriminate *this catalogue's* fine-grained instances at all. The
  correct reading is: the first and largest win available is domain-specific contrastive training on
  the clean catalogue, which costs zero photographs and zero annotation, and is independent of any
  renderer. Build that first and measure before writing a single line of glare simulation.
- The residual gap attributable to photographic realism is bounded by the Met's own numbers at
  roughly +2.1 GAP (30.4 → 32.5 from better positive selection) and by DIHE at +0.030 1-NN with a
  pretrained backbone. Both are small. A renderer that costs weeks to build is being asked to beat
  a few points.
- The transforms with published support, ranked by evidence strength: (1) crop/scale and colour
  jitter — directly ablated and large; (2) learned unpaired restyling from a few hundred unlabelled
  real photographs — directly ablated, +0.030 with a strong encoder; (3) geometric warp — strong
  support in the document literature but only in combination with real captured data; (4) specular
  highlight simulation — one paper reports it is insufficient as a fine-tuning signal, one claims
  success without numbers I could verify. Moiré, halftone and JPEG artefacts: **I found no paper
  quantifying their contribution to cross-domain cover or product retrieval.**
- A book cover is physically closer to a *document* than to a museum object: flat, printed, often
  laminated, held in the hand. The document-dewarping literature is therefore the right source for
  the geometric half of the renderer, and its verdict is explicit — synthetic appearance alone was
  judged unrealistic by the people who tried hardest, and the fix was adding a modest set of real
  captures.

### Gaps

- SHDocs' actual quantified OCR improvement could not be retrieved; the NeurIPS abstract page gives
  no numbers. Treat the claim as unverified.
- I found no study quantifying moiré or print-halftone simulation for retrieval or recognition. The
  demoiréing literature exists but targets restoration, not recognition transfer.
- UVDoc's real-capture set size (the "how much real" figure for the document analogue) was not in
  the pages I read.

---

## Q3. How much real photographic data is needed alongside synthetic?

### Takeaway

Across four independent domains the answer clusters tightly: **real data needs to be about 5–20% of
a mixed training set, and the first ~5% delivers most of the benefit.** But for a cross-domain
retrieval system with a catalogue-sized class count, there is a stronger result available — several
systems used *zero* identity-labelled photographs and only a few hundred *unlabelled* real
photographs, used purely to characterise the photographic domain.

### Cited Findings

- Object detection: the largest reduction in required real examples came with real data at roughly
  **5% to 20%** of a mixed training set — [arXiv 2202.00632](https://arxiv.org/pdf/2202.00632)
- Optical chemical structure recognition: in a 3×6 sweep over real-data fractions, **the first 5% of
  real data supplied about two-thirds of the total gain** observed between 0% and 70% real, for each
  pretrained base — [arXiv 2608.09100](https://arxiv.org/pdf/2608.09100)
- Domain randomization for car detection (KITTI, AP@0.5): synthetic-only DR 78.1 (Faster R-CNN),
  71.5 (R-FCN), 46.3 (SSD); Virtual KITTI 79.7 / 64.6 / 36.1. Synthetic pretraining **plus** real
  fine-tuning on all 6,000 real images reaches **98.5**, which the paper reports as 2.1 points above
  real-only training (implying ≈96.4 real-only) and 1.6 above VKITTI-pretrained. With COCO
  initialisation: COCO only 56.1; COCO+VKITTI 79.7; COCO+DR 83.7 —
  [Tremblay et al., ar5iv 1804.06516](https://ar5iv.labs.arxiv.org/html/1804.06516)
- Scene text recognition — the cleanest synthetic-to-real ratio in the literature: pooled public
  **real** labelled data of **276K images, about 1.7% of the 16M synthetic images** used by
  then-SOTA methods, trained STR models satisfactorily; CRNN on real data matched its
  synthetic-trained counterpart and TRBA on real data **surpassed** it —
  [Baek et al., CVPR 2021](https://openaccess.thecvf.com/content/CVPR2021/html/Baek_What_if_We_Only_Use_Real_Datasets_for_Scene_Text_CVPR_2021_paper.html); [arXiv 2103.04400](https://arxiv.org/abs/2103.04400); [code/data](https://github.com/ku21fan/STR-Fewer-Labels/)
- Zero identity-labelled photographs, museum case: the Met's best model is trained entirely on
  catalogue images and evaluated on visitor photographs, reaching 36.1 GAP / 55.0 ACC over 224k
  classes — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- A few hundred **unlabelled** real photographs, retail case: DIHE's domain discriminator used
  **547 unlabelled in-store crops**, with no overlap with the 938 evaluation queries, to drive the
  studio→shelf translation — [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- Hand-labelled real photographs were needed for the **detector**, not the embedder: 1,247 manually
  labelled in-store images, boxes only, no product labels — [arXiv 1810.01733](https://arxiv.org/pdf/1810.01733)
- A dissenting caution: one paper argues synthetic-vs-real comparisons are frequently unfair because
  they pit *targeted* synthetic images against *untargeted* real images, and finds targeted real
  data retrieved from the generator's own training set often outperforms the synthetic data —
  [arXiv 2406.05184](https://arxiv.org/html/2406.05184v2)
- A secondary aggregator reports ImageNet-1K results of 70.9% top-1 at a 1:1 synthetic-to-real ratio
  and 76.0% at 10× synthetic. This is an aggregator, not a primary source; I did not verify it
  against the underlying paper — [Emergent Mind: synthetic-to-real data ratio](https://www.emergentmind.com/topics/synthetic-to-real-data-ratio)

### Inferences

- The 5–20% guidance is for a *fixed-size mixed training set for one task*. It cannot be applied
  naively here: if the synthetic cover corpus is 10⁵–10⁶ renders, 5% real is 5,000–50,000
  owner-authored photographs, which is not achievable by one person under the ethics constraint.
- The resolution is to put the real photographs where the literature says they are irreplaceable and
  cheapest, and nowhere else. Three distinct roles, in descending order of value per photograph:
  1. **Evaluation and threshold calibration** (the only role where the Met needed photographs at
     all). This is what the existing 122-image corpus already is.
  2. **An unlabelled appearance distribution** for a learned restyler or for domain-adversarial
     training — DIHE's 547 crops is the published order of magnitude. These need **no ISBN, no
     identity label at all**, which makes them cheap to produce and ethically simple.
  3. **Class-agnostic detector boxes** — Tonioni's 1,247 images, labelled with boxes only. Books
     in a frame are an easier detection problem than grocery SKUs, and a general object detector
     may cover it off the shelf.
- Synthetic-first, real-fine-tune is the ordering with the best evidence (Tremblay: 98.5 vs ≈96.4),
  but note it required 6,000 real images to reach that figure. Treat "fine-tune on real" as a
  *later* phase that may never be affordable here, not as the plan.
- Baek's STR result is the warning for the generative branch, not the retrieval branch: if the plan
  ends up training a text reader, 276K real labelled text crops beat 16M synthetic ones — and
  there is no ethical way to obtain 276K real book-cover text crops from users. The correct move is
  therefore to **use an existing scene-text/VLM reader trained by someone else on public data**, not
  to train one.

### Gaps

- No paper I found quantifies the synthetic-to-real ratio for *instance-level retrieval with a
  catalogue-sized class count*. The 5–20% figures come from detection and structure recognition,
  which have orders of magnitude fewer classes. Transferring them is an extrapolation.
- The Tremblay AP-versus-amount-of-real-data curve exists only as a figure (Fig. 6); the underlying
  values are not in the text, so I cannot report the knee of that curve.

---

## Q4. Retrieval vs generative: what does each need from a training set?

### Takeaway

They need almost disjoint things, and the asymmetry is the most consequential fact in this file:
**retrieval's data requirement scales with the catalogue (one reference image per edition, plus
negatives drawn from the catalogue's own structure), while generative reading's requirement scales
with typography diversity and is essentially independent of how many books exist.** Only the
retrieval path needs a distractor-scaled evaluation set; only the generative path needs transcription
targets that differ from catalogue metadata.

### Cited Findings

**Retrieval path**

- Needs one-or-few clean reference images per class and nothing else per class: Tonioni encodes each
  reference as a ~1,000-float descriptor and adds new products by inserting descriptors, with no
  retraining — [ar5iv 1810.01733](https://arxiv.org/pdf/1810.01733)
- Needs no class labels for the embedding loss beyond catalogue grouping: the Met trains
  contrastively with self-generated positives, and this beats parametric classifiers on the same
  data by a wide margin (32.5 vs 16.9 GAP for ArcFace) — [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- Needs an evaluation set **with distractors at realistic index scale**, because accuracy is a
  function of index size: book covers 0.68 → 0.18 top-1 going from 101 to 104k candidates
  ([ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)); ILIAS DINOv3-L 31.1 → 26.5
  mAP@1k going from 5M to 100M distractors ([ILIAS](https://vrg.fel.cvut.cz/ilias/)); the Met's
  R18 ImageNet GAP 15.9 with distractors vs 37.5 without — a 21.6-point gap
  ([ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747))
- Benefits strongly from a re-ranking stage, which has its own data needs: ILIAS AMES re-ranking of
  the top-10k lifts 100M-scale mAP@1k from ~31 to 38.9 against an oracle ceiling of 56.0
  ([ILIAS](https://vrg.fel.cvut.cz/ilias/)); the book paper's RANSAC/HOG re-rank of the top 15 lifts
  top-1 from 0.84 to 0.94 without distractors and 0.60 to 0.67 with them
  ([ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307))
- Frozen off-the-shelf backbones are a serious baseline and respond very differently to adaptation:
  linear adaptation on UnED gives PE-L +12.5 and SigLIP2-L +12.0 mAP@1k at 5M, but DINOv3-L only
  +1.8 and DINOv2-L +0.3. ILIAS lists UnED-based adaptation training data at 2.8M images —
  [ILIAS](https://vrg.fel.cvut.cz/ilias/)

**Generative / text-reading path**

- Needs transcription targets, and real ones beat synthetic ones at a ~58:1 ratio: 276K real labels
  matched or beat 16M synthetic — [Baek et al., CVPR 2021](https://openaccess.thecvf.com/content/CVPR2021/html/Baek_What_if_We_Only_Use_Real_Datasets_for_Scene_Text_CVPR_2021_paper.html)
- Needs nothing per-edition: the 2014 book system matched noisy OCR output against clean title and
  author strings with character 3-grams and tf-idf weighted inner products — the catalogue side is
  pure text, free — [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)
- Degrades much more gracefully with index size than visual retrieval: OCR 0.65 → 0.31 vs VLAD
  0.68 → 0.18 at 104k distractors — [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)
- Current VLM ceiling on bibliographic reading is well short of solved: BiblioPage annotates scanned
  title pages with 16 bibliographic attributes; the **best model reached F1 67**, with GPT-4o leading
  among VLMs, and adding OCR output to the prompt improved results —
  [BiblioPage, arXiv 2503.19658](https://arxiv.org/html/2503.19658v1)
- On cover-specific VQA, publisher is typically the easiest attribute to extract and **book titles
  present the greatest challenge** — [ViOCRVQA benchmark summary](https://www.alphaxiv.org/benchmarks/vietnam-national-university/viocrvqa)
- A documented failure mode of the generative path is hallucinated completion: a write-up of
  Llama 3.2-Vision reports it "intelligently fills in the missing first name of an author" —
  presented there as a feature, but it is a fabricated read —
  [Towards AI](https://towardsai.com/p/machine-learning/enhance-ocr-with-llama-3-2-vision-using-ollama)
- An evaluation comparing sending a cover image to a VLM versus OCR-then-text-LLM concluded VLMs win
  for title extraction, but the page did not expose the underlying numbers —
  [DOAB title extraction eval](https://huggingface.co/spaces/davanstrien/doab-title-extraction-eval/blob/main/app.py)

### Inferences

- The two paths answer different questions and the ISBN hard gate already decides which one is
  structurally safer. A retrieval hit is a claim about *a specific edition* and can be wrong in a way
  that looks confident; a text read produces title/author strings that must then be resolved against
  Open Library or Google Books, and that resolution step **is** the verification. The generative path
  therefore inherits the existing ISBN gate for free, while the retrieval path requires its own
  calibrated confidence threshold — which is a thing only photographs can calibrate.
- The two fail differently and the 2014 paper already proved combining them is worth +0.24 top-1
  (0.60 vs 0.31/0.18 at 104k). A combined architecture is not a hedge; it is the measured best option
  in the only study of this exact task.
- Training-set implication, stated bluntly: **the generative path needs no training set at all** in
  2026 — it needs a prompt, a verification step against the ISBN gate, and an evaluation corpus. The
  retrieval path needs a reference index (free), a negative-mining scheme (free from metadata),
  optionally a renderer (expensive), and an evaluation corpus *with distractors* (the expensive part
  nobody budgets for).

### Gaps

- I found no benchmark measuring modern VLM accuracy on *photographed book covers* specifically,
  with reported title/author exact-match or ISBN-resolution rates. BiblioPage is scanned title pages;
  ViOCRVQA is Vietnamese covers in a VQA format. This is a genuine hole and the project's own
  122-image corpus may be the best instrument available for it.
- The DOAB VLM-vs-OCR comparison's numbers were not retrievable from the page I could read.

---

## Q5. What annotation is actually required? What is not free from catalogue metadata?

### Takeaway

The cover-image-to-ISBN pairing is free, and so is the entire class hierarchy used for negative
mining. What is **not** free is (a) the identity of the edition in a photograph taken by a human,
(b) list-valued ground truth for multi-book frames, (c) class-agnostic detection boxes, and (d) the
negative/not-a-book classes. The project's own corpus already measures (a): 19 of 122 images could
not carry a scoring label without a follow-up round.

### Cited Findings

- Free from catalogue: each cover in the 2014 book study "is annotated with title and author text",
  and 104,132 distractor covers with metadata were simply downloaded from openlibrary.org —
  [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)
- Free: class grouping for metric learning. The Met uses one class per exhibit straight from the
  museum's open-access catalogue, with no additional annotation, and its best results come from a
  contrastive objective that needs no labels beyond that grouping —
  [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- Free: the hierarchy for negative weighting. DIHE scales the triplet margin by how many parent
  classes the anchor and the negative share, using the product taxonomy that ships with the dataset —
  [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- **Not free — detector supervision:** 1,247 in-store images manually labelled with bounding boxes.
  Crucially, boxes only, no product identity, because the detector is class-agnostic —
  [arXiv 1810.01733](https://arxiv.org/pdf/1810.01733)
- **Not free — per-instance evaluation annotation:** the shelf study's "management" evaluation used
  70 in-store images with per-instance annotations against a 182-product database —
  [arXiv 1810.01733](https://arxiv.org/pdf/1810.01733)
- **Not free — query identity.** This project has already measured the cost. `images/CORPUS-INTAKE.md`
  records that "7 of the first 8 carry no identity and `recall@1` was uncomputable on them at any
  corpus size" because the fixtures "were shot and labelled afterwards", and the mitigation is to
  record the ISBN-13 at capture time, most cheaply by encoding it in the filename —
  `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`
- **Not free — and dangerous to guess.** The same file records a real defect of this exact kind:
  "the corpus plan cited Bird Lake Moon's ISBN for the barcode fixture, which is The Name of the
  Rose", and notes elsewhere that "the model was right where this label was wrong" —
  `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`, `/Users/erinversfeld/thestacks/images/SHOT-LIST.md`
- **Measured residual annotation burden:** `images/SHOT-LIST.md` reports that 19 of the 122 images
  "need something before they can carry a label that scores" — 10 need an ISBN with no reshoot, 2
  need title **and** ISBN and a second photo, 4 need a decision only the owner can make, 2 are worth
  reshooting, and 1 needs a privacy check —
  `/Users/erinversfeld/thestacks/images/SHOT-LIST.md`
- **Not expressible yet — multi-book ground truth:** `expect_isbn` is a single field, so a frame
  holding three books "can record only one expected identity"; the intake doc is explicit that faking
  it would be "a lying label, and this project has been bitten by exactly that shape before" —
  `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`
- **Not free — the distinction between a work and an edition.** The intake doc states the scoring
  consequence directly: "an ISBN match is proof of *edition*, a title match is proof of *work*", and
  warns against inferring one from the other because "a photograph is of one physical copy and the
  work has many editions" — `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`
- **Not free — negative and near-miss classes.** The project's shot list allocates 20 `neg-` images
  (mug, plant, screenshot, person) and 15 `adjacent-` images (magazine, boxed DVD, notebook, distant
  shelf), neither of which has any catalogue counterpart —
  `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`

### Inferences

- The 19-of-122 figure (15.6%) is the best available estimate of the **label-completion overhead per
  photograph** for owner-authored capture, and it was produced by this project under favourable
  conditions. Any capture plan should budget a second pass at roughly that rate, and the
  filename-carries-the-ISBN convention is the measured mitigation.
- The work/edition distinction is a training-set hazard, not just a scoring one. If the retrieval
  index is keyed by ISBN (edition) but the renderer or augmenter is fed one cover image per *work*,
  the negatives will be silently poisoned: two ISBNs of the same work with the same cover art are
  genuine near-duplicates that no embedding can separate. This must be decided before any data is
  generated, and the honest resolution is to make the retrieval target the *work* or the *cover art*,
  and leave edition disambiguation to the barcode/text path.
- Detector boxes are the one hand-annotation line item that is unavoidable **and** cheap: boxes only,
  no identity, on owner-authored frames; and the `multi-` stratum frames are the same images.
- The ethics constraint does not add annotation cost. It adds *capture* cost. Annotation cost is
  identical whether the photograph came from a user or from the owner — and is actually lower for
  owner-authored images, because the owner holds the physical book and can read the barcode.

### Gaps

- I found no published figure for per-image annotation time on instance-level retrieval corpora, so
  the only quantified labour datapoint is this project's own 19/122.
- The licensing status of Open Library / Google Books cover images for use as training data was not
  researched here and is a real open question — the 2014 paper downloaded 104k Open Library covers
  for research use, which does not establish a licence for model training.

---

## Q6. Hard-negative mining for book covers specifically

### Takeaway

Two published strategies apply directly and compose: **mine negatives from the current embedding's
own top-k** (the Met), and **scale the triplet margin by catalogue-hierarchy distance** so that a
same-series or same-imprint negative is pushed apart less aggressively than an unrelated one (DIHE).
Book catalogues supply the hierarchy for free — series, imprint, publisher, author, editions of a
work — which is exactly the structure DIHE had to have handed to it.

### Cited Findings

- The Met's mining rule, stated precisely: each anchor is paired with one positive and one hard
  negative, where "the hard negative is a randomly chosen image from a different class, drawn from
  the **10 most similar images** according to the current backbone's embeddings" —
  [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- The Met's positive selection is also a mining problem, and getting it wrong costs accuracy:
  random same-class positives scored 29.8 GAP, embedding-nearest same-class positives scored 32.5 —
  the authors conclude real positives help "only when the pair is properly disambiguated" —
  [ar5iv: The Met Dataset](https://ar5iv.labs.arxiv.org/html/2202.01747)
- DIHE's hierarchical margin: α is scaled between α_min and α_max according to how many parent
  classes the anchor and negative share — items sharing all parents get α_min, fully disjoint items
  get α_max. Values used: α_min = 0.1 / α_max = 0.5 in the small-network study; α_min = 0.05 /
  α_max = 0.5 for the final VGG-16 model; a fixed-margin baseline used α = 0.3 —
  [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- Quantified contribution of the hierarchy alone (small network, K=1): Grocery_Food 0.301 → 0.325,
  Grocery_Full 0.277 → 0.302, Product8600 0.351 → 0.355; on VGG-16 the gains are +0.013, +0.041 and
  +0.040 — [ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)
- The baseline shelf pipeline used **random** negatives, with each training iteration picking two
  products at random and using the augmented reference of one as the anchor; it reports no
  hard-negative mining at all — [ar5iv 1810.01733](https://arxiv.org/pdf/1810.01733)
- Geometry-sourced hard examples where geometry exists: Radenović, Tolias and Chum select hard
  positive and hard negative examples using camera positions and geometry from structure-from-motion
  reconstructions, with no manual annotation, and pair this with GeM pooling and learned whitening to
  reach state-of-the-art on Oxford/Paris/Holidays — [arXiv 1711.02512](https://arxiv.org/abs/1711.02512)
- Index-scale evidence that confusable negatives are the binding constraint for covers: the 2014
  paper reports VLAD "tends to match covers with similar visual patterns", and its visual top-1
  collapses from 0.68 to 0.18 once 104k real covers are present as potential confusers —
  [ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307)

### Inferences

- The book-specific negative taxonomy that follows from DIHE's scheme, in increasing hardness, with
  each level available free from catalogue metadata:
  1. **Same work, different edition** — frequently *identical or near-identical cover art*. These
     are not negatives at all; they are the same visual class and must be merged or the loss will be
     asked to separate images that cannot be separated. This is the single most important case and
     it is unique to books (the grocery literature has no equivalent because SKUs are distinct).
  2. **Same series, same template** — Penguin Classics, Virago Modern Classics, a numbered genre
     series. Same spine colour, same typographic grid, differing only in title text and cover art
     panel. These are the true hardest negatives and are exactly what α_min is for.
  3. **Same author, same publisher, same designer** — shared art direction.
  4. **Same imprint, different series**; then **unrelated**, at α_max.
- The Met's "top-10 of the current embedding" rule will *discover* level-2 negatives automatically
  without any metadata, and the metadata hierarchy will *weight* them correctly. Using both is
  strictly better than either, and neither costs annotation.
- A book-specific negative source with no analogue in the cited literature: **the back cover, the
  spine, and the barcode region of the same edition**. These are genuine positives for "which book
  is this" and genuine negatives for "which face am I looking at", and a corpus built only from
  front-cover renders will contain none of them.
- ⚠️ Negative mining interacts with the ethics constraint in one place worth flagging: the standard
  cheap source of millions of hard negatives for a photographic domain is a large web photo corpus
  (ILIAS uses 100M YFCC100M images as distractors). YFCC100M is Creative-Commons licensed and
  contains people. Using it as a *distractor index for evaluation* is a different act from using it
  as *training data*, and the project's stated reason for the constraint — that a corpus is permanent
  and bystanders cannot consent — applies to both. This needs an explicit decision rather than a
  default.

### Gaps

- No paper I found mines hard negatives for book covers specifically, or quantifies the series/template
  confusion. The taxonomy above is my inference from DIHE's hierarchy mechanism applied to bibliographic
  metadata; it is not a cited result.
- No published figure for how many distinct editions share cover art across a real catalogue, which
  would size problem (1) above.

---

## Costed plan: what the evidence implies for an owner-authored + synthetic corpus

### Takeaway

The literature supports a plan in which **no photograph is ever a training example**. Photographs
serve three roles only — evaluation, unlabelled appearance distribution, and detector boxes — and
the published volumes for those roles are in the hundreds, not the thousands. The expensive and
currently unbudgeted item is not photography and not rendering; it is **a distractor index for
evaluation**, without which the dominant failure mode of the retrieval path is invisible.

### Cited Findings

- The volumes the comparable systems actually used: Met — 0 photographs in training, ~1,100+ visitor
  photographs for evaluation over 224k classes ([ar5iv](https://ar5iv.labs.arxiv.org/html/2202.01747));
  DIHE — 547 unlabelled real crops for the domain discriminator, 938 evaluation queries
  ([ar5iv 1902.00760](https://ar5iv.labs.arxiv.org/html/1902.00760)); Tonioni — 1,247 box-labelled real
  images for the detector, 680 evaluation queries, 0 photographs in embedder training
  ([arXiv 1810.01733](https://arxiv.org/pdf/1810.01733)); Shih et al. — 404 queries over 101 titles and
  104,132 catalogue distractors ([ar5iv 1411.5307](https://ar5iv.labs.arxiv.org/html/1411.5307))
- The project's own capture economics: 122 images shot to date; the plan targets 135 shot plus 20
  generated across 9 strata, from "**~45–55 distinct books**, not 135", because the `hostile-` and
  `typo-` strata are deliberate restagings of books already shot for `clean-` and `cover-`. A
  directional pilot is declared possible at 45 images (`cover-` + `typo-`) —
  `/Users/erinversfeld/thestacks/images/CORPUS-INTAKE.md`
- The project's measured label-completion overhead: 19 of 122 images required a follow-up round
  before they could carry a scoring label — `/Users/erinversfeld/thestacks/images/SHOT-LIST.md`

### Inferences

A costed plan, in dependency order. Costs are given in the units the evidence supports —
photograph counts, distinct-book counts, and engineering phases. Where a figure is an assumption
rather than a citation it is marked **[assumption]**.

**Phase 0 — measure the frozen baseline (days, no new data).**
Embed the existing 122 photographs with DINOv3-L and SigLIP2-L and retrieve against catalogue cover
images. ILIAS says DINOv3-L gets 31.1 mAP@1k at 5M distractors with no adaptation, and gains only
+1.8 from linear adaptation, while SigLIP2-L gains +12.0 — so this phase also tells you *which
backbone is worth adapting*. Cost: inference over 122 images plus an index build. This phase can
make most of the rest unnecessary, and the DIHE pretrained-backbone collapse (+0.153 → +0.030) is
the reason to run it before committing to a renderer.

**Phase 1 — build the distractor index (the real cost, and the one the 122-image corpus cannot
substitute for).**
Retrieval accuracy is a function of index size: 0.68 → 0.18 at 104k for covers, 15.9 vs 37.5 GAP
with and without distractors for the Met. An evaluation that reports recall@1 against a few hundred
candidates is measuring nothing. Minimum viable: the ~104k Open Library covers used by Shih et al.
as a precedent; realistic: the full catalogue the product will actually serve. Cost is storage,
embedding compute, and an ANN index — **[assumption]** dominated by one-off embedding inference over
the catalogue, not by anything bespoke.

**Phase 2 — catalogue-side contrastive training (zero photographs, zero annotation).**
Reproduce Con-Syn on cover images: one class per cover-art group, positives by crop/colour-jitter/
grayscale augmentation, hard negatives from the top-10 of the current embedding, margin scaled by
bibliographic hierarchy per DIHE. Expected effect, by analogy to the Met: the largest single gain
available (15.9 → 30.4 GAP there), and it needs no photographs at all. ⚠️ Resolve the
work-vs-edition class definition before this phase, or the negatives are poisoned.

**Phase 3 — unlabelled photographic appearance set (hundreds of photographs, no labels).**
DIHE's 547 unlabelled crops is the published order of magnitude. These are the cheapest photographs
to produce because they need no ISBN, no title, no decision from the owner — just book-shaped things
under real light. **[assumption]** at 2–4 minutes per photograph including staging, 550 photographs
is roughly 20–35 hours of capture; the project's own evidence that 122 images covered ~45–55 distinct
books suggests the book-sourcing problem, not the shutter, is the constraint. Use them for a restyler
or a domain-adversarial term, and expect a modest gain (+0.030 1-NN with a strong backbone), not a
transformation.

**Phase 4 — renderer, only if Phases 0–3 leave a measured gap.**
The document literature is the right source (Doc3D geometry, UVDoc's finding that synthetic
appearance alone was unrealistic, DocReal's added deformations and noise). Order the transforms by
evidence: perspective/cylindrical warp first, then blur and exposure, then glare — noting that the
one ablation of synthetic glare as a fine-tuning signal reported it "did not improve performance
enough". **[assumption]** this is weeks of engineering, which is why it is Phase 4 and not Phase 1.

**Phase 5 — detector boxes (hundreds of images, boxes only).**
Tonioni needed 1,247 box-labelled images. Books in a frame are easier than grocery SKUs and an
off-the-shelf detector may suffice; test that before labelling anything.

**Running alongside: close the two label defects the corpus already has.** The 19-of-122 follow-up
rate and the single-valued `expect_isbn` field are both measured, tracked problems, and the
multi-book stratum cannot express its ground truth at all until the latter is fixed.

**What the ethics constraint actually costs.** On this evidence, remarkably little for the retrieval
path: every comparable system trained its embedder with zero photographs, and the only photographs
that were irreplaceable were evaluation queries and a few hundred unlabelled appearance samples —
both of which are producible by the owner. The constraint bites hardest on the *generative* path,
where Baek's 276K-real-labels result says real transcription data is worth ~58× its synthetic
equivalent and there is no ethical route to 276K real cover-text crops. The correct response is not
to train a reader but to use one trained by others on public data, and to let the ISBN hard gate
verify its output.

### Gaps

- I could not find published per-photograph or per-GPU-hour costs for any of the comparable systems,
  so every monetary figure here would be invented. The costings above are deliberately expressed in
  photograph counts, distinct-book counts and phase ordering, which the sources do support.
- The licensing position for using Open Library / Google Books cover images as *training* data (as
  opposed to as an index or as research distractors) is unresolved and is a genuine blocker for
  Phase 2, not a detail.
- Whether using a Creative-Commons web photo corpus (e.g. YFCC100M, which contains photographs of
  people) as an evaluation distractor index is compatible with this project's stated reason for its
  constraint is a decision I cannot make from the literature. It should be made explicitly.
