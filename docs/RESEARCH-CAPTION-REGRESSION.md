# Caption-only discovery regression

The reported query returned an indexed sports article whose headline omitted the requested name. The name appeared in the article's photo caption. Public search confirmed the article, and a direct HTML read confirmed both caption occurrences, including one inside the article.

Rendered Google discovery previously retained only headings and URLs. `PageReader.search` discarded snippet text, and `ResearchPlan.score` rejected non-directory headlines without the full name before fetching their pages. That path can lose correct articles even though ordinary Google search finds them. This identifies a reproducible harness defect; it does not confirm every condition on the user's phone.

The extractor now preserves bounded text from one result container, stopping before an ancestor that contains multiple result headings. Discovery retains relevant contextual articles and low-priority title-only results. Parked domains and obvious partial-name distractors remain filtered. A page must still contain the full subject name before evidence extraction, and quotations remain attributable to that subject.

Tests use fictional subjects and publishers. The JavaScript test failed with the original extractor and passes with snippet preservation. Native tests exercise a title-only sports article whose only named evidence is a caption, with deliberately invalid model extraction to verify deterministic evidence recovery. Access errors are retained independently of matching failures. User-facing outcomes explain incomplete access or insufficient evidence without internal graph counts.
