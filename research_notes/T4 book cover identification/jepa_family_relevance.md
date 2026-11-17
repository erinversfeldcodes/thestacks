# JEPA-family models (I-JEPA, V-JEPA, V-JEPA 2) for book-cover identification on constrained hardware

Scope: assessed as of November 2026, against a deployment target of an NVIDIA T4 (16GB, Turing, no bf16) on Modal serverless at $0.59/hr with a $50/month total AI budget, and against the two already-shortlisted alternatives: SigLIP 2 ViT-B/16 (Apache-2.0, 86M params) and DINOv2 ViT-B/14 (Apache-2.0).

**Headline verdict: NO. Three independent disqualifiers, any one of which is sufficient.** (1) I-JEPA and V-JEPA 1 weights and code are **CC-BY-NC 4.0 — non-commercial only**. (2) I-JEPA was **never evaluated on retrieval at all**, and its nearest architectural cousin (MAE) scores 2.2 mAP on Oxford-Hard where DINOv2 ViT-B/14 scores 49.5. (3) The smallest released I-JEPA checkpoint is **~600M params** — roughly 7× SigLIP 2 ViT-B/16 — with no base-size release. V-JEPA 2 escapes disqualifier (1) with an MIT licence, but is a *video clip* encoder, is also evaluated on no retrieval task, and solves a problem (temporal/physical prediction) that is not the problem book-cover identification has.

---

## What exactly are I-JEPA and V-JEPA / V-JEPA 2? What the output is, and what it is NOT

### Takeaway
JEPA is a **self-supervised pretraining objective**, not a retrieval model: a context encoder predicts the *latent representations* of masked target blocks (produced by an EMA target encoder) rather than predicting pixels. The deliverable of that recipe is a frozen backbone whose patch/CLS features are intended to be consumed by a **trained probe** (linear classifier, attentive probe, or VLM adapter). It is explicitly NOT a trained similarity metric, NOT a contrastive/view-invariant embedding, and NOT a text-aligned embedding space.

