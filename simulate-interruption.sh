#!/usr/bin/env bash
# Simulates a spot reclaim on the doks-spot-demo GPU workload -- not by
# killing a single node, but by deleting the ENTIRE spot node pool via the
# DOKS node-pool API, same as a real reclaim would (DOKS reclaims a spot
# pool as a whole, never partially). No manual cordon/drain step here: the
# DeleteNodePool API itself cordons, drains (respecting PodDisruptionBudgets),
# and deletes each node after its drain timeout -- that's DOKS's job, not
# this script's. We just trigger it and watch.
#
# The evicted workload has nowhere to run once the spot pool is gone --
# unless a fallback exists. This demo pre-provisions one: an on-demand pool
# created by launch.sh at 0 nodes. That's DO's recommended spot-fallback
# pattern (label both pools, taint only spot, give the workload a toleration
# + preferred-not-required node affinity toward spot). What's NOT fully
# automatic here: DOKS/doctl doesn't support scale-to-zero on an autoscaling
# pool, so cluster-autoscaler alone can't bring a 0-node pool to life on its
# own the way it would if the pool already had >=1 node. This script does
# that scale-up explicitly (node-pool update) to reach the same end state a
# fully-automatic priority-expander setup would.
#
# Usage: ./simulate-interruption.sh [ondemand-gpu-size]
# ondemand-gpu-size only matters if the on-demand pool doesn't already
# exist; normally it does (launch.sh creates it) and this is a no-op override.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./env.sh
source ./env.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
fi

command -v doctl >/dev/null || { echo "doctl not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

doctl account get >/dev/null || { echo "doctl isn't authenticated -- run 'doctl auth init'" >&2; exit 1; }

ONDEMAND_GPU_SIZE="${1:-$DEFAULT_ONDEMAND_GPU_SIZE}"

doctl kubernetes cluster node-pool get "$CLUSTER_NAME" "$SPOT_POOL_NAME" >/dev/null 2>&1 \
  || { echo "Spot pool '$SPOT_POOL_NAME' not found -- run ./launch.sh first" >&2; exit 1; }

echo "== Before =="
echo "Node pools:"
doctl kubernetes cluster node-pool list "$CLUSTER_NAME" --format Name,Size,Count
echo
echo "Pods on the spot pool's node(s):"
kubectl get pods -A -o wide -l "doks-spot-demo=true"

start=$(date +%s)

echo
echo "== Reclaiming the ENTIRE spot node pool: $SPOT_POOL_NAME =="
echo "(DeleteNodePool cordons/drains respecting PDBs, then deletes -- no manual drain needed here)"
doctl kubernetes cluster node-pool delete "$CLUSTER_NAME" "$SPOT_POOL_NAME" --force

echo
echo "== Node/pod events since the reclaim signal =="
# What a third-party scheduler (Kueue, Volcano, Ray) would react to instead
# of polling DO's side -- surfaced here just to make it visible.
kubectl get events -A --sort-by=.lastTimestamp \
  --field-selector involvedObject.kind=Node 2>/dev/null | tail -n 20 || true

echo
echo "== Confirming the spot pool's node(s) are gone from the cluster =="
for _ in $(seq 1 60); do
  # A transient kubectl failure here must not read as "0 nodes left" (falsely
  # confirming the pool gone early) or kill the script outright under
  # set -euo pipefail (pipefail propagates kubectl's exit status through the
  # pipe even though wc/tr succeed). Fall back to 1 -- "not confirmed empty
  # yet" -- so the loop just retries. Same class of bug as PR #1's guard on
  # the old single-node wait loop; that patch doesn't apply to this rewritten
  # loop, so it's fixed here directly instead.
  remaining=$(kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE}" --no-headers 2>/dev/null | wc -l | tr -d ' ') || remaining=1
  [[ "$remaining" -eq 0 ]] && break
  sleep 5
done
kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}" 2>/dev/null || true
echo
echo "Workload re-entering scheduling, nowhere left to run:"
kubectl get pods -A -o wide -l "doks-spot-demo=true"

echo
echo "== Scaling up the pre-provisioned on-demand fallback pool: $ONDEMAND_POOL_NAME =="
if ! doctl kubernetes cluster node-pool get "$CLUSTER_NAME" "$ONDEMAND_POOL_NAME" >/dev/null 2>&1; then
  echo "On-demand pool '$ONDEMAND_POOL_NAME' doesn't exist -- launch.sh should have created it. Creating it now at size $ONDEMAND_GPU_SIZE."
  doctl kubernetes cluster node-pool create "$CLUSTER_NAME" \
    --name "$ONDEMAND_POOL_NAME" \
    --size "$ONDEMAND_GPU_SIZE" \
    --count "$GPU_COUNT" \
    --auto-scale \
    --min-nodes "$GPU_COUNT" \
    --max-nodes "$GPU_COUNT" \
    --tag "$TAG" \
    --label "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_ONDEMAND_VALUE}" \
    --label "doks-spot-demo-gpu-size=$ONDEMAND_GPU_SIZE"
else
  doctl kubernetes cluster node-pool update "$CLUSTER_NAME" "$ONDEMAND_POOL_NAME" \
    --count "$GPU_COUNT" \
    --auto-scale \
    --min-nodes "$GPU_COUNT" \
    --max-nodes "$GPU_COUNT" \
    --label "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_ONDEMAND_VALUE}" \
    --label "doks-spot-demo-gpu-size=$ONDEMAND_GPU_SIZE"
fi

echo
echo "== Waiting for the on-demand pool's node(s) to be Ready =="
ready=0
for _ in $(seq 1 90); do
  ready=$(kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_ONDEMAND_VALUE}" \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c True || true)
  [[ "$ready" -ge "$GPU_COUNT" ]] && break
  sleep 10
done
kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_ONDEMAND_VALUE}"
[[ "$ready" -ge "$GPU_COUNT" ]] || { echo "Timed out waiting for on-demand node(s) to be Ready" >&2; exit 1; }

echo
echo "== Waiting for the workload to recover on the on-demand pool =="
kubectl rollout status deployment/doks-spot-demo-workload -n default --timeout=300s

end=$(date +%s)
echo
echo "Recovery complete in $((end - start))s (spot pool reclaimed -> on-demand pool Ready -> workload Ready)."
echo "Spot pool '$SPOT_POOL_NAME' no longer exists. Restoring spot capacity means creating a brand-new spot pool, at whatever rate is in effect then."
