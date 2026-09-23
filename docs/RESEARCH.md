# Research search and identity evidence

Research uses Tavily advanced web search, not the Wikipedia fallback used for ordinary questions. Add a working key under Sidebar → Online. A missing key, rejected key, provider error or exhausted allowance is reported explicitly. Advanced queries cost more credits; the app's work level bounds searches and page reads.

The plan keeps a supplied person's full name in every query. Medical requests include hospital, clinic and practitioner-register searches; academic requests include faculty and publication searches. All results are ranked for name, contextual clues and professional relevance. A genuine practice hosted on Wix remains eligible; a website-builder landing page does not receive credibility merely from its domain.

The app reads extracted page text or the page itself. Search snippets are discovery leads, not identity evidence. Name plus a common occupation is insufficient: a retained quote must link the name with a supplied location or organisation. Quotes are checked against page text; quotes about other people and invented quotes do not become facts or search seeds. Unverified profiles stay separate. Source URLs, unresolved supplied clues, provider failures and disagreements are retained in the report.

No public-web search establishes an identity with 100% certainty, exhausts every website or establishes that a person has no web presence. These checks reduce false merges; the local model can still miss relevant passages or misinterpret a profile. Sources can copy one another. Identity status remains provisional, and reported disagreements are not automatically declared resolved after another search.

The macOS CI build compiles and runs `scripts/research-tests.swift` against the production policy, engine and search client before archiving the IPA. Fixtures cover query anchoring, professional relevance, incorrect name matches, invented evidence, mixed-person pages, failed subject extraction, missing/rejected search keys and malformed responses. These tests do not replace on-device testing or a live test using the user's own search key.
