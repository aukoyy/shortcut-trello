#!/usr/bin/env bash
# Shortcut → Trello reconciler.
# Usage: ./reconcile.sh [--dry-run]
# Requires: bash, curl, jq, and a filled .env (see .env.example).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run]" >&2
      exit 2
      ;;
  esac
done

# --- load .env (script dir, then cwd) ---
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$SCRIPT_DIR/.env"; set +a
elif [[ -f ./.env ]]; then
  # shellcheck disable=SC1091
  set -a; source ./.env; set +a
else
  echo "error: .env not found in $SCRIPT_DIR or cwd" >&2
  exit 1
fi

: "${SHORTCUT_API_TOKEN:?SHORTCUT_API_TOKEN is required}"
: "${TRELLO_KEY:?TRELLO_KEY is required}"
: "${TRELLO_TOKEN:?TRELLO_TOKEN is required}"
: "${TRELLO_BOARD_ID:?TRELLO_BOARD_ID is required}"
: "${SHORTCUT_OWNER_ID:?SHORTCUT_OWNER_ID is required}"

STATE_MODE="${STATE_MODE:-lists}"
SAFE_PRUNE="${SAFE_PRUNE:-true}"

case "$STATE_MODE" in
  lists|labels) ;;
  *)
    echo "error: STATE_MODE must be 'lists' or 'labels' (got: $STATE_MODE)" >&2
    exit 1
    ;;
esac

SC_API="https://api.app.shortcut.com/api/v3"
TR_API="https://api.trello.com/1"
TR_AUTH="key=${TRELLO_KEY}&token=${TRELLO_TOKEN}"

CREATED=0
UPDATED=0
ARCHIVED=0
SKIPPED=0
WOULD_CREATE=0
WOULD_UPDATE=0
WOULD_ARCHIVE=0
WOULD_SKIP=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- HTTP helpers (fail hard; no silent empty arrays) ---
sc_get() {
  local path="$1"
  curl -sf \
    -H "Shortcut-Token: ${SHORTCUT_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$SC_API$path"
}

sc_post() {
  local path="$1"
  local body="$2"
  curl -sf -X POST \
    -H "Shortcut-Token: ${SHORTCUT_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$SC_API$path"
}

tr_get() {
  local path="$1"
  curl -sf "${TR_API}${path}?${TR_AUTH}"
}

tr_post() {
  local path="$1"
  shift
  # remaining args are -d name=value pairs for curl
  if $DRY_RUN; then
    return 0
  fi
  curl -sf -X POST "${TR_API}${path}?${TR_AUTH}" "$@"
}

tr_put() {
  local path="$1"
  shift
  if $DRY_RUN; then
    return 0
  fi
  curl -sf -X PUT "${TR_API}${path}?${TR_AUTH}" "$@"
}

# url-encode via jq
ue() {
  jq -nr --arg s "$1" '$s|@uri'
}

# --- 1) Desired state (same field-resolution jq as shortcut-stories.sh) ---
echo "Fetching Shortcut stories for owner ${SHORTCUT_OWNER_ID}…" >&2

members=$(sc_get /members)
groups=$(sc_get /groups)
workflows=$(sc_get /workflows)
projects=$(sc_get /projects)
epics=$(sc_get /epics)
cfields=$(sc_get /custom-fields)
stories=$(sc_post /stories/search "{\"owner_id\": \"${SHORTCUT_OWNER_ID}\", \"archived\": false}")

