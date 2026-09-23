#!/usr/bin/env bash
# Usage: ./shortcut-stories.sh <owner-uuid> [--tsv]
# Requires: curl, jq, $SHORTCUT_API_TOKEN

set -euo pipefail

API="https://api.app.shortcut.com/api/v3"
OWNER_ID="${1:?usage: $0 <owner-uuid> [--tsv]}"
FORMAT="${2:-}"

auth=(-H "Shortcut-Token: ${SHORTCUT_API_TOKEN:?SHORTCUT_API_TOKEN not set}"
      -H "Content-Type: application/json")

get() { curl -sf "${auth[@]}" "$API$1" || echo '[]'; }

# Lookup tables. Fetched once, reused for every story.
members=$(get /members)
groups=$(get /groups)          # Teams
workflows=$(get /workflows)    # Workflow states live inside these
projects=$(get /projects)      # [] in workspaces that never used Projects
epics=$(get /epics)
cfields=$(get /custom-fields)

stories=$(curl -sf -X POST "${auth[@]}" "$API/stories/search" \
  -d "{\"owner_id\": \"$OWNER_ID\", \"archived\": false}")

result=$(jq -n \
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

if [ "$FORMAT" = "--tsv" ]; then
  printf 'id\tname\ttype\tteam\tstate\tproject\tepic\trequester\towners\tpriority\tpermalink\n'
  echo "$result" | jq -r '.[] | [
      .id, .name, .type, (.team // "-"), (.state // "-"),
      (.project // "-"), (.epic // "-"), (.requester // "-"),
      (if (.owners | length) == 0 then "-" else (.owners | join(", ")) end),
      (.priority // "-"), .permalink
    ] | @tsv'
else
  echo "$result"
fi
