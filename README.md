# Shortcut → Trello mirror

Stateless bash+jq reconciler that mirrors your owned Shortcut stories onto a Trello board as `sc-<id> …` cards.

## Prerequisites

- `bash` (macOS stock Bash 3.2 is supported — no Bash 4+ / associative arrays), `curl`, `jq`
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
| `TRELLO_KEY` | Power-Up **API key** from [trello.com/power-ups/admin](https://trello.com/power-ups/admin) (or trello.com/app-key) |
| `TRELLO_TOKEN` | Generated user **Token** from that same page (authorize the app). **Not** the OAuth Secret |
| `TRELLO_BOARD_ID` | Board URL or API (`/1/members/me/boards`) |

Trello’s Power-Up page shows three different values — do not mix them up:

| Value | Use in this repo? |
|---|---|
| API key | Yes → `TRELLO_KEY` |
| User token (generated after “allow”) | Yes → `TRELLO_TOKEN` |
| OAuth secret | No — never put this in `.env` |

Optional:

- `STATE_MODE=lists` (default) — one Trello list per Shortcut workflow state; missing lists are created. `labels` maps state to a label instead.
- `SAFE_PRUNE=true` (default) — only archive orphan `sc-*` cards whose `dateLastActivity` is before local midnight today.
- `OWNER_LABEL_COLORS=ryan:green` (default) — comma-separated `name:color` pairs for owner labels. Keys match owner display names case-insensitively as substrings (so `ryan` matches `Ryan`). Unmatched owners use `OWNER_LABEL_COLOR_DEFAULT` (default `blue`).

### Card description & labels

Each `sc-*` card gets a markdown description shaped for Sunsama:

```
[Open in Shortcut](https://app.shortcut.com/…)

type: …
team: …
epic: …
project: …
requester: …
priority: …
```

Empty fields use `-`. Type and team live in the description (not as Trello labels).

**Labels:** each story owner name (from Shortcut `owners`) becomes a Trello label. Colors come from `OWNER_LABEL_COLORS` (default: Ryan → `green`; everyone else → `blue`). Existing labels with the wrong color are updated via the Trello API. With `STATE_MODE=lists`, those are the only labels on the card. With `STATE_MODE=labels`, the workflow-state label is kept as well. Updates set `idLabels` to exactly that set (old type/team labels are dropped), so dual-owner cards get both owner labels with correct colors.

`.env` is gitignored; keep secrets out of commits.

## Dry-run (always do this first)

```bash
./reconcile.sh --dry-run
```

Prints would-create / would-update / would-archive actions without writing to Trello. For creates and desc/label updates, also prints the planned **label names** and full **description** (no API secrets). Exit non-zero on API failure.

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

## Scheduling (launchd, every 5 minutes)

A user LaunchAgent runs a **real** reconcile (not dry-run) every **5 minutes** while the Mac is on and you are logged in. Label: `com.aukoyy.shortcut-trello-reconcile`.

| | |
|---|---|
| **Label** | `com.aukoyy.shortcut-trello-reconcile` |
| **Interval** | 300s (`StartInterval`) — while Mac is on / logged in |
| **Repo plist** | `launchd/com.aukoyy.shortcut-trello-reconcile.plist` |
| **Install path** | `~/Library/LaunchAgents/com.aukoyy.shortcut-trello-reconcile.plist` |
| **Logs** | `~/Library/Logs/shortcut-trello-reconcile.log` |

Requires a filled `.env` in this directory (the installer refuses to proceed without it).

### Install

```bash
./scripts/install-launchd.sh
```

What it does: copies the plist into `~/Library/LaunchAgents/`, bootstraps it in `gui/$(id -u)`, enables it, and kickstarts one run immediately. Refuses to install if `.env` is missing.

Manual equivalent:

```bash
cp launchd/com.aukoyy.shortcut-trello-reconcile.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.aukoyy.shortcut-trello-reconcile.plist
launchctl enable "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
launchctl kickstart -k "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
```

### Check recent logs

```bash
tail -n 50 ~/Library/Logs/shortcut-trello-reconcile.log
```

### Job status

```bash
launchctl print gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile
```

### Manual kickstart / run once

Force one run now (supported; same as install’s kickstart):

```bash
launchctl kickstart -k "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
```

Or run the reconciler directly from the repo (bypasses launchd):

```bash
./reconcile.sh
```

### Pause / resume

```bash
# Pause (unload; keeps the plist on disk)
launchctl bootout "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"

# Resume
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.aukoyy.shortcut-trello-reconcile.plist
```

### Uninstall

```bash
./scripts/uninstall-launchd.sh
```

Removes the job and the installed plist. The log file is left in place.
