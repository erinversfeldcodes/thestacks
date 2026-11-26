"""Modal app for the corpus LoRA: train an adapter on the author's own writing,
then run the privacy ship-gate against it.

RUN BY THE OWNER on Modal GPU. RAG-only is the default; the adapter ships ONLY if
the eval clears `ship_decision`:

    modal run app/lora/modal_app.py --docs-dir ./my-writing --user-id me

The author's prose is sensitive. It lives only in memory during training and is
never written to the volume; ONLY the adapter weights are saved, under the user's
id, so the Elixir erasure path can reach them (see the lora-adapter record +
cleanup on the core side). The held-out split the membership-inference test needs
is carved off here so those documents are never trained on.

⚠️ Versions, GPU type and hyper-parameters are starting points — adjust to what
runs on your Modal account and corpus size. The mitigations (LOW rank, FEW
epochs, DROPOUT, and the near-dup dedup already done in prepare_corpus) are the
load-bearing part; keep them.
"""

# mypy: disable-error-code="untyped-decorator"
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import modal

from app.lora.prepare_corpus import prepare
from app.lora.privacy_eval import (
    canary_leak_rate,
    extraction_overlap,
    mia_auc,
    ship_decision,
)

BASE_MODEL = "meta-llama/Llama-3.1-8B-Instruct"
ADAPTER_ROOT = "/adapters"

app = modal.App("stacks-lora")

image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "torch==2.5.1",
    "transformers==4.46.3",
    "peft==0.13.2",
    "datasets==3.1.0",
    "accelerate==1.1.1",
)

adapters = modal.Volume.from_name("stacks-lora-adapters", create_if_missing=True)


@app.function(image=image, gpu="A100-40GB", volumes={ADAPTER_ROOT: adapters}, timeout=60 * 60)
def train(
    sequences: list[str],
    user_id: str,
    base_model: str = BASE_MODEL,
    rank: int = 16,
    epochs: int = 2,
    dropout: float = 0.1,
    learning_rate: float = 2e-4,
) -> str:
    """Train a LoRA adapter on the prepared sequences and save it to the volume
    under the user's id. The anti-memorisation mitigations are LOW rank, FEW
    epochs and DROPOUT here (near-dup dedup already applied upstream)."""
    import torch
    from datasets import Dataset
    from peft import LoraConfig, get_peft_model
    from transformers import (
        AutoModelForCausalLM,
        AutoTokenizer,
        DataCollatorForLanguageModeling,
        Trainer,
        TrainingArguments,
    )

    tokenizer = AutoTokenizer.from_pretrained(base_model)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        base_model, torch_dtype=torch.bfloat16, device_map="auto"
    )

    lora = LoraConfig(
        r=rank,
        lora_alpha=rank * 2,
        lora_dropout=dropout,
        target_modules=["q_proj", "v_proj"],
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora)

    def tokenize(batch: dict[str, Any]) -> Any:
        return tokenizer(batch["text"], truncation=True, max_length=1024)

    dataset = Dataset.from_dict({"text": sequences}).map(
        tokenize, batched=True, remove_columns=["text"]
    )

    out_dir = f"{ADAPTER_ROOT}/{user_id}"
    args = TrainingArguments(
        output_dir=out_dir,
        num_train_epochs=epochs,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        learning_rate=learning_rate,
        bf16=True,
        logging_steps=10,
        save_strategy="no",
        report_to=[],
    )
    trainer = Trainer(
        model=model,
        args=args,
        train_dataset=dataset,
        data_collator=DataCollatorForLanguageModeling(tokenizer, mlm=False),
    )
    trainer.train()
    model.save_pretrained(out_dir)
    adapters.commit()
    return out_dir


