#!/usr/bin/env bash
# Deletes the doks-spot-demo cluster and everything it created (load
# balancers, volumes, snapshots). Leaves the 'doks-spot-demo' project itself in
# place for reuse -- delete that manually if you're done with it entirely.
#
# Usage: ./teardown.sh [--yes]
# --yes skips the confirmation prompt (for non-interactive/repeatable runs).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./env.sh
source ./env.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
fi

command -v doctl >/dev/null || { echo "doctl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

doctl account get >/dev/null || { echo "doctl isn't authenticated -- run 'doctl auth init'" >&2; exit 1; }

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "This deletes cluster '$CLUSTER_NAME' and its LBs/volumes. Type the cluster name to confirm: " confirm
  [[ "$confirm" == "$CLUSTER_NAME" ]] || { echo "Aborted."; exit 1; }
fi

# Captured before delete, while the cluster still exists: the set of Droplets
# that must be gone once teardown finishes. $TAG can't scope this -- it's shared
# by every doks-spot-demo run in the account/team, so sweeping on it risks
# someone else's nodes. Two independent per-cluster sources instead:
#   1. the node-pool API's own droplet_id list, and
#   2. DO's "k8s:<cluster-id>" auto-tag, which is unique per cluster.
# Two sources because either one alone is an unverified assumption about an API
# shape, and if the lookup silently matches nothing, "no leftovers" below reads
# exactly like a clean account -- which is the precise failure this sweep exists
# to prevent. If BOTH come back empty the result is reported as undetermined,
# not as success.
cluster_id=$(doctl kubernetes cluster get "$CLUSTER_NAME" --format ID --no-header 2>/dev/null || true)

expected_droplets=""
if [[ -n "$cluster_id" ]]; then
  from_api=$(doctl kubernetes cluster node-pool list "$CLUSTER_NAME" -o json 2>/dev/null \
    | jq -r '.[].nodes[]?.droplet_id // empty' 2>/dev/null || true)
  from_tag=$(doctl compute droplet list --tag-name "k8s:${cluster_id}" -o json 2>/dev/null \
    | jq -r '.[].id' 2>/dev/null || true)
  expected_droplets=$(printf '%s\n%s\n' "$from_api" "$from_tag" | grep -E '^[0-9]+$' | sort -u || true)
fi

# Tolerate an already-gone cluster. The sweep below exists to recover from a
# previous teardown that removed the cluster object but left workers billing;
# aborting here on "cluster not found" would block exactly that recovery.
delete_ok=true
doctl kubernetes cluster delete "$CLUSTER_NAME" --dangerous --force || {
  delete_ok=false
  echo "Warning: cluster delete failed or cluster was already gone -- continuing to the Droplet sweep." >&2
}

# --dangerous cleans up LBs/volumes but has been observed leaving worker
# Droplets running (billing) after the cluster object itself is gone --
# confirmed the hard way. Give DO's own async cleanup a few tries, then
# force it ourselves rather than silently leak paid compute.
echo "Confirming this cluster's Droplets are gone..."
sweep="ok"
if [[ -z "$cluster_id" ]]; then
  echo "Warning: couldn't resolve cluster id -- can't identify this run's Droplets precisely." >&2
  sweep="skipped"
  # Fallback for the case this whole sweep exists for: a previous teardown
  # removed the cluster object but left workers billing, so there's no cluster
  # id left to scope by. $TAG is account/team-wide and may cover someone else's
  # run, so it is listed for a human, never auto-deleted.
  candidates=$(doctl compute droplet list --tag-name "$TAG" -o json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true)
  if [[ -n "$candidates" ]]; then
    echo "Warning: Droplet(s) tagged '$TAG' are still running -- possibly leaked by an" >&2
    echo "         earlier teardown, possibly someone else's run. NOT deleting automatically:" >&2
    printf '           %s\n' $candidates >&2
  else
    echo "         No Droplets tagged '$TAG' are running, so nothing obvious is leaking." >&2
  fi
elif [[ -z "$expected_droplets" ]]; then
  echo "Warning: resolved cluster $cluster_id but found 0 Droplets for it before the delete." >&2
  echo "         Either the cluster genuinely had no nodes, or Droplet discovery is broken" >&2
  echo "         (node-pool droplet_id and the k8s:<cluster-id> tag both came back empty)." >&2
  echo "         Those are not distinguishable here, so this is NOT a clean bill of health." >&2
  sweep="undetermined"
else
  expected_count=$(printf '%s\n' "$expected_droplets" | wc -l | tr -d ' ')
  leftover=""
  for _ in $(seq 1 6); do
    leftover=""
    for id in $expected_droplets; do
      # Existence check per id, not another tag lookup -- the ids are already
      # resolved, so this no longer depends on the tag format being right.
      if doctl compute droplet get "$id" --format ID --no-header >/dev/null 2>&1; then
        leftover="$leftover $id"
      fi
    done
    leftover="${leftover# }"
    [[ -z "$leftover" ]] && break
    sleep 5
  done
  if [[ -n "$leftover" ]]; then
    echo "Found leftover Droplet(s) after DO's cleanup window, deleting directly: $leftover"
    # shellcheck disable=SC2086
    doctl compute droplet delete $leftover --force
    sleep 5
    still=""
    for id in $leftover; do
      if doctl compute droplet get "$id" --format ID --no-header >/dev/null 2>&1; then
        still="$still $id"
      fi
    done
    if [[ -n "$still" ]]; then
      echo "Error: Droplet(s) still present after direct delete:$still" >&2
      sweep="failed"
    else
      echo "Leftover Droplet(s) deleted and confirmed gone."
    fi
  else
    echo "No leftover Droplets ($expected_count from this cluster confirmed gone)."
  fi
fi

# A sweep that did not run is not a sweep that passed. Anything short of a
# verified-clean result exits non-zero, because the thing at stake is billing.
if [[ "$sweep" != "ok" || "$delete_ok" != true ]]; then
  echo >&2
  echo "Teardown did NOT fully verify (cluster_delete=$delete_ok, droplet_check=$sweep)." >&2
  echo "Paid compute may still be running. Check manually:" >&2
  echo "  doctl compute droplet list --tag-name k8s:${cluster_id:-<cluster-id>}" >&2
  echo "  doctl compute droplet list --tag-name $TAG" >&2
  exit 1
fi

echo "Deleted. Project '$PROJECT_NAME' left in place."
