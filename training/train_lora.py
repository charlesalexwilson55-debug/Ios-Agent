"""QLoRA fine-tune of Qwen3-8B on the Conduit dataset.

RUN THIS ON A RENTED GPU, NOT ON THE DEV MACHINE.

An 8B QLoRA needs roughly 12-16GB of VRAM. The machine this project is
authored on has an Intel UHD 620 with ~1GB of shared video memory and no CUDA
device at all, so training here is not slow — it is impossible. Verified
options, cheapest first:

  * Google Colab, free T4 (16GB)   — fits an 8B QLoRA at seq len 1024 with
                                     Unsloth. Tight; drop to Qwen3-4B if it OOMs.
  * Kaggle, 2x T4 or P100          — 30 free GPU-hours a week.
  * RunPod / Vast.ai A40 (48GB)    — about $0.40-0.80/hr; this job is well
                                     under an hour, so call it a dollar.

Before you spend anything, read docs/TRAINING.md. The honest recommendation is
to NOT fine-tune first: measure the base model with the system prompt, and only
train if you can point at a specific behaviour it gets wrong. mlx-swift-lm
already does tool-call recovery and argument normalisation, which removes most
of what a format LoRA would otherwise buy you.

Setup (Colab / Kaggle):
    !pip install -q unsloth
    !python train_lora.py --data conduit_sft.jsonl --out conduit-lora

Then see convert_adapter.py for getting the result onto the phone.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="unsloth/Qwen3-8B",
                        help="Base model. It must be the same model the phone runs, or the "
                             "adapter will not fit it: unsloth/Qwen3.5-4B for "
                             "Qwen3.5-4B-MLX-4bit, unsloth/Qwen3-4B for Qwen3-4B-4bit.")
    parser.add_argument("--data", default="data/conduit_sft.jsonl")
    parser.add_argument("--eval-data", default="data/conduit_sft_eval.jsonl")
    parser.add_argument("--out", default="conduit-lora")
    parser.add_argument("--max-seq-length", type=int, default=1536)
    # Rank 16 is deliberate. This LoRA teaches a response *style* and a set of
    # procedural habits, not new knowledge, and a high rank on a small dataset
    # is the fast route to a model that has memorised the templates and
    # forgotten how to handle anything else.
    parser.add_argument("--rank", type=int, default=16)
    parser.add_argument("--alpha", type=int, default=32)
    parser.add_argument("--epochs", type=float, default=2.0)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--grad-accum", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20260916)
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # Imported inside main so --help works on a machine with no GPU stack.
    from datasets import Dataset
    from trl import SFTConfig, SFTTrainer
    from unsloth import FastLanguageModel
    from unsloth.chat_templates import train_on_responses_only

    print(f"Loading {args.model}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model,
        max_seq_length=args.max_seq_length,
        # 4-bit base for training. Note this is independent of the 4-bit
        # quantisation used for inference on the phone — QLoRA quantises the
        # frozen base to save VRAM while training in higher precision adapters.
        load_in_4bit=True,
        dtype=None,
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=args.rank,
        lora_alpha=args.alpha,
        lora_dropout=0.05,
        bias="none",
        # Attention and MLP projections. Targeting attention alone is cheaper
        # but consistently weaker at changing response style, which is most of
        # what this dataset is for.
        target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
        use_gradient_checkpointing="unsloth",
        random_state=args.seed,
    )

    def load_rows(path: str) -> list[dict]:
        rows = []
        with Path(path).open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
        return rows

    def render(rows: list[dict]) -> Dataset:
        """Render each row through the model's own chat template.

        Passing `tools=` matters: Qwen's template injects the tool schemas into
        the system turn itself. Rendering without them trains the model on
        prompts that never show the tools, and at inference — where the tools
        ARE present — the prompt looks different from anything it saw. The
        result is a model that calls tools less reliably after training than
        before, which is a genuinely confusing way to waste a GPU hour.
        """
        texts = []
        for row in rows:
            texts.append(tokenizer.apply_chat_template(
                row["messages"],
                tools=row.get("tools"),
                tokenize=False,
                add_generation_prompt=False,
                # Conduit disables thinking at inference, so train on the same
                # prompt shape. A mismatch here shows up as the model emitting
                # stray <think> blocks into the transcript.
                enable_thinking=False,
            ))
        return Dataset.from_dict({"text": texts})

    train_rows = load_rows(args.data)
    train_dataset = render(train_rows)
    print(f"{len(train_dataset)} training rows")

    eval_dataset = None
    if Path(args.eval_data).exists():
        eval_dataset = render(load_rows(args.eval_data))
        print(f"{len(eval_dataset)} eval rows")

    print("\n--- first rendered example (check the tools appear in the system turn) ---")
    print(train_dataset[0]["text"][:1200])
    print("--- end ---\n")

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        args=SFTConfig(
            output_dir=f"{args.out}-checkpoints",
            dataset_text_field="text",
            max_seq_length=args.max_seq_length,
            per_device_train_batch_size=args.batch_size,
            gradient_accumulation_steps=args.grad_accum,
            num_train_epochs=args.epochs,
            learning_rate=args.lr,
            warmup_ratio=0.05,
            lr_scheduler_type="linear",
            logging_steps=10,
            optim="adamw_8bit",
            weight_decay=0.01,
            seed=args.seed,
            report_to="none",
            save_strategy="epoch",
            eval_strategy="epoch" if eval_dataset is not None else "no",
        ),
    )

    # Train on the assistant turns only.
    #
    # Without this the loss includes the system prompt and the user's messages,
    # so a large share of the gradient goes into learning to reproduce a system
    # prompt that is supplied verbatim at inference anyway. Worse, with a long
    # fixed system prompt repeated across every row, that term dominates and
    # the behavioural signal gets drowned.
    trainer = train_on_responses_only(
        trainer,
        instruction_part="<|im_start|>user\n",
        response_part="<|im_start|>assistant\n",
    )

    trainer.train()

    print(f"\nSaving adapter to {args.out}")
    model.save_pretrained(args.out)
    tokenizer.save_pretrained(args.out)

    print("""
Done. Two ways to get this onto the phone:

  A) Adapter only (small, ~50-150MB, keeps the base weights you already have):
         python convert_adapter.py --adapter {out} --out {out}-mlx
     Copy the resulting folder to the phone next to the model and pick it in
     Conduit's LoRA adapter list. This is the cheaper path and needs no Mac.

  B) Merged model (a full second copy of the weights, ~4.6GB):
         model.save_pretrained_merged("{out}-merged", tokenizer)
         python -m mlx_lm.convert --hf-path {out}-merged -q --q-bits 4 --mlx-path {out}-mlx-full
     mlx_lm only runs on Apple silicon, so this step needs a Mac or a macOS CI
     runner. Prefer (A) unless you have a specific reason not to.
""".format(out=args.out))


if __name__ == "__main__":
    main()