@app.function(image=image, gpu="A100-40GB", volumes={ADAPTER_ROOT: adapters}, timeout=60 * 30)
def evaluate(
    adapter_dir: str,
    canaries: list[str],
    canary_prefixes: list[str],
    extraction_prefixes: list[str],
    true_continuations: list[str],
    member_texts: list[str],
    nonmember_texts: list[str],
    base_model: str = BASE_MODEL,
) -> dict[str, object]:
    """Run the three ship-gate vetoes against the fine-tuned model and return
    `ship_decision`'s verdict. This is the ONLY authority on whether the adapter
    may ship; a failure leaves RAG-only in place."""
    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(base_model)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    base = AutoModelForCausalLM.from_pretrained(
        base_model, torch_dtype=torch.bfloat16, device_map="auto"
    )
    model = PeftModel.from_pretrained(base, adapter_dir)
    model.eval()

    def generate(prompt: str, max_new_tokens: int = 64) -> str:
        ids = tokenizer(prompt, return_tensors="pt").to(model.device)
        out = model.generate(**ids, max_new_tokens=max_new_tokens, do_sample=False)
        return str(tokenizer.decode(out[0][ids["input_ids"].shape[1] :], skip_special_tokens=True))

    def mean_loss(text: str) -> float:
        ids = tokenizer(text, return_tensors="pt").to(model.device)
        with torch.no_grad():
            return float(model(**ids, labels=ids["input_ids"]).loss)

    leak = canary_leak_rate([generate(p) for p in canary_prefixes], canaries)
    extraction_gens = [generate(p) for p in extraction_prefixes]
    runs = [
        extraction_overlap(gen, cont)
        for gen, cont in zip(extraction_gens, true_continuations, strict=True)
    ]
    auc = mia_auc([mean_loss(t) for t in member_texts], [mean_loss(t) for t in nonmember_texts])

    decision = ship_decision(leak, runs, auc)
    return {
        "ship": decision.ship,
        "reasons": decision.reasons,
        "canary_leak_rate": leak,
        "max_extraction_run": max(runs, default=0),
        "mia_auc": auc,
    }


def _read_docs(docs_dir: str) -> list[str]:
    root = Path(docs_dir)
    texts: list[str] = []
    for pattern in ("*.txt", "*.md"):
        texts.extend(p.read_text(encoding="utf-8") for p in sorted(root.rglob(pattern)))
    if not texts:
        raise SystemExit(
            f"no .txt/.md documents under {docs_dir}. Convert other formats first "
            f"(the vision document extractor does this), or point at a directory of text."
        )
    return texts


@app.local_entrypoint()
def main(docs_dir: str, user_id: str, holdout: int = 2) -> None:
    """Orchestrate the pipeline: read the author's text, carve off `holdout`
    documents as membership-inference NON-members (never trained on), prepare +
    train on the rest, then run the ship-gate and print the verdict."""
    documents = _read_docs(docs_dir)
    if len(documents) <= holdout:
        raise SystemExit(f"need more than {holdout} documents; found {len(documents)}.")

    nonmembers, members = documents[:holdout], documents[holdout:]
    prepared = prepare(members)

    adapter_dir = train.remote(prepared.sequences, user_id)

    # Canary prefixes are the first half of each planted canary; extraction uses
    # the opening of each member document against its true continuation.
    canary_prefixes = [
        " ".join(c.split()[: max(1, len(c.split()) // 2)]) for c in prepared.canaries
    ]
    extraction_prefixes = [" ".join(m.split()[:20]) for m in members]
    true_continuations = [" ".join(m.split()[20:120]) for m in members]

    result = evaluate.remote(
        adapter_dir,
        prepared.canaries,
        canary_prefixes,
        extraction_prefixes,
        true_continuations,
        members,
        nonmembers,
    )

    print(json.dumps(result, indent=2))
    if result["ship"]:
        print("\nSHIP: the adapter cleared the privacy gate. (RAG-only remains available.)")
    else:
        print("\nDO NOT SHIP -- RAG-only stays the default. Reasons:")
        for reason in result["reasons"]:
            print(f"  - {reason}")
