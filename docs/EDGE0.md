# Streaming Edge0 models

Conduit keeps its existing MLX backend and adds the Apache-2.0 Edge0 iOS engines
as a separate backend. The source revision and local changes are recorded in
`Vendor/Edge0/UPSTREAM.md`; upstream licenses remain alongside that code.

On Models, select **Download directly to iPhone**. Edge0 8B requires about 5 GB;
Edge0 35B requires about 20 GB, plus 2 GB of preparation headroom. Keep Conduit
open, preferably on Wi-Fi and power. No checkpoint is stored on the computer or
included in the IPA. Pausing retains completed tensors; pressing Download resumes
the same pinned checkpoint. Incomplete installations remain hidden from the picker.

For 35B, the downloader reads shard headers through HTTP byte ranges, then downloads
individual tensors to a temporary file. It scatters stacked expert tensors into
40 per-layer files, extracts resident tensors, converts the tokenizer, and transposes
the trained fp16 prerouter heads. Every resident and expert write is read back and
compared with its source. Only the current tensor needs temporary storage. Full
checkpoint shards are never downloaded. Original weights are not requantized.

The runtime renders the complete supplied chat and tool results, isolates thinking,
and parses both JSON and Qwen XML tool calls before handing them to the existing
tool policy. The first profile limits prompts to 24,000 UTF-8 bytes and answers to
2,048 tokens or the user's lower limit. Prefill batches are reduced for phone memory.
Cancellation, thermal checks, available-memory checks, and usage recording remain active.

These are experimental models. The upstream Mac allocator benchmark is not an iPhone
memory guarantee. Validate total process footprint, cold and warm speed, battery,
long-context behavior, and actual tool accuracy on the device before relying on 35B.

CI tests verify expert offsets, rejection of invalid shapes, tokenizer serialization,
fp16 prerouter transposition, fragmented protocol tags, JSON/XML tool calls, malformed
calls, and tool-result history before compiling the app.
