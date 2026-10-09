# On-device model evaluation

Generate the suite with `python scripts/make-model-evaluation.py`. It contains 50 cases per installed model: 15 JavaScript coding tasks, 15 phone tasks, 10 general questions and 10 source-based research questions. The production inference engine, tokenizer, system prompts, memory limits and tool schemas are used. Each case starts with a fresh context. Personal memories, profiles and chat history are excluded.

Copy the generated JSON to the app's `Documents/Evaluation/request.json`, then open Conduit. This is an explicit QA entry point, not normal chat behavior. Leave the app visible. The app pauses when it leaves the foreground and resumes on return. Stop tests cancels the request. Results are saved incrementally to `Documents/Evaluation/<request-id>/results.jsonl`. A checkpoint makes an interrupted case visible after a process crash. A request ID cannot be reused with different test content.

Only installed model directory names are accepted. The test runner never changes the selected model or invokes phone-action providers. Messages, calendar changes and other phone actions use fixture results; JavaScript uses the existing bounded in-app sandbox. Research cases use synthetic pages about fictional people. These tests measure source extraction, name disambiguation, instruction following and tool selection. They do not measure live search coverage or actual message delivery. The vision specialist receives the same text questions for comparison; its image accuracy requires an additional image-specific suite.

Answers, tool calls, errors, elapsed time, tokens per second and peak MLX allocation are recorded. Private reasoning is not exported. A load rejection is recorded as `blocked_load` for the affected cases, not as 50 generated answers. Memory and thermal safeguards stay enabled. Generation is capped at 512 tokens per round, four tool rounds, and 240 seconds per case; this is a bounded non-thinking baseline. Follow up with production thinking-mode stress tests on failures.

Score copied results with `python scripts/score-model-evaluation.py artifacts/evaluation/suite.json artifacts/evaluation/results.jsonl`. Generated JavaScript functions are checked against multiple independent inputs in a restricted, timed VM. Missing cases, interrupted cases and load failures never pass. A reported failure needs diagnosis before changing prompts, routing or model files. Keep raw answers for comparison, and rerun failed cases after a fix with a new request ID.
# Device findings, 9 October 2026

Build 78 produced actual device answers. MiniCPM5 emitted its documented XML
`function`/`param` protocol as visible text because the pinned MLX parser did
not recognize it. A schema-checked decoder now handles that protocol, excluding
fenced examples and refusing incomplete, duplicate or unknown arguments.

A rapid inactive/active transition during Qwen3.5 testing also exposed an
inference cleanup race. Cancelling the stream did not await its underlying
producer, so a resumed load could see the old model still occupying memory.
The runner now retains and awaits the producer before releasing its gate.
Evaluation resumes after the paused worker drains, and disables automatic
screen locking only while tests run. Manual backgrounding still pauses tests.

The 9B folder is incomplete on this device: its index declares 5,950,062,560
bytes of tensor data, but the two copied shards total only 1,193,110,620 bytes.
Catalog validation excludes those shards. A blocked model is reported
separately from failed generated answers; it must never count as 50 tested
responses. Repairing that download also does not establish that the full
model fits the unsigned app's memory allowance.
