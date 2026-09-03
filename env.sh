#!/usr/bin/env bash
# Shared config for the doks-spot-demo spot-on-doks scripts. Source this, don't run it directly.
# shellcheck disable=SC2034  # every var here is consumed by whichever script sources it

PROJECT_NAME="doks-spot-demo"
PROJECT_PURPOSE="Spot-on-DOKS interruption tolerance testing"
TAG="doks-spot-demo"

REGION="${DO_REGION:-nyc2}"
K8S_VERSION="${DO_K8S_VERSION:-latest}"

CLUSTER_NAME="doks-spot-demo"

SYSTEM_POOL_NAME="system-doks-spot-demo"
SYSTEM_COUNT="${DO_SYSTEM_COUNT:-1}"

# Pool name prefixes carry the identifying word (system/spot/od) rather than
# suffixing it, because kube-ops-view truncates long node names down to
# whatever fits the node box and shows the start of the string -- with the
# old doks-spot-demo-<pool> naming, every node showed the same common prefix
# and nothing distinguishing. Since we can't color-code nodes in kube-ops-view
# (checked the source -- no per-node/per-label coloring support at all),
# this is the fallback for telling pools apart in the dashboard at a glance.

# Modeled on DOKS's actual spot-reclaim design: reclaiming a spot node pool
# takes the WHOLE pool down (not one node), and DOKS won't relaunch it --
# recovering spot capacity means standing up a brand-new spot pool at
# whatever rate is in effect then. The customer-recommended mitigation is a
# pre-provisioned on-demand fallback pool, so it exists here too, from
# launch.sh onward -- built and registered with the cluster, but at 0
# running nodes (see launch.sh for why 0 is a fixed count here, not
# autoscaler-managed: DOKS/doctl doesn't support scale-to-zero on an
# autoscaling pool). simulate-interruption.sh is what brings it to life.
SPOT_POOL_NAME="spot-doks-spot-demo"
ONDEMAND_POOL_NAME="od-doks-spot-demo"
GPU_COUNT="${DO_GPU_COUNT:-1}"

# Sizing follows AWS's C/M/R instance-family shorthand as a stand-in for
# real hardware classes, mapped onto DO's actual droplet families -- NOT a
# literal letter match. DO's own "m-" prefix means Memory-Optimized, which
# is the AWS-R equivalent, not AWS-M (General Purpose). DO has no "r-"
# family at all (checked via `doctl compute size list`). The mapping used
# here:
#   AWS C (compute-optimized) -> DO c-   (CPU-Optimized)      -- system pool
#   AWS M (general purpose)   -> DO g-   (General Purpose)    -- spot pool
#   AWS R (memory-optimized)  -> DO m-   (Memory-Optimized)   -- on-demand fallback pool
#
# Every instance-type knob follows the same rule: launch.sh's/simulate-
# interruption.sh's positional args win if given, else these DO_* env vars,
# else the hardcoded fallback here. One mechanism, three knobs -- change a
# default for good without editing a script, or override just one run.
#
# Plain c-/g-/m- sizes, all 2 vCPU: self-serve GPU capacity has been
# unavailable in every region tried so far, and for exercising the
# interruption/failover mechanics the actual hardware doesn't matter, only
# that a node in these pools can be interrupted and failed over. Pass real
# gpu-* slugs once capacity/PP allows.
DEFAULT_SYSTEM_SIZE="${DO_SYSTEM_SIZE:-c-2}"
DEFAULT_SPOT_GPU_SIZE="${DO_SPOT_GPU_SIZE:-g-2vcpu-8gb}"
DEFAULT_ONDEMAND_GPU_SIZE="${DO_ONDEMAND_GPU_SIZE:-m-2vcpu-16gb}"

# Mirrors the labeling/tainting scheme a customer would actually configure
# per DO's spot-fallback guidance: both pools carry this label so the
# workload's node affinity can express "either is eligible, spot preferred"
# -- but only the spot pool is tainted. The on-demand pool stays untainted
# (it's meant as a landing spot for anything that falls off spot, not an
# exclusive one).
POOL_TYPE_LABEL_KEY="gpu-pool-type"
POOL_TYPE_SPOT_VALUE="spot"
POOL_TYPE_ONDEMAND_VALUE="on-demand"
SPOT_TAINT="${POOL_TYPE_LABEL_KEY}=${POOL_TYPE_SPOT_VALUE}:NoSchedule"

KUBE_OPS_VIEW_NAMESPACE="doks-spot-demo-ops"
