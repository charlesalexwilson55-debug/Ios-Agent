# Conduit research and interface implementation plan

**Goal:** Apply the user-approved research, settings, image, startup and model changes in one iOS build.
**Architecture:** Keep existing research evidence rules and extend selection to multiple explicitly chosen sources. Reuse the existing image reading pipeline from the chat composer. Preserve the existing offline model import path.
**Tech stack:** SwiftUI, ActivityKit, PhotosUI, Core ML, MLX Swift.
**Approved design:** Chat approval on 2026-10-10: multiple sources for one person, 1.2-second launch reveal, simplified settings, chat image attachments, supported Dynamic Island presentation, official Ornith MLX download, licensed 3D logos only where available.
**Constraints:** Work solo. No sensor overlap or added Live Activity buttons. Do not start installation without an explicit install request. Verify and load each successful current IPA into Sideloadly.

- [ ] Research: add selection-list compatibility and regression cases; remove duplicate text choices; add checked cards and one submit button; preserve per-source provenance in reports.
- [ ] Settings: persist a profile photo outside prompt context; remove usage list below badge, navigation controls, energy comparison section and research quality picker; automatically validate and save one Exa/Tavily key input.
- [ ] Images: attach Photos items in chat; show removable attachment previews; reuse AgentSession imageData; crop created images on the left with fullscreen original.
- [ ] Motion: restore orb travel and a blue radial explosion; simplify Dynamic Island to supported orb regions and white keyline.
- [ ] Models: verify Ornith MLX compatibility and hashes, download pinned weights; transfer through iTunes file sharing; search for licensed logo assets and retain icons where none are verified.
- [ ] Delivery: review touched files, run local checks and native CI, fix relevant failures, verify current IPA and load Sideloadly.
