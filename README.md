# Conduit

A Liquid Glass command bar at the bottom of your iPhone, driving a local LLM
that does things on the phone: calendar, reminders, contacts, messages, calls,
email, and your own Shortcuts. Everything runs on-device. Nothing leaves the
phone, and it works with airplane mode on.

Built for an iPhone 17 Pro on iOS 26, authored entirely on Windows, compiled on
a GitHub Actions macOS runner.

---

## Read this first: what "local" does and does not buy you

Running the model on the phone gives you real things: privacy, offline
operation, no API bill, no rate limit.

It does **not** give you more control over the phone. iOS decides what an app
may do, and that answer is identical whether the model runs in your pocket or
in a datacentre. The relevant limits:

| You want | Reality |
|---|---|
| Send a text / email | The app fills in the whole thing; **you tap send**. No public API sends on an app's behalf. |
| Place a call | Can be started; iOS shows a confirmation. Cannot answer or hang up. |
| Read your texts / email / notifications | **Not possible.** iOS exposes none of it to apps. |
| Calendar, reminders | **Fully automatic**, no taps, once permission is granted. |
| Contacts lookup | Automatic. |
| Set an alarm, Focus mode, Wi-Fi, settings | Not directly. **Run a Shortcut that does it.** |
| Create a Shortcut | Not possible. Only run ones you already made. |

So the shape of the app follows from that: calendar and reminders are where it
genuinely automates; messaging is a very good drafting assistant; and
**Shortcuts is the escape hatch** for everything else. You build a shortcut
once, name it, and the model can run it by name forever after. Conduit also
exposes itself *to* Shortcuts and Siri via an App Intent, so automation flows
both ways.

This is stated plainly in the app itself, under Model → "What Conduit can and
cannot do", and it is baked into the model's system prompt so it never claims
to have sent something it only drafted.

## How it works

```
GlassCommandBar ──▶ AgentSession ──▶ ModelRunner ──▶ mlx-swift-lm ──▶ Qwen3 4-bit
                          │
                          └──▶ ToolRegistry ──▶ PeopleTools / CalendarTools / DeviceTools
                                                        │
                                                        └──▶ EventKit, Contacts,
                                                             MessageUI, Shortcuts
```

- **`mlx-swift-lm`** (`ml-explore/mlx-swift-lm`, 3.31.3) does inference. It has
  first-class tool calling: tools are declared as JSON schemas, and tool calls
  arrive as typed `.toolCall` stream events rather than tags to be parsed out
  of the text. It also ships malformed-call recovery and argument
  normalisation, which is most of why no fine-tune is needed to get started.
- **All MLX API usage is confined to `App/Model/ModelRunner.swift`.** Nothing
  else in the app imports it. This project can't be compiled on Windows, so
  concentrating the fast-moving dependency in one file means an API change is
  one file to fix.
- **Tool results are values, not exceptions.** Every tool returns
  `{ok, action, summary, detail, error}`. A failed tool call is ordinary
  conversation the model should read and react to, not a thrown error that
  kills the turn. Error strings are written *for the model*, saying what was
  wrong and what to try instead.
- **`ToolFriction`** labels each tool `silent`, `requiresConfirmation`, or
  `leavesApp`, and the system prompt is generated from those labels — so the
  honesty rules cannot drift from the actual tools.

## Layout

```
project.yml                  XcodeGen manifest (no .xcodeproj is committed)
Support/                     Info.plist, entitlements
App/
  ConduitApp.swift           App entry, root view, model loading
  UI/                        GlassCommandBar, TranscriptView, ModelPicker, Capabilities
  Model/                     ModelCatalog (discovery/import), ModelRunner (all MLX)
  Agent/                     AgentSession loop, ToolRegistry, SystemPrompt, the tools
  Services/                  Permissions, ComposePresenter
  Intents/                   App Intents, so Shortcuts and Siri can call Conduit
scripts/                     build-ios.sh, verify-ipa.py, make-icons.py
training/                    dataset generator, LoRA training, adapter conversion
docs/                        SETUP.md, TRAINING.md
```

## Getting it on the phone

Short version: push to GitHub, download the artifact, re-sign with Sideloadly.

```bash
git push
# then download Conduit-unsigned-ipa from the Actions run
```

Full instructions, including the entitlements step that an 8B model depends
on: **[docs/SETUP.md](docs/SETUP.md)**.

## Getting a model on the phone

Conduit lists any model folder it finds in its Documents or Application
Support directories, so the easiest route is to download on a computer and copy
the folder across via the Files app.

```bash
pip install mlx-lm huggingface_hub
huggingface-cli download mlx-community/Qwen3-4B-4bit --local-dir Qwen3-4B-4bit
```

Then Files → On My iPhone → Conduit → paste the folder. It appears in the model
picker.

**On the 8B.** `mlx-community/Qwen3-8B-4bit` is about 4.6GB of weights, and
with KV cache and working memory it wants ~6.5GB live on a 12GB phone. That
needs the `increased-memory-limit` entitlement (included, see SETUP) and it
will still be slow and thermally limited. **Start with `Qwen3-4B-4bit.`** For
this workload — pick a tool, fill in the arguments, write one sentence — the
4B is close to the 8B and several times more pleasant to use. The picker warns
you when a model looks too big for the device rather than letting iOS kill the
app mid-sentence.

## The model's "training"

Two layers, and the first is probably all you need:

1. **The system prompt** (`training/system_prompt.md`, generated at runtime by
   `SystemPrompt.swift`). This is what tells the model its sole purpose is
   executing tasks, that it must call `get_current_time` before any relative
   date, and that it must never claim a message was sent when it was only
   drafted. No training required; edit and rebuild.

2. **An optional LoRA** for when you can point at a specific behaviour the
   prompt doesn't fix. `training/make_dataset.py` builds a balanced dataset
   (runs on Windows, no GPU); `train_lora.py` trains it on a rented GPU;
   `convert_adapter.py` converts the result into the format the app loads at
   runtime — a ~100MB adapter folder, not a second copy of the weights.

Your machine (Intel UHD 620, no CUDA) cannot train an 8B model, so step 2
means Colab, Kaggle, or about a dollar of RunPod. See
**[docs/TRAINING.md](docs/TRAINING.md)** for the honest cost/benefit.

## Status

The Swift has never been compiled — there is no Swift toolchain on Windows, and
this repo's first real build will be the first CI run. Expect to fix things.
The Python is tested and working:

```bash
python scripts/make-icons.py                  # generates the app icon
python training/make_dataset.py               # builds the dataset + checks tool drift
```

`make_dataset.py` cross-checks `training/tools.json` against the tool names in
the Swift sources and fails if they disagree, so the dataset can't quietly
train the model to call tools the app doesn't implement.
