# Evidence-grounded research implementation plan

**Goal:** Implement the user-approved pasted workflow in the existing iPhone app.

**Architecture:** A native coordinator advances through planning, discovery, extraction, identity resolution, verification, gap analysis and reporting. A local SQLite archive stores bounded, source-specific claims and checkpoints. The loaded local model performs short stage-specific jobs sequentially; no forced 9B download or concurrent MLX models.

**Constraints:** iOS 26+, Swift 5, no server backend, no real personal fixtures or API keys in the repository. Public professional information only. Identity scores are uncalibrated evidence scores, never probabilities or guarantees. Missing information is unknown. User selection narrows scope, not evidence of identity.

- [ ] Add production-code tests for separate same-name profiles, independent corroboration, copied pages, fabricated quotations, conflicting contemporaneous claims, privacy/injection filtering, canonical URLs, bounded rounds, cancellation and checkpoint round trips.
- [ ] Add graph types and deterministic verification in `App/Agent/ResearchGraph.swift`: sources, entities, evidence, claims, identity candidates, relationships, contradictions, gaps and searches. Retain quotes with dates and URLs. Merge only when grounded distinguishing attributes connect profiles; never infer transitive personal relationships.
- [ ] Add `ResearchStore.swift`: transactional SQLite run snapshots and separately queryable graph records. Preserve interrupted work; resume explicitly with remaining budgets, do not restart automatically or duplicate completed searches.
- [ ] Replace the page-following loop with `ResearchCoordinator.swift`. Broaden discovery, canonicalize/rank/filter before reading selected pages, validate structured extraction, resolve and verify, search grounded gaps, and stop on no progress or hard search/page/round/time/model-text budgets. Existing `ResearchEngine` remains a compatible facade for chat and planning helpers.
- [ ] Add Exa discovery and selected-page extraction alongside Tavily; preserve existing keys and support either provider. No encyclopedia fallback in research. Separate provider setup and tests. This disjoint work is delegated to one builder.
- [ ] Integrate a Research archive/detail page and explicit resume. Reports keep identities and evidence separated and show contradictions, skipped work and stop reason even if model generation fails.
- [ ] Run Swift regression executables in macOS CI, build/verify the IPA, obtain one focused expert review, resolve findings, publish and load the verified version into Sideloadly.

**Validation:** Network fixtures exercise real provider parsers without paid requests. Graph tests exercise actual Swift types, not a Python reimplementation. macOS CI compiles Foundation/SQLite tests and the iOS archive. Device inference requires the connected phone; no on-device performance claim follows from CI alone.
