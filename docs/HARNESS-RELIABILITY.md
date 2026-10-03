# Reliability update

The chat viewport and footer now occupy separate regions of a vertical layout. The viewport is clipped above the composer, and streamed scrolling waits for the row mutation to reach layout rather than repeatedly starting competing animations.

Model colour swatches use independent plain buttons within the list and show a live conduit preview. Recall passages remain internal context. Previous recall chips are hidden when displaying saved conversations. Conversation memory is retrieved for personal or retrospective requests, rather than being attached to every general question. Earlier assistant text is explicitly unverified history.

Answers render inline Markdown during streaming and after completion. List markers are displayed as bullets and headings as styled text; code blocks retain their original content. If reasoning exhausts the output budget without a reply or tool call, the turn retries once without thinking instead of immediately asking the user to rephrase.

Public web discovery uses rendered Google search on iOS with public Bing result pages as fallback, without an API key. It extracts original source URLs, including encoded search redirects, and available snippets. It does not copy a search provider's generated answer. Optional Exa and Tavily providers remain available. Research reads source pages through WebKit when provider extraction is unavailable, follows bounded relevant links found on those pages, and retains its evidence graph, identity clarification, public-information scope and cancellation controls. Challenges or unreadable result pages are reported as access failures, not proof that no person or information exists.

This is public-page search and reading, not a general interactive browser agent. It does not log into sites, bypass challenges or grant access to every phone app. A future desktop companion could provide persistent browser sessions and user-visible interaction, with an optional self-hosted SearXNG endpoint for multiple search engines. That companion would require the desktop to stay available. It is not included in this build.

Native CI checks exercise provider boundaries, no-key public search, redirect decoding, refusal of non-web URLs, blocked-result handling, original research evidence fixtures, Markdown transformations, and the iOS archive. Repeated streaming, keyboard transitions and colour selection still require device testing.
