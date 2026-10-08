# Local task models

Conduit downloads compatible, pinned model files straight onto the iPhone from Models. Downloads use Wi-Fi, save completed files in hidden staging directories, check file sizes and LFS SHA256 hashes, and publish a model only after validation. Keep the app open during a download. A cancelled large file must restart; completed files are reused.

- MiniCPM5-1B: OpenBMB's official 4-bit MLX release. 1,080,632,832 parameters; 608,026,621 bytes of weights, approximately 618 MB including the tokenizer. Standard Llama architecture supported by the pinned MLX Swift runtime. It is a text model, not a vision model. Automatic routing uses it for short rewrites/translations and research planning/extraction with no tools. Its native XML tool syntax differs from the pinned parser, so automatic phone actions stay on the selected chat model.
- Qwen3-VL-2B-Instruct-4bit: approximately 1.80 GB including processor/tokenizer files. The image reader puts the chat model aside, describes images, then restores the chat model. Apple Vision remains the OCR fallback. This model reads images; it does not generate them.
- Edge0-35B-A3B-preview: experimental expert streaming, approximately 19.5 GB of tensor payloads on storage. Automatic routing uses it for heavy code/proof requests only once installation is complete. The published Mac working-memory benchmark does not prove iPhone speed, stability, or memory consumption.

Models > Model routing permits explicit research, heavy-work and image assignments. Turn automatic routing off to retain the selected text model for all text tasks. Missing or failed optional models fall back to the selected chat model. Only one text/vision model is kept resident during these routes. The existing inference queue serializes text GPU jobs while independent web queries can run concurrently.

MiniCPM source: https://huggingface.co/openbmb/MiniCPM5-1B-MLX
Qwen vision source: https://huggingface.co/mlx-community/Qwen3-VL-2B-Instruct-4bit

# Startup artwork

The startup mark is an original rendered PNG generated with the built-in image generation tool. Prompt: “Photorealistic polished silver chrome hollow horizontal capsule ring, front-facing, narrow dimensional silver rim, empty transparent centre and transparent background, no text, no feet or end bars, understated premium industrial finish.”

The asset is bundled in StartupConduitChrome.imageset. A short pullback, crossing, glow and dissolve replaces the procedural particle explosion. Reduced Motion uses a fade. The existing Appearance startup toggle and orb colour still apply. A rare extra return crossing is retained. Startup waits for loading to finish before revealing the app; this is not a timer claiming the model is ready.
