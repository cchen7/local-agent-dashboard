# M3 query syntax — FR-SR

`ADCore.SearchQuery.parse(_:)` converts search input into text clauses and
typed filters. Terms within a clause use implicit AND, unquoted uppercase
`OR` separates positive clauses, and filters constrain the whole query.
Exclusions, quoted phrases and quoted filter values are supported. Unknown
prefixes are treated as literal text. Errors identify categories without
embedding the query.

This standalone parser does not execute FTS, access files, or change the App.
Input limits are 16,384 UTF-8 bytes and 256 tokens. Calendar dates and positive
hour/day windows are validated before execution; the search layer interprets
them with the user's local time zone and the current clock.

The focused repository ADCore run passed 43 test functions, including 27 new
parser tests covering every Appendix B example, Boolean precedence,
quoting/escaping, invalid values and input boundaries. The test corpus is
synthetic. API and dependency guards passed.
