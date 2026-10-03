# Research and photo retrieval update

Research begins with the full requested name, all supplied city/employer clues,
and relevant professional queries. The subject stays in every follow-up query.
Clear requests no longer wait for a local planning generation. Tavily research
defaults to advanced discovery; Settings > Web Searching offers a standard mode.
Exa and Tavily remain the full-web providers. Missing credentials produce an
explicit configuration error, never an encyclopedia-only substitute.

Sport and profession suffixes are now separated from the person's name. A request
such as "Morgan Example soccer" searches for "Morgan Example" with soccer context,
then tries player profiles, club rosters, team results, league statistics and match
reports. Compound names remain intact. Public roster directories can be read even
when their search snippet omits the name; the actual page must contain the name.
Empty first-round results trigger unused request-grounded discovery variants.
Unread pages remain queued across rounds. Temporary provider failures continue
with other queries; credential and quota failures stop with an explicit reason.
All searches remain bounded by the existing search, page, round and time budgets.

Structured name, city, age and job/title fields are recognized without relying on
model formatting. Adult age is a discovery hint, never identity proof. Private
home addresses are excluded. When attributable sources leave multiple profiles,
chat asks which person the user means before producing a combined report. A
profile choice or unique quoted job/city reply focuses the next search. Other
profiles stay separate in the archive; additional sources require multiple
matching quoted distinguishing details before entering the selected report.

Page reading now returns public HTTP/HTTPS links that the model can follow with
read_page. Chat receives the actual network/search-key state. This provides web
search and page browsing, not unrestricted desktop shell access or control of
every iOS app. Search providers still require working credentials; page reading
can use a public URL without a search key.

Research activity appears as a small conduit and current action text. Source
details and cancellation controls expand on demand. The composer now belongs to
the transcript's navigation layout. A real tail spacer and scrolling on activity
updates keep growing research modules above the input bar.

Sources are read before identity matching. Literal attributable source statements
survive malformed model extraction. A name alone remains a possible profile;
independent sources with multiple supplied anchors provide stronger provisional
support. Copied pages do not count as independent confirmation. Contradictions
stay visible. Sources sharing quoted attributes are grouped for presentation.
Evidence-grounded follow-up searches seek missing clues and public professional
biographies, education, and publications. Research remains bounded and cannot
guarantee exhaustive discovery or certain identity.

Bulk gallery imports now add recognized text, photo dates, and visual labels to
the same local retrieval index as documents. Stable document IDs prevent retry
duplicates. Existing bulk imports migrate before the next chat retrieval. Gallery
images remain in Photos, with their asset IDs retained by the chosen library.
Multi-select photo imports have no app-imposed 20-photo limit and are analyzed
one at a time. Failed/unavailable assets are reported. iCloud originals are only
downloaded when enabled in Settings > Appearance > Photos.

SQLite keyword matching now qualifies the passage text column: the old table
name was ambiguous with the document passage-count column and could make recall
silently return no results. Collection filtering happens before result limits,
so unrelated or disabled libraries cannot crowd the requested collection out.

The loading indicator is centered, smaller, and moves inside a bounded capsule.
Answers appear as soon as they arrive, without the previous delayed shake/haptic
sequence. Activity labels follow actual research/tool/streaming state and can be
hidden in Appearance. Startup has a smaller centered mark, no wordmark, and a
shorter transition. Transcript tail space and composer separation are increased;
the composer is slightly thinner. Navigation modes remain unchanged.

Settings badges use 15 engagement ranks based on recorded generations, with the
three most-used models and their share of generation time shown underneath.
Ranks describe usage, not measured model capability.

Native regression fixtures cover failed model extraction, name-only leads,
attribution to the correct profile, provider settings, usage thresholds, bounded
indicator movement, and existing research/provenance/protocol behavior. Device
checks remain necessary for PhotoKit permissions, iCloud-only images, large
imports, keyboard spacing, animation appearance, and live-provider relevance.
