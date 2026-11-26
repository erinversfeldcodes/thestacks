# mypy: disable-error-code="untyped-decorator"
"""Modal serving for the dialogue model: scale-to-zero with per-session DEMAND
WAKE, and NO idle keep-warm.

The responsiveness ruling bans paying to stay warm, so there is no scheduled
ping and no always-on replica: `min_containers` defaults to 0, a container spins
up on the first request of an editing session, and `scaledown_window` bills only
a short idle tail before it scales back to zero. This serves on the EXISTING
scale-to-zero GPU family (A10G), as the issue requires.

The base model answers by default. A user's LoRA adapter is loaded ONLY behind a
SHIPPED marker written when the privacy ship-gate cleared it — the gate's verdict
is honoured at the serving seam, not merely recorded, so a failed or un-evaluated
adapter never serves. RUN BY THE OWNER on Modal.
"""

from __future__ import annotations

import modal

BASE_MODEL = "meta-llama/Llama-3.1-8B-Instruct"
ADAPTER_ROOT = "/adapters"
SHIPPED_MARKER = "SHIPPED"

app = modal.App("stacks-dialogue")

image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "torch==2.5.1",
    "transformers==4.46.3",
    "peft==0.13.2",
    "accelerate==1.1.1",
)

adapters = modal.Volume.from_name("stacks-lora-adapters", create_if_missing=True)


@app.cls(
    image=image,
    gpu="A10G",
    volumes={ADAPTER_ROOT: adapters},
    # Per-session demand wake, no keep-warm: min_containers is left at its default
    # of 0 (nothing runs between sessions), and the container bills only this idle
    # tail after the last request before scaling to zero. No scheduled ping.
    scaledown_window=60,
)
class DialogueModel:
    @modal.enter()
    def load(self) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL)
        if self.tokenizer.pad_token is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token
        self.model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL, torch_dtype=torch.bfloat16, device_map="auto"
        )

    @modal.method()
    def complete(self, prompt: str, user_id: str | None = None, max_new_tokens: int = 256) -> str:
        """Generate a completion. A user's adapter is applied ONLY when a SHIPPED
        marker sits beside it (the ship-gate cleared it); otherwise the base model
        serves, which is the RAG-only default."""
        import os

        import torch

        model = self.model
        if user_id and os.path.exists(f"{ADAPTER_ROOT}/{user_id}/{SHIPPED_MARKER}"):
            from peft import PeftModel

            model = PeftModel.from_pretrained(self.model, f"{ADAPTER_ROOT}/{user_id}")

        ids = self.tokenizer(prompt, return_tensors="pt").to(model.device)
        with torch.no_grad():
            out = model.generate(**ids, max_new_tokens=max_new_tokens, do_sample=False)
        return str(
            self.tokenizer.decode(out[0][ids["input_ids"].shape[1] :], skip_special_tokens=True)
        )
