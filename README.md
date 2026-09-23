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

## Scheduling (launchd, every 15 minutes)

A user LaunchAgent runs a **real** reconcile (not dry-run) every 15 minutes.

| | |
|---|---|
| **Label** | `com.aukoyy.shortcut-trello-reconcile` |
| **Repo plist** | `launchd/com.aukoyy.shortcut-trello-reconcile.plist` |
| **Install path** | `~/Library/LaunchAgents/com.aukoyy.shortcut-trello-reconcile.plist` |
| **Logs** | `~/Library/Logs/shortcut-trello-reconcile.log` |

Requires a filled `.env` in this directory (the installer refuses to proceed without it).

### Install

```bash
./scripts/install-launchd.sh
```

This copies the plist into `~/Library/LaunchAgents/`, bootstraps it in `gui/$(id -u)`, enables it, and kickstarts one run.

Manual equivalent:

```bash
cp launchd/com.aukoyy.shortcut-trello-reconcile.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.aukoyy.shortcut-trello-reconcile.plist
launchctl enable "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
launchctl kickstart -k "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
```

### Check status / logs

```bash
launchctl print "gui/$(id -u)/com.aukoyy.shortcut-trello-reconcile"
tail -n 50 ~/Library/Logs/shortcut-trello-reconcile.log
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