# Field-resolution jq must match shortcut-stories.sh AS-IS (plus owners unused by Trello).
desired=$(jq -n \
  --argjson stories   "$stories" \
  --argjson members   "$members" \
  --argjson groups    "$groups" \
  --argjson workflows "$workflows" \
  --argjson projects  "$projects" \
  --argjson epics     "$epics" \
  --argjson cfields   "$cfields" '
  def idx(keyf; valf): reduce .[] as $x ({}; .[$x | keyf | tostring] = ($x | valf));

  ($members                | idx(.id; .profile.name)) as $M |
  ($groups                 | idx(.id; .name))         as $G |
  ([$workflows[].states[]] | idx(.id; .name))         as $S |
  ($projects               | idx(.id; .name))         as $P |
  ($epics                  | idx(.id; .name))         as $E |
  ([$cfields[] | select(.canonical_name == "priority"
                     or ((.name // "") | ascii_downcase) == "priority")]
     | first // {id: null, values: []})               as $PF |
  (($PF.values // [])      | idx(.id; .value))        as $PV |

  $stories | map({
    id:        .id,
    name:      .name,
    type:      .story_type,
    team:      $G[.group_id          | tostring],
    state:     $S[.workflow_state_id | tostring],
    project:   $P[.project_id        | tostring],
    epic:      $E[.epic_id           | tostring],
    requester: $M[.requested_by_id   | tostring],
    owners:    [.owner_ids[]? | $M[.] // .],
    priority:  ([.custom_fields[]? | select(.field_id == $PF.id)
                                   | (.value // $PV[.value_id])] | first),
    permalink: .app_url
  })')

echo "$desired" >"$tmpdir/desired.json"
desired_count=$(jq 'length' <<<"$desired")
echo "Desired stories: $desired_count" >&2

# --- 2) Actual Trello state (all reads before any writes) ---
echo "Fetching Trello board ${TRELLO_BOARD_ID}…" >&2

cards=$(tr_get "/boards/${TRELLO_BOARD_ID}/cards")
lists=$(tr_get "/boards/${TRELLO_BOARD_ID}/lists")
labels=$(tr_get "/boards/${TRELLO_BOARD_ID}/labels")

echo "$cards"  >"$tmpdir/cards.json"
echo "$lists"  >"$tmpdir/lists.json"
echo "$labels" >"$tmpdir/labels.json"

# Index sc-* cards by story id (name must match ^sc-([0-9]+)  with a space)
sc_cards=$(jq '
  [.[]
    | select(.name | test("^sc-[0-9]+ "))
    | {
        id: (.name | capture("^sc-(?<id>[0-9]+) ") | .id | tonumber),
        card: .
      }
  ]
' <<<"$cards")
echo "$sc_cards" >"$tmpdir/sc_cards.json"

# Local midnight today (ISO-ish compare via epoch)
midnight_epoch=$(date -d "today 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s)

# --- helpers for label / list ensure ---
# Working copies we mutate as we create
lists_json="$lists"
labels_json="$labels"

find_list_id() {
  local name="$1"
  jq -r --arg n "$name" '
    [.[] | select(.name == $n and (.closed | not))] | first // empty | .id // empty
  ' <<<"$lists_json"
}

find_label_id() {
  local name="$1"
  jq -r --arg n "$name" '
    [.[] | select(.name == $n)] | first // empty | .id // empty
  ' <<<"$labels_json"
}

# Create list if missing; print id (or placeholder in dry-run)
ensure_list() {
  local name="$1"
  local id
  id="$(find_list_id "$name")"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi
  echo "  ensure-list: '$name'" >&2
  if $DRY_RUN; then
    id="dry-list-$(ue "$name")"
    lists_json=$(jq --arg id "$id" --arg n "$name" \
      '. + [{id: $id, name: $n, closed: false}]' <<<"$lists_json")
    printf '%s' "$id"
    return 0
  fi
  local created
  created=$(curl -sf -X POST "${TR_API}/lists?${TR_AUTH}" \
    --data-urlencode "name=${name}" \
    --data-urlencode "idBoard=${TRELLO_BOARD_ID}" \
    --data-urlencode "pos=bottom")
  id=$(jq -r '.id' <<<"$created")
  lists_json=$(jq --argjson c "$created" '. + [$c]' <<<"$lists_json")
  printf '%s' "$id"
}

# Create label if missing; print id
# color cycles through a fixed palette (Trello requires a color)
ensure_label() {
  local name="$1"
  [[ -z "$name" || "$name" == "null" ]] && { printf ''; return 0; }
  local id
  id="$(find_label_id "$name")"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi
  local colors=(blue green orange red purple yellow sky lime pink black)
  local color_idx
  color_idx=$(jq -rn --arg n "$name" '($n | explode | add) % 10')
  local color="${colors[$color_idx]}"
  echo "  ensure-label: '$name' ($color)" >&2
  if $DRY_RUN; then
    id="dry-label-$(ue "$name")"
    labels_json=$(jq --arg id "$id" --arg n "$name" --arg c "$color" \
      '. + [{id: $id, name: $n, color: $c}]' <<<"$labels_json")
    printf '%s' "$id"
    return 0
  fi
  local created
  created=$(curl -sf -X POST "${TR_API}/labels?${TR_AUTH}" \
    --data-urlencode "name=${name}" \
    --data-urlencode "idBoard=${TRELLO_BOARD_ID}" \
    --data-urlencode "color=${color}")
  id=$(jq -r '.id' <<<"$created")
  labels_json=$(jq --argjson c "$created" '. + [$c]' <<<"$labels_json")
  printf '%s' "$id"
}

card_desc() {
  local permalink="$1" epic="$2" project="$3" requester="$4" priority="$5"
  printf '%s\nepic: %s\nproject: %s\nrequester: %s\npriority: %s' \
    "$permalink" "${epic:--}" "${project:--}" "${requester:--}" "${priority:--}"
}

desired_name() {
  local id="$1" name="$2"
  printf 'sc-%s %s' "$id" "$name"
}

# Collect unique states / types / teams we need
echo "Ensuring lists/labels…" >&2

if [[ "$STATE_MODE" == "lists" ]]; then
  while IFS= read -r state_name; do
    [[ -z "$state_name" || "$state_name" == "null" ]] && continue
    ensure_list "$state_name" >/dev/null
  done < <(jq -r '[.[].state // empty] | unique | .[]' <<<"$desired")
fi

# Always ensure type + team labels; in labels mode also state
while IFS= read -r lbl; do
  [[ -z "$lbl" || "$lbl" == "null" ]] && continue
  ensure_label "$lbl" >/dev/null
done < <(jq -r '
  [.[].type // empty, .[].team // empty]
  + (if $mode == "labels" then [.[].state // empty] else [] end)
  | unique | .[]
' --arg mode "$STATE_MODE" <<<"$desired")

# Persist ensured indexes
echo "$lists_json"  >"$tmpdir/lists.json"
echo "$labels_json" >"$tmpdir/labels.json"

# Map story id → card for quick lookup
declare -A CARD_BY_STORY
while IFS=$'\t' read -r sid cid; do
  [[ -n "$sid" ]] && CARD_BY_STORY["$sid"]="$cid"
done < <(jq -r '.[] | "\(.id)\t\(.card.id)"' <<<"$sc_cards")

declare -A SEEN_STORY

# --- 3) Diff + apply: stories → cards ---
echo "Reconciling…" >&2

story_count=$(jq 'length' <<<"$desired")
for ((i = 0; i < story_count; i++)); do
  story=$(jq -c --argjson i "$i" '.[$i]' <<<"$desired")
  sid=$(jq -r '.id' <<<"$story")
  sname=$(jq -r '.name' <<<"$story")
  stype=$(jq -r '.type // empty' <<<"$story")
  steam=$(jq -r '.team // empty' <<<"$story")
  sstate=$(jq -r '.state // empty' <<<"$story")
  sproject=$(jq -r '.project // empty' <<<"$story")
  sepic=$(jq -r '.epic // empty' <<<"$story")
  sreq=$(jq -r '.requester // empty' <<<"$story")
  sprio=$(jq -r '.priority // empty' <<<"$story")
  sperma=$(jq -r '.permalink // empty' <<<"$story")

  SEEN_STORY["$sid"]=1
  want_name="$(desired_name "$sid" "$sname")"
  want_desc="$(card_desc "$sperma" "$sepic" "$sproject" "$sreq" "$sprio")"

  # Desired label ids (type, team, and state if labels mode)
  want_label_ids=()
  for lbl in "$stype" "$steam"; do
    [[ -z "$lbl" || "$lbl" == "null" ]] && continue
    lid="$(ensure_label "$lbl")"
    [[ -n "$lid" ]] && want_label_ids+=("$lid")
  done
  if [[ "$STATE_MODE" == "labels" && -n "$sstate" && "$sstate" != "null" ]]; then
    lid="$(ensure_label "$sstate")"
    [[ -n "$lid" ]] && want_label_ids+=("$lid")
  fi

  # Dedupe label ids
  want_labels_csv=$(printf '%s\n' "${want_label_ids[@]:-}" | awk 'NF' | sort -u | paste -s -d ',' -)

  want_list_id=""
  if [[ "$STATE_MODE" == "lists" ]]; then
    if [[ -n "$sstate" && "$sstate" != "null" ]]; then
      want_list_id="$(ensure_list "$sstate")"
    else
      # Fallback: first open list on the board
      want_list_id=$(jq -r '[.[] | select(.closed | not)] | first | .id // empty' <<<"$lists_json")
    fi
  fi

  if [[ -z "${CARD_BY_STORY[$sid]:-}" ]]; then
    # CREATE
    if $DRY_RUN; then
      echo "would-create: $want_name (list=${want_list_id:-n/a} labels=${want_labels_csv:-none})" >&2
      WOULD_CREATE=$((WOULD_CREATE + 1))
    else
      echo "create: $want_name" >&2
      create_args=(
        --data-urlencode "name=${want_name}"
        --data-urlencode "desc=${want_desc}"
      )
      if [[ -n "$want_list_id" ]]; then
        create_args+=(--data-urlencode "idList=${want_list_id}")
      else
        # labels mode: still need a list — use first open list
        fallback=$(jq -r '[.[] | select(.closed | not)] | first | .id // empty' <<<"$lists_json")
        if [[ -z "$fallback" ]]; then
          echo "error: board has no open lists to place card sc-$sid" >&2
          exit 1
        fi
        create_args+=(--data-urlencode "idList=${fallback}")
      fi
      if [[ -n "$want_labels_csv" ]]; then
        create_args+=(--data-urlencode "idLabels=${want_labels_csv}")
      fi
      tr_post "/cards" "${create_args[@]}" >/dev/null
      CREATED=$((CREATED + 1))
    fi
    continue
  fi

  # UPDATE — compare and PUT only changed fields
  card_id="${CARD_BY_STORY[$sid]}"
  card=$(jq -c --arg id "$card_id" '.[] | select(.id == $id)' <<<"$cards")

  cur_name=$(jq -r '.name' <<<"$card")
  cur_desc=$(jq -r '.desc // ""' <<<"$card")
  cur_list=$(jq -r '.idList' <<<"$card")
  cur_labels=$(jq -r '[.idLabels[]] | sort | join(",")' <<<"$card")
  want_labels_sorted=$(printf '%s\n' "${want_label_ids[@]:-}" | awk 'NF' | sort -u | paste -s -d ',' -)

  put_args=()
  changes=()

  if [[ "$cur_name" != "$want_name" ]]; then
    put_args+=(--data-urlencode "name=${want_name}")
    changes+=("name")
  fi
  # Trim trailing whitespace/newlines so Trello round-trips compare cleanly
  cur_desc_n="${cur_desc%"${cur_desc##*[![:space:]]}"}"
  want_desc_n="${want_desc%"${want_desc##*[![:space:]]}"}"
  if [[ "$cur_desc_n" != "$want_desc_n" ]]; then
    put_args+=(--data-urlencode "desc=${want_desc}")
    changes+=("desc")
  fi
  if [[ "$STATE_MODE" == "lists" && -n "$want_list_id" && "$cur_list" != "$want_list_id" ]]; then
    put_args+=(--data-urlencode "idList=${want_list_id}")
    changes+=("list")
  fi
  if [[ "$cur_labels" != "$want_labels_sorted" ]]; then
    put_args+=(--data-urlencode "idLabels=${want_labels_sorted}")
    changes+=("labels")
  fi

  if [[ ${#changes[@]} -eq 0 ]]; then
    if $DRY_RUN; then
      WOULD_SKIP=$((WOULD_SKIP + 1))
    else
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi

  change_list=$(IFS=,; echo "${changes[*]}")
  if $DRY_RUN; then
    echo "would-update: sc-$sid ($change_list)" >&2
    WOULD_UPDATE=$((WOULD_UPDATE + 1))
  else
    echo "update: sc-$sid ($change_list)" >&2
    # Filter out dry-* placeholder writes (should not happen outside dry-run)
    curl -sf -X PUT "${TR_API}/cards/${card_id}?${TR_AUTH}" "${put_args[@]}" >/dev/null
    UPDATED=$((UPDATED + 1))
  fi
done

# --- 4) Archive orphan sc-* cards (SAFE_PRUNE) ---
orphan_count=$(jq 'length' <<<"$sc_cards")
for ((i = 0; i < orphan_count; i++)); do
  entry=$(jq -c --argjson i "$i" '.[$i]' <<<"$sc_cards")
  sid=$(jq -r '.id' <<<"$entry")
  if [[ -n "${SEEN_STORY[$sid]:-}" ]]; then
    continue
  fi
  card=$(jq -c '.card' <<<"$entry")
  card_id=$(jq -r '.id' <<<"$card")
  card_name=$(jq -r '.name' <<<"$card")
  closed=$(jq -r '.closed' <<<"$card")
  if [[ "$closed" == "true" ]]; then
    continue
  fi

  should_archive=true
  if [[ "$SAFE_PRUNE" == "true" ]]; then
    dla=$(jq -r '.dateLastActivity // empty' <<<"$card")
    if [[ -z "$dla" ]]; then
      should_archive=false
    else
      # dateLastActivity is ISO8601 UTC; compare to local midnight
      dla_epoch=$(date -d "$dla" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${dla%%.*}" +%s 2>/dev/null || echo "")
      if [[ -z "$dla_epoch" || "$dla_epoch" -ge "$midnight_epoch" ]]; then
        should_archive=false
      fi
    fi
  fi

  if ! $should_archive; then
    echo "skip-prune: $card_name (SAFE_PRUNE: activity today or unknown)" >&2
    if $DRY_RUN; then
      WOULD_SKIP=$((WOULD_SKIP + 1))
    else
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi

  if $DRY_RUN; then
    echo "would-archive: $card_name" >&2
    WOULD_ARCHIVE=$((WOULD_ARCHIVE + 1))
  else
    echo "archive: $card_name" >&2
    tr_put "/cards/${card_id}" --data-urlencode "closed=true" >/dev/null
    ARCHIVED=$((ARCHIVED + 1))
  fi
done

# --- summary ---
if $DRY_RUN; then
  echo "summary: would-create=${WOULD_CREATE} would-update=${WOULD_UPDATE} would-archive=${WOULD_ARCHIVE} would-skip=${WOULD_SKIP}"
else
  echo "summary: created=${CREATED} updated=${UPDATED} archived=${ARCHIVED} skipped=${SKIPPED}"
fi
