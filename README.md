# Shortcut → Trello mirror

Stateless bash+jq reconciler that mirrors your owned Shortcut stories onto a Trello board as `sc-<id> …` cards.

## Prerequisites

- `bash`, `curl`, `jq`
- Shortcut API token and your member UUID (`SHORTCUT_OWNER_ID`)
- Trello API key + token and a board id

## Setup

```bash
cp .env.example .env
```

Edit `.env` and fill:

| Variable | Where to get it |
|---|---|
| `SHORTCUT_API_TOKEN` | Shortcut → Settings → API tokens |
| `SHORTCUT_OWNER_ID` | Your Shortcut member UUID (from `/api/v3/member` or the UI) |
| `TRELLO_KEY` | [Trello Power-Up admin / app key](https://trello.com/power-ups/admin) |
| `TRELLO_TOKEN` | Generated from the same app key page |
| `TRELLO_BOARD_ID` | Board URL or API (`/1/members/me/boards`) |

Optional:

- `STATE_MODE=lists` (default) — one Trello list per Shortcut workflow state; missing lists are created. `labels` maps state to a label instead.
- `SAFE_PRUNE=true` (default) — only archive orphan `sc-*` cards whose `dateLastActivity` is before local midnight today.

`.env` is gitignored; keep secrets out of commits.

## Dry-run (always do this first)

```bash
./reconcile.sh --dry-run
```

Prints would-create / would-update / would-archive actions without writing to Trello. Exit non-zero on API failure.

## Real run

```bash
./reconcile.sh
```

Idempotent: creates missing `sc-*` cards, updates changed fields only, archives orphan `sc-*` cards (subject to `SAFE_PRUNE`). Never touches non-`sc-*` cards; never hard-deletes.

Summary line: `created=… updated=… archived=… skipped=…` (or `would-*` under `--dry-run`).

## Standalone story dump

```bash
export SHORTCUT_API_TOKEN=…
./shortcut-stories.sh <owner-uuid>          # JSON
./shortcut-stories.sh <owner-uuid> --tsv    # TSV
```

## Scheduling (follow-up)

Not included in this slice. When you want unattended sync, add a launchd plist (macOS) or cron that runs `reconcile.sh` on an interval after you've validated dry-runs. Example launchd sketch:

```xml
<!-- ~/Library/LaunchAgents/com.user.shortcut-trello.plist -->
<!-- ProgramArguments: /path/to/reconcile.sh -->
<!-- WorkingDirectory: /path/to/this/repo -->
<!-- StartInterval: 900 -->
```

Load with `launchctl load ~/Library/LaunchAgents/com.user.shortcut-trello.plist` once `.env` is filled and dry-run looks right.