### Cited Findings
- I-JEPA "predicts the representations of various target blocks in the same image" from "a single context block", is "non-generative", and its stated aim is "highly semantic image representations" learned "without relying on hand-crafted data augmentations" — [I-JEPA, arXiv:2301.08243](https://arxiv.org/abs/2301.08243)
- The latent-space target is load-bearing, not incidental: ablating the target from the target-encoder output to raw pixels drops ImageNet-1% linear probe top-1 from **66.9 to 40.7** (ViT-L/16) — I-JEPA paper, Table 7 ("Ablating targets") — [I-JEPA PDF](https://arxiv.org/pdf/2301.08243v3)
- The paper's own framing of the family split: I-JEPA is positioned *against* "methods using extra view data augmentations" (DINO, iBOT, MSN, SimCLR) and *alongside* "methods without view data augmentations" (MAE, data2vec, CAE). Every results table in the paper is partitioned on exactly this axis — [I-JEPA PDF, Tables 1–4](https://arxiv.org/pdf/2301.08243v3)
- V-JEPA 2's own model card describes the artefact as a video encoder "intended to represent any video (and image) to perform video classification, retrieval" and as "a video encoder for VLMs"; its HF pipeline tag is `video-classification`. The card reports **no evaluation results of any kind** — [facebook/vjepa2-vitl-fpc64-256](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256)
- V-JEPA 2 checkpoints are clip encoders parameterised by frames-per-clip: the ViT-L checkpoint is `fpc64`, i.e. "For this model, we use 64" frames — [facebook/vjepa2-vitl-fpc64-256](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256)
- V-JEPA 2's reported headline results are all temporal/physical: EK100 action anticipation 39.7 (vs 27.6 previous best), SSv2 probe 77.3, Diving48 probe 90.2, MVP Video-QA 44.5, TempCompass 76.9; plus a robot-manipulation arm (V-JEPA 2-AC: reach, grasp, pick-and-place on a Franka arm) — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)

### Inferences
- The thing a cover-identification index needs is a **metric space where two photographs of the same physical cover land near each other and a different cover lands far away**. JEPA optimises predictability of latent content within one image; nothing in the objective shapes a *between-image* distance. DINOv2's and SigLIP 2's objectives do shape exactly that (view-invariance via augmentation/self-distillation; cross-modal alignment via a sigmoid contrastive loss respectively).
- The card's word "retrieval" for V-JEPA 2 is an *intended-use* aspiration written by the authors, not a measured capability — there is no number anywhere behind it. It should not be read as evidence.

### Gaps
- No source found that states the embedding dimensionality of the I-JEPA checkpoints' pooled output, nor a recommended pooling strategy for retrieval (because retrieval was never a target use).

---

## ⛔ DECISIVE: is a JEPA checkpoint usable as an off-the-shelf image-retrieval encoder?

### Takeaway
**No, and the evidence for that is an absence that is itself conclusive: I-JEPA is evaluated on zero retrieval benchmarks in its own paper, and it is not included as a baseline in DINOv2's instance-recognition table.** Nobody — not Meta, not the DINOv2 authors, not the follow-up literature I could find — has published an I-JEPA number on ROxford/RParis/Met/AmsterTime or any copy-detection benchmark. Meanwhile the architecturally nearest evaluated model (MAE, the other no-view-augmentation masked-pretraining method) is catastrophically bad at it.

### Cited Findings

**The absence, established from the primary source.** The complete table list in the I-JEPA paper is: Table 1 ImageNet-1K linear eval; Table 2 ImageNet-1% semi-supervised; Table 3 linear-probe transfer classification (CIFAR100, Places205, iNat18); Table 4 low-level tasks (Clevr/Count, Clevr/Dist); Table 5 dataset/model-size ablation; Table 6 masking-strategy ablation; Table 7 target-space ablation. **There is no retrieval, instance-recognition, copy-detection, landmark, or near-duplicate evaluation in the paper.** — [I-JEPA PDF, Tables 1–7](https://arxiv.org/pdf/2301.08243v3)

**DINOv2's instance-level recognition table (Table 9), the benchmark that matters, verbatim.** Columns: Oxford M / Oxford H / Paris M / Paris H / Met GAP / Met GAP- / Met ACC / AmsterTime mAP — [DINOv2, arXiv:2304.07193, Table 9](https://arxiv.org/pdf/2304.07193v2)

| Feature | Arch | Ox-M | Ox-H | Par-M | Par-H | Met GAP | Met GAP- | Met ACC | AmsterTime |
|---|---|---|---|---|---|---|---|---|---|
| OpenCLIP | ViT-G/14 | 50.7 | 19.7 | 79.2 | 60.2 | 6.5 | 23.9 | 34.4 | 24.6 |
| MAE | ViT-H/14 | **11.7** | **2.2** | 19.9 | 4.7 | 7.5 | 23.5 | 30.5 | 4.2 |
| DINO | ViT-B/8 | 40.1 | 13.7 | 65.3 | 35.3 | 17.1 | 37.7 | 43.9 | 24.6 |
| iBOT | ViT-L/16 | 39.0 | 12.7 | 70.7 | 47.0 | 25.1 | 54.8 | 58.2 | 26.7 |
| DINOv2 | ViT-S/14 | 68.8 | 43.2 | 84.6 | 68.5 | 29.4 | 54.3 | 57.7 | 43.5 |
| **DINOv2** | **ViT-B/14** | **72.9** | **49.5** | **90.3** | **78.6** | 36.7 | 63.5 | 66.1 | 45.6 |
| DINOv2 | ViT-L/14 | 75.1 | 54.0 | 92.7 | 83.5 | 40.0 | 68.9 | 71.6 | 50.0 |
| DINOv2 | ViT-g/14 | 73.6 | 52.3 | 92.1 | 82.6 | 36.8 | 73.6 | 76.5 | 46.7 |

- **I-JEPA does not appear in this table, or as a retrieval baseline anywhere in the DINOv2 paper.** The non-view-augmentation family is represented solely by MAE — [DINOv2, arXiv:2304.07193](https://arxiv.org/pdf/2304.07193v2)
- DINOv2's retrieval protocol is exactly the cover-identification protocol: "Images from a database are ranked according to their cosine similarity with a query image" — a non-parametric, frozen-feature nearest-neighbour evaluation, no probe trained. DINOv2's features "significantly outperform both SSL (+41% mAP on Oxford-Hard), and weakly-supervised (+34% mAP on Oxford-Hard) ones" — [DINOv2 §7.3 Instance Recognition](https://arxiv.org/pdf/2304.07193v2)
- **Where I-JEPA does overlap with a view-invariant method on transfer tasks, it loses.** I-JEPA ViT-H/14 vs iBOT ViT-L/16 on linear-probe transfer: CIFAR100 87.5 vs **88.3**, Places205 58.4 vs **60.4**, iNat18 **47.6 vs 57.3** — a 9.7-point deficit on the fine-grained benchmark, against a *smaller* model — [I-JEPA PDF, Table 3](https://arxiv.org/pdf/2301.08243v3)
- I-JEPA also loses to DINO ViT-B/8 on iNat18 (47.6 vs 55.9) despite ViT-H/14 being far larger — [I-JEPA PDF, Table 3](https://arxiv.org/pdf/2301.08243v3)
- Independent confirmation that the head-to-head simply does not exist: a targeted search for an I-JEPA-vs-DINOv2 retrieval benchmark surfaced **no direct comparison**. The nearest indirect evidence — a representation-alignment study — reports that "MAE and I-JEPA align alike, both below DINOv2" — [Proving and Improving the Platonic Representation Hypothesis with JEPAs, arXiv:2610.39302](https://arxiv.org/html/2610.39302v1)
- A practitioner write-up attributes I-JEPA's weakness partly to scale, noting its largest model was pretrained on only ~15M images, and concludes that for image-retrieval/embedding tasks it is "probably still better to stick with CLIP or DINOv2 for now" — informal opinion, not a benchmark — [Machine Learning with a Honk, #32 I-JEPA](https://mlhonk.substack.com/p/32-i-jepa)
- One study on a *different* task (safety-image anomaly detection) found DINOv2, I-JEPA and ViT "deliver comparable performance" — a counterpoint, but for anomaly detection, not instance retrieval — [Comparative Study of DINOv2, I-JEPA and ViT (ICoSyS)](https://icosys.ch/wp-content/papercite-data/pdf/spat2025.pdf)
- **V-JEPA 2 is likewise not evaluated on retrieval.** Its repo's eval folders cover action anticipation, image classification and video classification only. An "R@5" figure appears for EK100 (32.7 R@5) but that is action-anticipation recall, not image retrieval — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)

**SigLIP 2 comparison point (weaker evidence).** I could not find a published SigLIP 2 number on ROxford/RParis/Met/AmsterTime. The closest is a fine-grained *industrial part* retrieval study reporting SigLIP2 at 94.26 Recall@10 vs DINOv2 CLS-token at 91.33, with the fusion of both reaching 97.02 — [Efficient Fine-grained Image Retrieval with Vision Foundation Models, CVPRW 2026](https://openaccess.thecvf.com/content/CVPR2026W/FGVC13/papers/Liu_Efficient_Fine-grained_Image_Retrieval_with_Vision_Foundation_Models_for_Industrial_CVPRW_2026_paper.pdf). ⚠️ These figures come from a search snippet, not a full-text fetch — treat as indicative only.

### Inferences
- **The absence is not neutral — it is the finding.** Meta's own researchers, who had every incentive to show I-JEPA's representations were strong off-the-shelf, chose linear probes and Clevr counting. Retrieval requires no training, is cheap to run, and is the standard showcase for a "strong off-the-shelf feature" claim. Its omission from a paper that explicitly claims "strong off-the-shelf semantic representations" is best read as a result that was not favourable, or a capability that was never a design goal.
- **The MAE row is the right proxy, with a caveat.** I-JEPA and MAE share the property DINOv2 identifies as decisive for retrieval — neither uses view-invariance augmentations. MAE ViT-H/14 scores **2.2 mAP on Oxford-Hard against DINOv2 ViT-B/14's 49.5 — a ~22× gap**, and 4.2 vs 45.6 on AmsterTime. I-JEPA should be expected to sit above MAE (its latent targets produce more semantic features than pixel targets — Table 7's 66.9-vs-40.7 gap is direct evidence of that) but well below the view-invariant family. It would have to beat MAE by more than an order of magnitude to merely reach DINOv2 ViT-S/14. **This is an inference, not a measurement — but the direction is not in doubt, and the burden of proof sits on anyone proposing I-JEPA.**
- Book-cover matching is *instance-level, fine-grained* retrieval — two Penguin Modern Classics differ by title typography on an identical livery. The I-JEPA result that most resembles this (iNat18, the fine-grained benchmark) is its single worst transfer result relative to baselines. That is the opposite of encouraging.
- To use a JEPA checkpoint for retrieval, this project would have to **generate the missing evidence itself** — build the ROxford/RParis harness or a cover-specific eval set, run it, and discover the answer. That is a research cost, not an integration cost.

### Gaps
- No published I-JEPA number on any retrieval benchmark exists, so the comparison to DINOv2/SigLIP 2 **cannot be made directly from the literature**. Reported here as absence, per instruction.
- No published SigLIP 2 number on ROxford/RParis/Met/AmsterTime found, so the SigLIP-2-vs-DINOv2 instance-retrieval ranking is unresolved from primary sources.

---

## Licences — CODE and WEIGHTS, stated separately

### Takeaway
**I-JEPA and V-JEPA 1 are CC-BY-NC 4.0 — commercial use is not granted, for code or for weights. This alone ends the evaluation for both.** V-JEPA 2 is different and genuinely permissive: MIT for code, and MIT declared on the checkpoint cards. The failure mode here is *not* the DINOv3 failure mode — CC-BY-NC is a standard, irrevocable, well-understood licence, not a bespoke unilaterally-amendable one — but it fails at a more basic gate: it simply does not permit the use.

### Cited Findings

**I-JEPA — CODE: CC-BY-NC 4.0.** The repository LICENSE file is the "Creative Commons Attribution-NonCommercial 4.0 International Public License". The grant at §2(a)(1)(a) is to "reproduce and Share the Licensed Material, in whole or in part, **for NonCommercial purposes only**". §1(i) defines NonCommercial as "not primarily intended for or directed towards commercial advantage or monetary compensation". §6(a): "if You fail to comply with this Public License, then Your rights under this Public License terminate automatically." — [facebookresearch/ijepa LICENSE](https://raw.githubusercontent.com/facebookresearch/ijepa/main/LICENSE)

**I-JEPA — WEIGHTS: CC-BY-NC 4.0.** The official Hugging Face checkpoint card declares `License: cc-by-nc-4.0`. Model size 0.6B params, F32. — [facebook/ijepa_vith14_1k](https://huggingface.co/facebook/ijepa_vith14_1k)

**V-JEPA 1 — CODE and (by repo default) WEIGHTS: CC-BY-NC 4.0.** The `facebookresearch/jepa` LICENSE is "Attribution-NonCommercial 4.0 International", §2(a)(1) limiting the licence to uses "for NonCommercial purposes only" — [facebookresearch/jepa LICENSE](https://raw.githubusercontent.com/facebookresearch/jepa/main/LICENSE). The repo README itself only says "See the LICENSE file for details" and states nothing separately about weights — [facebookresearch/jepa](https://github.com/facebookresearch/jepa)

**V-JEPA 2 — CODE: MIT.** The LICENSE file is the standard MIT template, "Copyright (c) Meta Platforms, Inc. and affiliates", granting permission "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell" — [facebookresearch/vjepa2 LICENSE](https://raw.githubusercontent.com/facebookresearch/vjepa2/main/LICENSE). The README confirms "The majority of V-JEPA 2 is licensed under MIT", with three utility files (`src/datasets/utils/video/randaugment.py`, `randerase.py`, `worker_init_fn.py`) under Apache-2.0 — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)

**V-JEPA 2 — WEIGHTS: MIT (per checkpoint card), but the repo does not state it.** The `facebook/vjepa2-vitl-fpc64-256` card declares `License: mit` — [HF card](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256). The GitHub README states no licence for the checkpoints; it only links download files — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2). A third-party mirror claims the ViT-giant encoder artifacts are Apache-2.0 while other encoders and probes are MIT, and advises checking each HF repo's licence individually — [LibreYOLO V-JEPA 2 docs](https://www.libreyolo.com/docs/models/vjepa2) ⚠️ third-party, unverified.
- The licence change between generations is confirmed by secondary sources: the original V-JEPA (2024) was CC-BY-NC and that restriction was removed in the V-JEPA 2 release.

### Inferences
- **The comparison this project cares about (vs the DINOv3 rejection) is asymmetric.** DINOv3's bespoke licence permits commercial use but with conditions this project judged unacceptable (non-transferable, pass-through on derivatives, unilateral amendment "effective immediately"). I-JEPA/V-JEPA 1's CC-BY-NC has *none* of those defects — it is irrevocable for the term, standard, and requires no pass-through agreement — but it withholds the one permission that matters. There is no negotiation to be had and no review to conduct: a commercially-operated product is outside the grant.
- A source-available, self-hosted product with partner integrations and a paid infrastructure footprint is "directed towards commercial advantage or monetary compensation" on any ordinary reading of §1(i). Even if the project believed it currently fell outside that, the ambiguity is itself the risk: the licence terminates automatically on breach (§6(a)), which would retroactively taint every embedding in the index.
- **V-JEPA 2 is legally clean** and should be judged on technical merit alone. If it ever were adopted, the per-checkpoint HF licence field must be checked for the specific checkpoint used, since the repo README does not cover weights and at least one third party claims the ViT-giant artifacts differ.

### Gaps
- Meta publishes no separate model-card/weights licence document for V-JEPA 2 in the GitHub repo; the MIT claim for weights rests on the HF card metadata. For a load-bearing legal decision this should be confirmed on the exact checkpoint before use.

---

## Model sizes and inference cost on a 16GB T4

### Takeaway
**Raw VRAM is not the binding constraint — model scale and cold-start are.** The smallest released I-JEPA checkpoint is ~600M params; **there is no ViT-B or ViT-S I-JEPA release at all**, so the floor is ~7× SigLIP 2 ViT-B/16's 86M. V-JEPA 2.1 does offer an 80M ViT-B/16, but it is a video encoder. I found **no reported inference latency for any JEPA checkpoint on any hardware**, let alone a T4.

### Cited Findings
- **I-JEPA released checkpoints (the complete set):** ViT-H/14 @224 (IN-1K, 300ep); ViT-H/16 @448 (IN-1K, 300ep); ViT-H/14 @224 (IN-22K); ViT-g/16 @224 (IN-22K). **No base or small variant is released.** The repo states no parameter counts — [facebookresearch/ijepa](https://github.com/facebookresearch/ijepa)
- I-JEPA ViT-H/14 is **0.6B params, F32** per the official model card — [facebook/ijepa_vith14_1k](https://huggingface.co/facebook/ijepa_vith14_1k)
- **V-JEPA 2 / 2.1 released checkpoints with parameter counts** — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2):

| Model | Params | Resolution |
|---|---|---|
| V-JEPA 2 ViT-L/16 | 300M | 256 |
| V-JEPA 2 ViT-H/16 | 600M | 256 |
| V-JEPA 2 ViT-g/16 | 1B | 256 |
| V-JEPA 2 ViT-g/16₃₈₄ | 1B | 384 |
| V-JEPA 2.1 ViT-B/16 | **80M** | 384 |
| V-JEPA 2.1 ViT-L/16 | 300M | 384 |
| V-JEPA 2.1 ViT-g/16 | 1B | 384 |
| V-JEPA 2.1 ViT-G/16 | 2B | 384 |

- Neither repo nor model card reports **any** inference cost, latency or throughput figure. The V-JEPA 2 repo only states that the demo "assumes your machine has a GPU" and recommends CUDA-enabled PyTorch — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2); [HF card](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256)
- I-JEPA's efficiency claims are all about **pretraining** cost, not inference: ViT-H/14 pretrained on 16 A100s in under 72 hours; "a huge I-JEPA model (ViT-H/14) requires less compute than a small iBOT model (ViT-S/16)" to *pretrain*; the scaling figure's x-axis is "Pretraining GPU Hours" (10³–10⁴) — [I-JEPA, arXiv:2301.08243](https://arxiv.org/abs/2301.08243); [I-JEPA PDF §7 Scalability, Fig. 5](https://arxiv.org/pdf/2301.08243v3)
- The one efficiency datapoint for V-JEPA 2 is a third-party optimisation blog claiming a 4× reduction in its heaviest computation — not a baseline latency, and unverified — [Medium](https://medium.com/@cryptofairy/how-i-got-a-4-reduction-in-v-jepa-2s-heaviest-computation-d54376052d8d) ⚠️ self-published.

### Inferences
- **Memory fits; economics do not.** I-JEPA ViT-H/14 at fp16 is roughly 1.2GB of weights, comfortable in 16GB. But a ViT-H/14 at 224px runs ~256 patch tokens through 32 wide layers — order-of-magnitude more FLOPs per image than SigLIP 2 ViT-B/16. On a serverless T4 billed at $0.59/hr with containers scaling to zero, the cost driver is seconds-of-GPU-per-identification plus the cold-start cost of pulling a 2.4GB F32 checkpoint into a fresh container. Choosing a 600M backbone over an 86M one multiplies both, for a capability that has never been measured on the task.
- **The no-bf16 constraint is a live risk specifically for V-JEPA 2**, whose reference code is modern and may assume bf16 autocast; fp16 on Turing would need verification and may require loss-scaling or fp32 fallbacks in the attention path. No source addresses T4/Turing support for either codebase.
- The absence of any published inference benchmark is consistent with these being research artefacts: nobody has had to defend their serving cost.

### Gaps
- **No measured inference latency or throughput for any I-JEPA or V-JEPA checkpoint, on T4 or otherwise, was found.** Any number used in a decision would have to be measured locally.
- Parameter count for the I-JEPA ViT-g/16 IN-22K checkpoint is not stated by Meta in either the repo or a model card.
- No source confirms or denies fp16/Turing compatibility of the `vjepa2` reference implementation.

---

## Is V-JEPA's VIDEO capability relevant to a video-driven identification path?

### Takeaway
**Not concretely, and not yet.** V-JEPA 2 is built for *temporal and physical* prediction — what happens next, what an action is, how a robot arm should move. A reader panning a camera across a shelf needs **per-frame instance matching plus simple tracking**, which is a different problem that V-JEPA 2 does not address and is not evaluated on. Pointing V-JEPA 2 at it would mean adopting a 300M–1B clip encoder to replace what a frame-sampling loop over an 86M image encoder already does.

### Cited Findings
- Every V-JEPA 2 headline benchmark is temporal/physical: EK100 action anticipation, SSv2, Diving48, MVP and TempCompass video-QA, plus V-JEPA 2-AC robot manipulation (reach, grasp, pick-and-place with a Franka arm) — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)
- The eval folders shipped in the repo are "action anticipation, image classification, and video classification" — **no retrieval, no tracking, no instance matching** — [facebookresearch/vjepa2](https://github.com/facebookresearch/vjepa2)
- V-JEPA 2 checkpoints encode clips, not frames: the ViT-L checkpoint consumes 64 frames per clip — [facebook/vjepa2-vitl-fpc64-256](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256)
- The model card's own intended-use text does list "retrieval", but the card carries no evaluation results to support it — [facebook/vjepa2-vitl-fpc64-256](https://huggingface.co/facebook/vjepa2-vitl-fpc64-256)
- DINOv2 — the image model — is already evaluated on video classification by linear probe on frame features: K400 73.2, UCF-101 89.1, SSv2 34.4 for ViT-B/14, with the authors noting the model "clearly sets a new state of the art" among self-supervised approaches on video "even though our features were not trained on videos" — [DINOv2 Table 7, §7.2](https://arxiv.org/pdf/2304.07193v2)

### Inferences
- **The video path's hard problems are not representational.** Pointing a phone at a shelf produces motion blur, oblique angles, partial occlusion by neighbouring spines, rolling-shutter artefacts, and the need to decide *which frame is worth running the expensive model on*. Those are solved by frame selection/quality gating, a barcode fast-path, and temporal vote aggregation over per-frame candidates — engineering the project controls — not by a clip-level world model.
- **Clip encoding is actively the wrong shape for this.** A 64-frame clip embedding deliberately pools away the per-object detail that distinguishes one spine from its neighbour; identification needs the opposite — a crop-level embedding per candidate spine. Running V-JEPA 2 on a shelf pan would cost more and discard the signal.
- DINOv2's result that image-trained frozen features linearly transfer to video classification is the relevant precedent: for this product's video path, **sample frames and run the image encoder**. That approach also keeps one encoder serving both the still-upload and video paths, which matters at $50/month.
- If a video-native model ever earns its place here, the triggering evidence would be a published instance-retrieval or re-identification benchmark where a clip encoder beats per-frame image embeddings. No such evidence exists for V-JEPA 2 today.

### Gaps
- No source evaluates V-JEPA 2 (or any JEPA) on video instance retrieval, object re-identification, or near-duplicate frame matching, so its suitability for this path is untested rather than disproven.

---

## Fair assessment: sensible candidate, or a pretraining research programme?

### Takeaway
**It is a pretraining research programme.** JEPA's contribution is a cheaper, augmentation-free way to *pretrain* a backbone — the paper's own efficiency argument is denominated entirely in pretraining GPU-hours. For a team that does not pretrain, that contribution is worth nothing. The deliverable this project needs — a frozen encoder with a published, reproducible instance-retrieval number under a permissive licence, small enough to serve cheaply — is exactly what DINOv2 ViT-B/14 and SigLIP 2 ViT-B/16 already are, and exactly what no JEPA checkpoint is.

### Cited Findings
- I-JEPA's efficiency claims are pretraining claims: "I-JEPA requires less compute than previous methods and achieves strong performance without relying on hand-crafted data-augmentations"; Figure 5's axis is "Pretraining GPU Hours" — [I-JEPA PDF §7](https://arxiv.org/pdf/2301.08243v3)
- I-JEPA's released ceiling was trained on ImageNet-1K/22K; DINOv2's was trained on LVD-142M — [I-JEPA checkpoints](https://github.com/facebookresearch/ijepa); [DINOv2 tables](https://arxiv.org/pdf/2304.07193v2). The Platonic-representation study attributes I-JEPA's weaker alignment partly to this: DINOv2 "saw far more curated images" — [arXiv:2610.39302](https://arxiv.org/html/2610.39302v1)
- DINOv2 ViT-B/14 is a *distilled* model that outperforms its own ViT-g/14 teacher on several instance-recognition columns (Paris-H 78.6 vs 82.6 is the teacher's win, but ViT-B/14 beats OpenCLIP ViT-G/14 everywhere: Oxford-H 49.5 vs 19.7) — [DINOv2 Table 9](https://arxiv.org/pdf/2304.07193v2)
- DINOv2 ViT-S/14 — smaller still — already scores Oxford-H 43.2 / AmsterTime 43.5, beating every non-DINOv2 baseline in the table including OpenCLIP ViT-G/14 (19.7 / 24.6) — [DINOv2 Table 9](https://arxiv.org/pdf/2304.07193v2)

### Inferences
- **The cost of adopting JEPA here is not an integration cost, it is an evaluation-plus-training cost.** You would have to (a) build the retrieval eval the literature never built, (b) discover — most likely — that frozen features underperform, and then (c) fund a fine-tune or a contrastive head on cover data to close the gap. Step (c) is training work on a $50/month budget. That is the definition of a research programme being mistaken for a deployment option.
- **The licence makes even the experiment inadvisable for I-JEPA/V-JEPA 1.** Time spent benchmarking a CC-BY-NC checkpoint cannot convert into a shipped feature, so the experiment has negative expected value regardless of how the numbers come out.
- **V-JEPA 2 is the only member worth a second look, and it still does not survive.** MIT licence, yes; 80M ViT-B available, yes. But it is a clip encoder with no retrieval evaluation, no inference benchmarks, no bf16-free validation, and a problem focus (anticipation, physical prediction, robot control) orthogonal to matching a photograph against a cover index. Adopting it would trade a measured capability for an unmeasured one.
- **The counterfactual is unusually strong, which is what settles it.** DINOv2 ViT-B/14 is Apache-2.0, ~86M params, and has a *published number on the exact protocol this product runs* — cosine-similarity nearest-neighbour over frozen features, 72.9/49.5 Oxford M/H, 90.3/78.6 Paris M/H, 45.6 AmsterTime. SigLIP 2 ViT-B/16 adds text-alignment, which a book product can use for title/author queries that no JEPA model can serve at all. Against two Apache-2.0 86M models with published evidence, a 600M non-commercial model with no retrieval evidence is not a close call.
- If there is residual curiosity, the cheap and correct version of it is a **two-hour local measurement, not an adoption**: build a small held-out set of cover photographs with known ISBNs, index with DINOv2 ViT-B/14 and SigLIP 2 ViT-B/16, and record top-1/top-5. That harness is needed anyway, is reusable, and would be the only legitimate way to ever evaluate a JEPA checkpoint later — if one ever ships under a permissive licence *with* a retrieval number.

### Gaps
- No cost model, pricing analysis, or budget-fit study for JEPA-family inference exists in any source found; the $50/month assessment here rests on parameter-count ratios and the absence of any published latency figure, not on measured serving cost.
- Whether a *fine-tuned* I-JEPA could match DINOv2 on cover retrieval is unknown and untested in the literature — but it is moot given the licence.
