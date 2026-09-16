# Training the model

You asked to "train this model so it knows its sole purpose is to help perform
tasks". Here is the honest version of how to do that, cheapest first.

## The recommendation: don't fine-tune yet

Not because fine-tuning is wrong, but because for *this* job most of what a
LoRA would buy you is already covered:

1. **The system prompt does the identity and procedure work.** Purpose, the
   `get_current_time`-first rule, the never-claim-a-send rule, the
   what-you-cannot-do list — all in `training/system_prompt.md`, applied every
   turn. Editing a text file and rebuilding beats a GPU run.

2. **`mlx-swift-lm` already handles format failures.** It ships
   `ToolCallRecoveryPolicy`, `TextToolCallRecoveryScanner` and
   `ToolArgumentNormalization` — so a slightly malformed tool call gets
   repaired by the framework rather than needing a model trained never to emit
   one. That was the main thing a format LoRA used to be for.

3. **Qwen3-8B is already a competent tool caller.** Tool use is a headline
   capability of the series, and the schemas here are small and
   well-described, with enums on the ambiguous arguments.

4. **4-bit quantisation costs more than the LoRA gains.** If tool calls are
   unreliable, the quantisation and the sampling settings are more likely the
   cause than the lack of a fine-tune. Conduit already pins Qwen's recommended
   non-thinking settings (temperature 0.7, top-p 0.8); above ~0.8 malformed
   calls climb noticeably.

**So: run the base model with the prompt for a week. Keep a list of the things
it actually gets wrong.** That list is worth more than any guess about what a
fine-tune would fix, and it becomes your eval set.

## When a LoRA is worth it

Specific, repeatable behaviours that prompting won't shift:

- It keeps saying "Sent!" when a message was only drafted. (Prompt says not to;
  small models drift on this under a long context.)
- It keeps skipping `get_current_time` and guessing dates.
- Replies are too long for a phone screen no matter how you word the prompt.
- You want a particular voice in the drafted messages.

All four are behaviour-shaping, which is exactly what a small LoRA is good at.

## Your hardware cannot do it

Intel UHD 620, ~1GB shared video memory, no CUDA device. An 8B QLoRA needs
12-16GB of VRAM. This is not "slow", it is "impossible" — there is no CUDA
backend to run on.

Options, cheapest first:

| Where | GPU | Cost | Notes |
|---|---|---|---|
| Google Colab | T4 16GB | free | Fits an 8B QLoRA with Unsloth at seq len 1024-1536. Tight; drop to 4B if it OOMs. |
| Kaggle | 2×T4 / P100 | free | 30 GPU-hours/week. More headroom than Colab. |
| RunPod / Vast.ai | A40 48GB | ~$0.40-0.80/hr | This job is well under an hour. Call it $1. |
| A borrowed Mac | M-series, 32GB+ | — | `mlx_lm.lora` trains natively; also the only way to run `mlx_lm.convert`. |

## The pipeline

### 1. Build the dataset (on Windows, no GPU)

```bash
python training/make_dataset.py
```

Writes `training/data/conduit_sft.jsonl` plus an eval split, and prints the
scenario mix. It first cross-checks `tools.json` against the tool names in the
Swift sources and refuses to run if they disagree — otherwise you can spend a
GPU hour teaching the model to call a tool the app doesn't have.

The mix is deliberately weighted away from the easy cases:

```
impossible          ~11%   refusing correctly, offering the Shortcuts route
message_awaiting    ~14%   "drafted, tap send" — the most valuable rows
ambiguous_contact    ~8%   asking which Sam, instead of texting the wrong one
permission_denied     ~6%   not retrying a denial
calendar/reminder   ~24%   the format baseline
multistep            ~9%   time → availability → contact → draft
```

Each scenario is filled to its own share rather than sampled from a common
pool. That matters: with a shared pool, the scenarios built from small template
vocabularies exhaust their unique combinations early and the others silently
absorb the shortfall, so the real mix ends up nothing like the declared
weights. The script reports any scenario it could not fill instead of hiding
it. If you see a `STARVED` line, add vocabulary to the lists at the top of the
file — that is the fix, not raising `--count`.

Read a few rows before training. Hand-check twenty examples; it is the single
highest-return thing you can do here.

### 2. Train (on the rented GPU)

```bash
pip install unsloth
python training/train_lora.py --data data/conduit_sft.jsonl --out conduit-lora
```

Defaults: rank 16, alpha 32, lr 1e-4, 2 epochs. Rank 16 is deliberate — this
teaches style and habits, not knowledge, and a high rank on ~1000 examples
memorises the templates and forgets everything else.

Two details in that script worth knowing about, because getting either wrong
makes the fine-tune actively worse than the base model:

- **Rows are rendered with `tools=`.** Qwen's chat template injects the tool
  schemas into the system turn. Render without them and you train on prompts
  where the tools are invisible, then run inference where they are present —
  the prompt shape doesn't match anything the model saw, and tool calling gets
  *less* reliable after training.
- **Loss is on assistant turns only** (`train_on_responses_only`). Otherwise a
  large fraction of the gradient goes into reproducing a long system prompt
  that is supplied verbatim at inference anyway, and it drowns the signal.

Also rendered with `enable_thinking=False`, matching what the app does, so the
model doesn't learn to emit stray `<think>` blocks into the transcript.

### 3. Get it onto the phone

**Adapter only — preferred.** ~100MB, no Mac needed, keeps the weights you have:

```bash
python training/convert_adapter.py --adapter conduit-lora --out conduit-lora-mlx
```

peft and MLX disagree on three things — the weights filename, the tensor key
names, and the orientation of the A/B matrices (peft stores `[r, in]` and
`[out, r]`; MLX wants `[in, r]` and `[r, out]`). The script handles all three
and refuses to write a partial adapter if any projection is missing a half.

**Caveat worth stating plainly:** that converter was written against both
documented formats but has never been run on a real trained adapter, because
producing one needs a GPU this project doesn't have. Verify the first run
rather than trusting it. If the app loads the adapter and quality gets *worse*,
suspect the transposes first.

Copy the output folder onto the phone via Files, then pick it in Conduit under
Model → LoRA adapter, and reselect the model.

**Merged model — only if you must.** A full second 4.6GB copy:

```python
model.save_pretrained_merged("conduit-merged", tokenizer)
```
```bash
python -m mlx_lm.convert --hf-path conduit-merged -q --q-bits 4 --mlx-path conduit-mlx
```

`mlx_lm` is Apple-silicon only, so this step needs a Mac or a macOS CI runner.
There is no Windows path. Prefer the adapter.

## Don't bake the persona into the weights

Keep identity and purpose in the system prompt, not the LoRA.

The prompt is a text file you can edit and ship in a rebuild. A persona in the
weights needs a GPU to change, applies to every request whether or not you want
it, and interacts badly with swapping the base model — which you will do, since
this app is built around choosing whichever model you like. Train *behaviours*
(report honestly, check the clock, keep it short). State *identity* in the
prompt.
