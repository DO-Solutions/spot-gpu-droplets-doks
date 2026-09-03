#!/usr/bin/env bash
# Builds the doks-spot-demo cluster: a system node pool, a spot GPU-workload
# pool, and a pre-provisioned on-demand fallback pool at 0 running nodes --
# built and registered with the cluster from the start, per DO's recommended
# spot-fallback setup, but not costing anything until an interruption is
# simulated and it's scaled up to take over. Idempotent -- safe to re-run.
#
# Usage: ./launch.sh [system-size] [spot-gpu-size] [ondemand-gpu-size]
#
# All three are droplet size slugs -- see `doctl kubernetes options sizes`
# for valid values. Any arg you omit falls back to its DO_SYSTEM_SIZE /
# DO_SPOT_GPU_SIZE / DO_ONDEMAND_GPU_SIZE env var, then to the hardcoded
# default in env.sh -- same mechanism for all three.
#
# Region is a separate axis (where, not what) and isn't positional: set
# DO_REGION to change it (default nyc2).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./env.sh
source ./env.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  grep '^#' "$0" | sed 's/^# \?//'
  exit 0
fi

SYSTEM_SIZE="${1:-$DEFAULT_SYSTEM_SIZE}"
SPOT_GPU_SIZE="${2:-$DEFAULT_SPOT_GPU_SIZE}"
ONDEMAND_GPU_SIZE="${3:-$DEFAULT_ONDEMAND_GPU_SIZE}"

gpu_resource_key() {
  case "$1" in
    gpu-*mi3*) echo "amd.com/gpu" ;;
    gpu-*) echo "nvidia.com/gpu" ;;
    *) echo "" ;;  # not a GPU size -- plain node, no device-plugin resource to request
  esac
}

