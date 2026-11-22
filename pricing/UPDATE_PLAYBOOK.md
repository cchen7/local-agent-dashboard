# Updating list prices locally

The bundled table is `pricing/pricing.json`. Build the developer executable
from the pinned Swift package, using a task-local directory outside the source
checkout. The executable does not fetch vendor prices or launch the App.

```sh
price_build=$(mktemp -d /private/tmp/agentdash-pricing.XXXXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build \
  --package-path Packages/AgentDashKit --scratch-path "$price_build" \
  --product AgentDashPricingTool --disable-automatic-resolution
export AGENTDASH_PRICING_TOOL="$price_build/debug/AgentDashPricingTool"
```

1. Use `Tools/pricing/models-seen --index-snapshot "$snapshot"` on an
   authorized, standalone Agent Dashboard index copy. A snapshot must
   use rollback-journal format and have no WAL, SHM or journal side files.
   Do not pass an active database, another app's SQLite file or a vendor
   source. The tool reads only accounting fields, never transcript or
   session identities. Its counts cover indexed records, not a new scan
   or the CLI's own statistics. Model strings outside the supported ID
   format, or detected as credentials, are omitted from the report.
2. Check model IDs and rate dates only against official Anthropic, OpenAI
   and xAI price pages. For Copilot use the underlying vendor's public API
   price; keep Copilot billing units separate. Leave undocumented prices
   unpriced.
3. Append a dated price entry when the rate changed, or add a model.
   Preserve every existing entry and its original source/check date.
   Use the vendor effective date, or the check date when no earlier
   date is established. Update `updatedAt` and dated display rates if needed.
4. Validate and preview historical impact:

   ```sh
   Tools/pricing/validate "$candidate"
   Tools/pricing/validate "$candidate" --previous "$previous" --index-snapshot "$snapshot"
   Tools/pricing/models-seen "$candidate" --index-snapshot "$snapshot"
   ```

   Both commands use the App's ADPricing decoder and exact per-event
   arithmetic. The quote delta is hypothetical. The projected stored
   total keeps previously priced records intact and fills only supported
   unpriced ones. A missing model or effective rate remains unpriced.
5. Open a PR for human review with official sources, pricing changes,
   remaining unpriced exceptions and the aggregate impact. Keep raw
   snapshots and local model inventories private. After the table and
   installation are authorized, run `Tools/pricing/install "$candidate" --apply`.
   It compares against bundled and existing history, stages a private
   file, and atomically replaces only the App's external
   `~/.config/agent-dashboard/pricing.json`. Validation or inventory
   never install anything. A malformed or symlinked existing target is
   left in place for explicit resolution.
