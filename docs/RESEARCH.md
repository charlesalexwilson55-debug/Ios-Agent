# Research search and identity evidence

Research uses Tavily advanced web search, not the Wikipedia fallback used for ordinary questions. Add a working key under Sidebar → Online. A missing key, rejected key, provider error or exhausted allowance is reported explicitly. Advanced queries cost more credits; one fixed research budget bounds searches and page reads.

Planning is optional model assistance, not a gate before search. Label variants, JSON and fenced JSON are accepted. Names and clues must come from the user's request; unsupported model inventions are dropped. If planning fails, the app extracts clear names and context directly from the request or searches the complete supplied wording in discovery-only mode. Missing formatted output no longer tells the user to supply details they already provided.

The plan keeps an identified person's full name in every query. Medical requests include hospital, clinic and practitioner-register searches; academic requests include faculty and publication searches. All results are ranked for name, contextual clues and professional relevance. A genuine practice hosted on Wix remains eligible; a website-builder landing page does not receive credibility merely from its domain.

The app reads extracted page text or the page itself. Search snippets are discovery leads, not identity evidence. Name plus a common occupation is insufficient: a retained quote must link the name with a supplied location or organisation. Quotes are checked against page text; quotes about other people and invented quotes do not become facts or search seeds. Unverified profiles stay separate. Source URLs, unresolved supplied clues, provider failures and disagreements are retained in the report.

No public-web search establishes an identity with 100% certainty, exhausts every website or establishes that a person has no web presence. These checks reduce false merges; the local model can still miss relevant passages or misinterpret a profile. Sources can copy one another. Identity status remains provisional, and reported disagreements are not automatically declared resolved after another search.

Up to eight candidate sources are shown separately with status, snippet, source link and supplied clues. “Research this profile” starts a fresh investigation of the selected URL, retaining the original request. Its readable literal statements can be shown even if model extraction fails. Choosing a page does not certify identity, and other same-name profiles remain separate candidates rather than being merged into its report. If final summarization fails, source excerpts remain available.

## Testing on the phone

1. Sidebar → Online: add a Tavily key and use **Test web search**. This tests the search provider without involving the text model.
2. Enable Research and use a clearly identified public professional: full name, role and publicly listed institution/city. The activity should progress to searches even if planning output is malformed. Check that sources include the relevant organisation.
3. Repeat with a deliberately incorrect city. Results must remain uncertain/conflicting instead of silently combining different profiles. Open a source to check the evidence, then select a candidate to see a report explicitly scoped to that page.
4. Try an ordinary maths question with Research off. This is separate from web search; compare its result with the research flow to distinguish model generation failures from provider failures.

The local diagnostic log records research output character counts, including reasoning-only output, but does not record research request text or keys in the added diagnostic entries.

The macOS CI build compiles and runs `scripts/research-tests.swift` against the production policy, engine and search client before archiving the IPA. Fixtures cover query anchoring, professional relevance, incorrect name matches, invented evidence, mixed-person pages, failed subject extraction, missing/rejected search keys and malformed responses. These tests do not replace on-device testing or a live test using the user's own search key.