echo "== Preflight =="
command -v doctl >/dev/null || { echo "doctl not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
[[ -f manifests/kube-ops-view.yaml ]] || { echo "manifests/kube-ops-view.yaml not found" >&2; exit 1; }

doctl account get >/dev/null || { echo "doctl isn't authenticated -- run 'doctl auth init'" >&2; exit 1; }

echo
echo "== Project =="
project_id=$(doctl projects list -o json | jq -r --arg n "$PROJECT_NAME" '.[] | select(.name==$n) | .id' | head -n1)
if [[ -z "$project_id" ]]; then
  echo "Creating project '$PROJECT_NAME'..."
  project_id=$(doctl projects create --name "$PROJECT_NAME" --purpose "$PROJECT_PURPOSE" --environment Development --format ID --no-header)
else
  echo "Project '$PROJECT_NAME' exists ($project_id)"
fi

echo
echo "== Cluster =="
if doctl kubernetes cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Cluster '$CLUSTER_NAME' exists, reusing."
else
  echo "Creating cluster '$CLUSTER_NAME' in $REGION..."
  doctl kubernetes cluster create "$CLUSTER_NAME" \
    --region "$REGION" \
    --version "$K8S_VERSION" \
    --tag "$TAG" \
    --enable-nvidia-gpu-device-plugin=true \
    --enable-amd-gpu-device-plugin=true \
    --node-pool "name=${SYSTEM_POOL_NAME};size=${SYSTEM_SIZE};count=${SYSTEM_COUNT};tag=${TAG}" \
    --wait
fi

cluster_id=$(doctl kubernetes cluster get "$CLUSTER_NAME" --format ID --no-header)
# Reflect where the cluster actually is, not just the region we requested --
# matters when reusing a cluster created by an earlier run with a different DO_REGION.
REGION=$(doctl kubernetes cluster get "$CLUSTER_NAME" --format Region --no-header)

doctl projects resources assign "$project_id" --resource="do:kubernetes:${cluster_id}" >/dev/null 2>&1 \
  && echo "Cluster assigned to project '$PROJECT_NAME'" \
  || echo "Warning: couldn't assign cluster to project (non-fatal, check manually)"

echo
echo "== Spot GPU-workload node pool =="
if doctl kubernetes cluster node-pool get "$CLUSTER_NAME" "$SPOT_POOL_NAME" >/dev/null 2>&1; then
  echo "Spot pool '$SPOT_POOL_NAME' exists, reusing."
  gpu_size=$(doctl kubernetes cluster node-pool get "$CLUSTER_NAME" "$SPOT_POOL_NAME" --format Size --no-header)
else
  echo "Creating spot pool '$SPOT_POOL_NAME' at size $SPOT_GPU_SIZE..."
  # auto-scale with min=max=GPU_COUNT: a fixed-size pool has no cluster-autoscaler
  # coverage at all, so a lost node just leaves its pods Pending forever (verified
  # the hard way). Autoscaling with min==max keeps the steady-state count fixed
  # while giving the autoscaler a pending pod to react to if a node disappears
  # within this pool. It does NOT help if the whole pool is reclaimed -- that's
  # what the on-demand pool below is for.
  doctl kubernetes cluster node-pool create "$CLUSTER_NAME" \
    --name "$SPOT_POOL_NAME" \
    --size "$SPOT_GPU_SIZE" \
    --count "$GPU_COUNT" \
    --auto-scale \
    --min-nodes "$GPU_COUNT" \
    --max-nodes "$GPU_COUNT" \
    --tag "$TAG" \
    --label "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE}" \
    --label "doks-spot-demo-gpu-size=$SPOT_GPU_SIZE" \
    --taint "$SPOT_TAINT"
  gpu_size="$SPOT_GPU_SIZE"
fi
echo "Spot pool size in use: $gpu_size"

echo
echo "== On-demand fallback pool (pre-provisioned, 0 nodes) =="
if doctl kubernetes cluster node-pool get "$CLUSTER_NAME" "$ONDEMAND_POOL_NAME" >/dev/null 2>&1; then
  echo "On-demand pool '$ONDEMAND_POOL_NAME' exists, reusing."
else
  echo "Creating on-demand pool '$ONDEMAND_POOL_NAME' at size $ONDEMAND_GPU_SIZE, 0 nodes..."
  # Fixed at count=0, NOT autoscaling: doctl/DOKS don't support scale-to-zero
  # on an autoscaling pool ("Scale-to-zero is not supported" per `doctl
  # kubernetes cluster node-pool create --help`), so there's no way to
  # register this pool ahead of time, at zero cost, and have
  # cluster-autoscaler alone bring it from 0 -> N automatically once spot
  # pods go pending. simulate-interruption.sh does that scale-up explicitly
  # instead (node-pool update --count N --auto-scale), which is the same
  # end state a fully-automatic priority-expander setup would reach --
  # we're just triggering it ourselves rather than DOKS's autoscaler.
  # No taint here, unlike the spot pool -- this pool is meant as a landing
  # spot for anything that falls off spot, not an exclusive one.
  doctl kubernetes cluster node-pool create "$CLUSTER_NAME" \
    --name "$ONDEMAND_POOL_NAME" \
    --size "$ONDEMAND_GPU_SIZE" \
    --count 0 \
    --tag "$TAG" \
    --label "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_ONDEMAND_VALUE}" \
    --label "doks-spot-demo-gpu-size=$ONDEMAND_GPU_SIZE"
fi

echo
echo "== Waiting for the spot pool's node(s) to be Ready =="
ready=0
for _ in $(seq 1 90); do
  ready=$(kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE}" \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c True || true)
  [[ "$ready" -ge "$GPU_COUNT" ]] && break
  sleep 10
done
kubectl get nodes -l "${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE}"
[[ "$ready" -ge "$GPU_COUNT" ]] || { echo "Timed out waiting for spot pool node(s) to be Ready" >&2; exit 1; }

echo
echo "== kube-ops-view =="
kubectl apply -f manifests/kube-ops-view.yaml

echo
echo "== Demo workload =="
gpu_resource_key=$(gpu_resource_key "$gpu_size")
resources_block=""
if [[ -n "$gpu_resource_key" ]]; then
  resources_block=$(cat <<RES
          resources:
            limits:
              ${gpu_resource_key}: "1"
RES
)
fi
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: doks-spot-demo-workload
  namespace: default
  labels:
    app: doks-spot-demo-workload
    doks-spot-demo: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: doks-spot-demo-workload
  template:
    metadata:
      labels:
        app: doks-spot-demo-workload
        doks-spot-demo: "true"
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: ${POOL_TYPE_LABEL_KEY}
                    operator: In
                    values: ["${POOL_TYPE_SPOT_VALUE}", "${POOL_TYPE_ONDEMAND_VALUE}"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: ${POOL_TYPE_LABEL_KEY}
                    operator: In
                    values: ["${POOL_TYPE_SPOT_VALUE}"]
      tolerations:
        - key: ${POOL_TYPE_LABEL_KEY}
          operator: Equal
          value: ${POOL_TYPE_SPOT_VALUE}
          effect: NoSchedule
      terminationGracePeriodSeconds: 10
      containers:
        - name: workload
          image: ubuntu:22.04
          command: ["sh", "-c", "echo doks-spot-demo-workload started \$(date -Iseconds); sleep infinity"]
${resources_block}
          readinessProbe:
            exec:
              command: ["true"]
            initialDelaySeconds: 2
            periodSeconds: 5
EOF
kubectl rollout status deployment/doks-spot-demo-workload -n default --timeout=180s

cat <<EOF

== Done ==
Cluster:      $CLUSTER_NAME ($REGION)
Project:      $PROJECT_NAME
System pool:  $SYSTEM_POOL_NAME -- size: $SYSTEM_SIZE
Spot pool:    $SPOT_POOL_NAME -- size: $gpu_size, resource: $gpu_resource_key
On-demand:    $ONDEMAND_POOL_NAME -- size: $ONDEMAND_GPU_SIZE, 0 nodes (pre-provisioned, scales up on interruption)

View kube-ops-view (it's a LoadBalancer Service -- the IP can take a minute or two to be assigned):
  kubectl -n $KUBE_OPS_VIEW_NAMESPACE get svc kube-ops-view -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  open http://<IP-FROM-ABOVE>
  (hover a node box to see its labels -- look for ${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE})

Next: ./simulate-interruption.sh
EOF
