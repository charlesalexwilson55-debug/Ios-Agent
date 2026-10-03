# Inference and research routing

Conduit retains the MLX/Metal and Edge0 backends that load the existing phone
models. A cancellation-aware FIFO gate serializes model load, generation and
suspension. Swift actor reentrancy alone did not provide that guarantee across
asynchronous generation. Queued cancelled requests are removed without stealing
a later request's permit.

Research dispatches one initial search to detect terminal provider failures,
then at most two independent searches concurrently. Page extraction and model
generation stay sequential. Individual operations and the whole run remain
cancellable. Dispatched queries are checkpointed before execution, duplicate
URLs are retained only once, and provider quota errors stop further dispatch.

Web work only unloads the language model when memory headroom falls below the
reserve for web rendering. MLX retains its bounded 32 MB allocator cache between
healthy turns. Streaming UI updates are coalesced to at most 20 per second and
flush the final answer. Diagnostics record queue delay, first-token latency,
prefill time, actual completion tokens and throughput. These are runtime
measurements; the change does not claim a measured phone speedup.

The research switch no longer overrides conversation intent. Corrections such
as “Payton is a boy” remain user-provided context, are not verified facts and do
not trigger searches. Acknowledgements and questions about the assistant use
normal conversation. “Find more” preserves the previous subject and selected
profile. Explicit requests to research a new subject start a new investigation.
Topic planning supports a grounded topic declaration instead of forcing every
two-word subject into a person's name. Follow-up topic queries remain anchored
to that topic, rather than searching for generic professional biographies.

Requests for additional information continue beyond the first matching source.
Identity claims still require source quotations. User corrections cannot become
evidence merely because the local model repeats them.

Validation covers single-lane GPU admission, queued cancellation and permit
recovery, two-search concurrency, terminal-provider failures, conversation
routing, topic planning, source attribution and previous research regressions.
