# Standard API list-price baseline

Checked 2026-11-20 UTC. The table contains 54 exact model IDs and three
documented aliases. Rates are USD per million tokens on the vendors' own
standard text APIs. For subscription agents and Copilot, these rates are
an API-equivalent estimate. They do not represent the user's bill, Azure or
other hosting prices, service tiers, regional premiums, or exchange rates.

| Vendor | IDs | Primary sources |
|---|---:|---|
| OpenAI | 32 | [Standard API pricing](https://developers.openai.com/api/docs/pricing#standard-pricing-data), [GPT-5.3-Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex#pricing), [GPT-5.2-Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex#pricing), [GPT-5.1-Codex](https://developers.openai.com/api/docs/models/gpt-5.1-codex#pricing) |
| Anthropic | 15 | [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing#model-pricing), [model IDs and support](https://platform.claude.com/docs/en/about-claude/model-deprecations), [Opus alias](https://platform.claude.com/docs/en/models/opus-4-5/overview), [Haiku alias](https://platform.claude.com/docs/en/models/haiku-4-5/overview), [Sonnet 5.5 launch](https://platform.claude.com/docs/en/release-notes/overview#september-28-2026) and [cache rate change](https://platform.claude.com/docs/en/release-notes/overview#october-7-2026) |
| xAI | 7 | [Text API prices](https://docs.x.ai/developers/models#text-api-pricing), [Grok 4.7 tier boundary](https://docs.x.ai/developers/models/grok-4.7#pricing) |

Use the check date when the source does not establish an earlier effective
date for the complete rate. For Claude Sonnet 5.5, the Oct 7 release note
records a cache-read reduction from $0.20 to $0.10 with all other prices
unchanged. Keep both entries from the documented launch and change dates.
Earlier usage without a verified effective entry stays unpriced.

The engine uses a strict greater-than test for prompt tiers. Standard
OpenAI long-context prices begin above 272,000 input tokens, and Claude
Haiku 5.5 begins above 100,000. xAI's higher price begins at 200,000, so
the xAI threshold in the table is 199,999. Anthropic's 5-minute and 1-hour
cache-write rates are entered as published. OpenAI's 30-minute and 12-hour
writes are not treated as either field. An event with a nonzero cache-write
count and no matching rate is approximate under SPEC §8.4.

Do not add a prefix selector or equate fast, private or regional slugs with
a standard model. Grok Build 0.1 had no verified current price in the
live vendor catalog on the check date; keep it unpriced. Retirement status,
supported rates and prices are independent of whether a local agent reports
an ID. Append verified changes to the table; never edit old rate entries to
make historical totals match a new price.
