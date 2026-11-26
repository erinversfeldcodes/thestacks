# Corpus LoRA — training your writing into an adapter, safely

This is the tooling to fine-tune a small LoRA adapter on **your own writing** and
prove it is safe to use before anything does. **RAG-only is the default and
always available**; a LoRA is an optional enhancement that ships *only* if it
clears the privacy ship-gate. You run the training; the gate decides.

> ⚠️ A LoRA memorises. The research behind the gate saw a canary repeated 16
> times reproduced *in full* on a 7B LoRA, and membership-inference at ~0.9 AUC —
> a small corpus over a few epochs crosses the memorisation threshold for every
> document. That is why the gate is a hard precondition, not a nicety.

## The pipeline

```
your writing (.txt/.md)
   │
   ▼  prepare_corpus.prepare()         near-dup DEDUP + paragraph packing
   │                                   + planted CANARIES (16×, the threshold)
   ▼  modal_app.train()                PEFT LoRA: LOW rank, FEW epochs, DROPOUT
   │                                   → adapter saved under your user id
   ▼  modal_app.evaluate()             the ship-gate, three independent vetoes:
   │                                     • canary   — did it recite a planted marker?
   │                                     • extraction — did it reproduce a long run
   │                                                    of a training document?
   │                                     • MIA      — can members be told from held-out?
   ▼  privacy_eval.ship_decision()     SHIP only if every veto is clear
```

The three pieces split by testability:

| File | What | Tested |
|------|------|--------|
| `prepare_corpus.py` | dedup + packing + canary planting | ✅ unit (`tests/test_lora_prepare_corpus.py`) |
| `privacy_eval.py` | the ship-gate metrics + `ship_decision` | ✅ unit (`tests/test_lora_privacy_eval.py`) |
| `modal_app.py` | the Modal GPU train + eval harness | ▶ you run it on Modal |

## Run it

From `apps/vision/`, with Modal configured (`modal token new` once):

```sh
modal run app/lora/modal_app.py --docs-dir ./path/to/your/writing --user-id <you>
```

It reads your `.txt`/`.md` files, holds **2 documents out** (never trained on, so
the membership-inference test has true non-members), prepares and trains on the
rest, then runs the ship-gate and prints a verdict:

```json
{ "ship": false, "reasons": ["canary leak rate 0.125 exceeds 0.0"], ... }
```

- `ship: true` → the adapter cleared the gate and may be used. RAG-only stays
  available as the fallback.
- `ship: false` → **do not use the adapter.** The reasons name which veto fired.
  RAG-only remains the default — nothing downstream changes.

Richer formats (PDF/ePub/DOCX) go through the vision document extractor first, or
export them to text; the pipeline takes text in.

## Knobs (all have safe defaults)

| Where | Knob | Default | Note |
|-------|------|---------|------|
| `train()` | `base_model` | `meta-llama/Llama-3.1-8B-Instruct` | your chosen base |
| `train()` | `rank` / `epochs` / `dropout` | `16` / `2` / `0.1` | the anti-memorisation mitigations — keep them low |
| `main()` | `holdout` | `2` | documents reserved as MIA non-members |
| `prepare()` | `canary_count` / `canary_repeats` | `8` / `16` | 16× is the threshold the gate must prove safe |
| `ShipThresholds` | canary `0.0`, extraction `50`, MIA `0.60` | — | the ship bar; tighten, don't loosen |

Versions, GPU type and corpus size are account-specific — adjust in `modal_app.py`.

## Handling — this is sensitive

Your prose is the most sensitive text the platform holds, and a trained adapter
is a derived copy of it. So:

- The training sequences live only **in memory** during the Modal run; only the
  adapter weights are written, under your user id.
- The adapter is handled at the **corpus's data classification** and MUST become
  reachable by account erasure. The core-side cleanup that deletes the adapter
  artifact on erasure / consent revocation is the remaining piece of this work;
  until it lands, delete a user's Modal adapter volume by hand if you erase them.
- Never commit an adapter, a prepared corpus, or an eval log to the repo.
