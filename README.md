# Token Burn

Mac menu bar item and desktop widget showing Claude Code cost for the current billing month, refreshed every 2 seconds.

    ./build.sh && open TokenBurn.app

- **Billing Day** and **Plan Fee** in the 🔥 menu are guessed from `~/.claude.json`; check them against your invoice.
- Responses seen are saved in `~/Library/Application Support/TokenBurn/ledger.json`, so totals survive transcript cleanup. Anything deleted before the app saw it is not counted.
- **Floating Mini Widget** in the 🔥 menu swaps the card for a small pill (month and today's cost) that stays above other windows, including full-screen apps.
- The arrow button on the card or pill collapses and expands it (the card keeps its header and the month's cost, the pill only the cost).
- The × button closes the widget; the app keeps running, and **Show / Hide Widget** in the 🔥 menu brings it back.
- Drag the widget to move it. The 🔥 menu bar item hides it, pins it on top, or quits.
- `TokenBurn.app/Contents/MacOS/TokenBurn --once` prints the totals in the terminal.
- Start at login: System Settings > General > Login Items > add TokenBurn.app.

## What the numbers mean

- Source: the transcripts in `~/.claude/projects`. claude.ai chat and your own API calls are not counted.
- Cost is an estimate at Anthropic API list price, not your invoice. On a Pro/Max/Team plan you do not pay per token.
- Claude Code deletes old transcripts (`cleanupPeriodDays`, 30 by default), so "All recorded" starts from the oldest transcript present at first run, not lifetime.
- Prices are hard-coded in `main.swift`; update them when they change, then rebuild.
