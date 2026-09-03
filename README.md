# spot-on-doks

Interruption-tolerance test on DigitalOcean Kubernetes (DOKS): reclaim a
spot GPU node pool -- the **entire pool**, not one node -- and watch the
workload fail over onto a pre-provisioned on-demand fallback pool.

This mirrors DO's actual spot-reclaim design, not a generic "node dies,
autoscaler relaunches it" pattern: DOKS reclaims a spot pool as a whole
(never partially), and it doesn't come back on its own. Recovering spot
capacity means creating a brand-new spot pool, at whatever rate is in
effect then. The mitigation DO recommends is a separate on-demand GPU pool
configured as a fallback -- so that's what this demo builds and exercises.

Project: **doks-spot-demo**. Everything this creates is tagged and named
`doks-spot-demo` / `doks-spot-demo-*` so it doesn't get lost among other
resources in whatever account you run it against.

## Quickstart

```
./launch.sh                    # build the cluster, system pool, spot pool, an idle on-demand fallback pool, kube-ops-view, demo workload
open http://$(kubectl -n doks-spot-demo-ops get svc kube-ops-view -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
./simulate-interruption.sh     # reclaim the entire spot pool -> scale up the on-demand pool -> watch it come back
./teardown.sh                  # tear it all down when you're done
```

## Prerequisites

- `doctl`, authenticated (`doctl auth init`) to whatever DO account you want this in.
- `kubectl` and `jq` on `PATH`.
- Nothing else -- no Terraform, no Helm. `launch.sh` will tell you plainly if a prerequisite is missing.

## Node hardware: not the point, right now

This is meant to exercise the reclaim/failover mechanics ahead of GPU Spot going to private preview -- which hardware sits in each pool doesn't matter for that. `launch.sh`/`simulate-interruption.sh` default to plain compute nodes (guaranteed capacity, pennies/hour) rather than GPU sizes, because self-serve GPU capacity was unavailable in every region tried while building this (`ams3` and `nyc2`, across L40S, RTX 4000 Ada, and RTX 6000 Ada -- see git history if you want the receipts).

Sizes follow AWS's C/M/R instance-family shorthand as a stand-in for real
hardware classes, mapped onto DO's actual droplet families -- **not** a
literal letter match:

| Role | AWS family | DO family | Default slug |
|---|---|---|---|
| System | C (compute-optimized) | `c-` CPU-Optimized | `c-2` |
| Spot GPU-workload pool | M (general purpose) | `g-` General Purpose | `g-2vcpu-8gb` |
| On-demand fallback pool | R (memory-optimized) | `m-` Memory-Optimized | `m-2vcpu-16gb` |

The letter mismatch on the last row is real and worth remembering: DO's
`m-` prefix means Memory-Optimized, which is the AWS-**R** equivalent, not
AWS-M. DO has no `r-` family at all. All defaults are 2 vCPU.

`system-size`/`spot-gpu-size`/`ondemand-gpu-size` are plain arguments, though -- once GPU capacity or the PP program is in, swap in real `gpu-*` slugs and everything downstream (labeling, tainting, the demo workload's resource request, kube-ops-view) adjusts automatically. See "Why this isn't 'real' spot" below for what we learned about DOKS + spot GPUs specifically.

## Why this isn't "real" spot (hardware-wise)

Before writing any of this, we checked whether DOKS actually supports spot
GPU node pools. It doesn't, currently:

- DO's new **Spot GPU Droplets** (public preview, Aug 2026) are a standalone Droplet product -- control-panel-only provisioning, no doctl/API/Terraform support, limited to NVIDIA B300 and AMD MI350X/MI355X.
- Those GPUs *do* have real `-spot` billing slugs (e.g.  `gpu-mi350x1-288gb-spot` at $4.00/GPU/hr), confirmed via `doctl compute size list`. But `doctl kubernetes options sizes` -- the allowlist DOKS validates node-pool sizes against -- doesn't include any `-spot` slug, and for that same GPU family it doesn't include a self-serve on-demand slug either (only `-contracted`, i.e. enterprise commitment). So there's no path to a spot *or* plain on-demand DOKS node pool for that hardware today.
- Every other GPU family (H100, H200, L40S, RTX 4000/6000 Ada, MI300X, MI325X) has a normal self-serve on-demand slug that DOKS accepts -- when there's capacity for it.

So the hardware is simulated: both GPU-workload pools are regular node pools, labeled `gpu-pool-type=spot`/`gpu-pool-type=on-demand` so they're distinct, visually identifiable pools in kube-ops-view and the only place the demo workload will schedule. **The reclaim/failover mechanics themselves are modeled on DO's actual documented spot-reclaim design, not simulated loosely** -- see below.

## How a real spot reclaim behaves (and how this demo matches it)

- **The whole pool goes, not one node.** DOKS reclaims a spot node pool in its entirety via the `DeleteNodePool` API -- never a partial reclaim of individual nodes. `simulate-interruption.sh` calls the same API (`doctl kubernetes cluster node-pool delete`), not a per-Droplet delete.
- **The delete is graceful, not a hard kill.** `DeleteNodePool` cordons and drains every node in the pool -- respecting PodDisruptionBudgets -- before deleting, with a drain timeout. This script doesn't add its own cordon/drain step; that would be redundant with what DOKS already does server-side.
- **A native Kubernetes Event fires the moment the reclaim signal is received**, so a third-party scheduler (Kueue, Volcano, Ray) or a customer's own hook can react without polling DO's side. `simulate-interruption.sh` prints recent Node events right after triggering the delete, to make this visible.
- **Recovery depends entirely on whether a fallback pool exists.** Evicted pods re-enter scheduling immediately and land on a backup on-demand pool automatically *if one exists*; if not, they stay Pending. Getting spot capacity back means creating a brand-new spot pool, at the rate in effect then -- the old one never comes back. `simulate-interruption.sh`'s closing message says this explicitly.
- **The fallback pattern: label both pools, taint only spot, prefer spot via soft affinity.** DO's recommended customer setup is `gpu-pool-type=spot` / `gpu-pool-type=on-demand` labels, a `NoSchedule` taint on the spot pool only, a toleration on the workload for that taint, and node affinity that makes *both* pools eligible with spot preferred (`preferredDuringSchedulingIgnoredDuringExecution`, not a hard requirement). That's exactly what `launch.sh`'s deployment manifest does.
- **One real gap versus the fully-automatic version of this pattern:** DO's design calls for the fallback pool to already exist and for cluster-autoscaler (with a priority expander) to notice pending pods and scale it up hands-off. `doctl`/DOKS currently don't support scale-to-zero on an autoscaling pool ("Scale-to-zero is not supported" per `doctl kubernetes cluster node-pool create --help`), so a pool sitting at 0 nodes has no autoscaler coverage to bring it to life on its own. `launch.sh` still pre-provisions the on-demand pool at 0 nodes (so it's registered with the cluster and costs nothing until needed, matching the intent), but `simulate-interruption.sh` does the 0→N scale-up explicitly (`node-pool update --count N --auto-scale`) rather than relying on the autoscaler to do it unprompted. End state is the same either way.

## How it fits together

```
doks-spot-demo (project)
  |
  +-- doks-spot-demo (DOKS cluster, nyc2 by default)
        |
        +-- system-doks-spot-demo (node pool, on-demand, c-2)
        |     +-- kube-ops-view          (doks-spot-demo-ops namespace)
        |     +-- CoreDNS / cluster addons
        |
        +-- spot-doks-spot-demo (node pool, autoscaling min=max=N, g-2vcpu-8gb)
        |     taint:  gpu-pool-type=spot:NoSchedule
        |     label:  gpu-pool-type=spot, doks-spot-demo-gpu-size=<slug>
        |     +-- doks-spot-demo-workload          (the workload we reclaim -- starts here)
        |
        +-- od-doks-spot-demo (node pool, pre-provisioned at 0 nodes, m-2vcpu-16gb)
              no taint -- open landing spot for anything that falls off spot
              label:  gpu-pool-type=on-demand, doks-spot-demo-gpu-size=<slug>
              +-- doks-spot-demo-workload          (fails over here once the spot pool is reclaimed)
```

The workload's pod spec carries a toleration for the spot taint plus node
affinity that requires either pool but prefers spot
(`preferredDuringSchedulingIgnoredDuringExecution`, weight 100) -- so it
starts on spot whenever spot capacity exists, and is equally schedulable on
the on-demand pool once that's the only one left.

## Layout

```
env.sh                        shared config (names, tags, sizes, region) -- sourced, not run
launch.sh                     build: project, cluster, system pool, spot pool, idle on-demand pool, kube-ops-view, demo workload
simulate-interruption.sh      reclaim the spot pool -> scale up the on-demand pool -> watch recovery
teardown.sh                   delete the cluster and everything it created
manifests/kube-ops-view.yaml
```

## Usage

```
./launch.sh [system-size] [spot-gpu-size] [ondemand-gpu-size]
```

All three are droplet size slugs -- see `doctl kubernetes options sizes` for valid values. Defaults are `c-2` / `g-2vcpu-8gb` / `m-2vcpu-16gb` (see "Node hardware" above). The on-demand pool is created at 0 nodes -- registered with the cluster, costing nothing, until `simulate-interruption.sh` scales it up.

Change a default for good without editing any script: set `DO_SYSTEM_SIZE`, `DO_SPOT_GPU_SIZE`, or `DO_ONDEMAND_GPU_SIZE`. Same mechanism for all three -- an arg on the command line wins if given, else the env var, else the hardcoded fallback in `env.sh`. Region is a separate axis (where, not what) and isn't positional -- set `DO_REGION` (default `nyc2`).

Idempotent -- re-running skips anything that already exists.

```
./simulate-interruption.sh [ondemand-gpu-size]
```

Deletes the entire spot GPU-workload node pool via the DOKS API (`DeleteNodePool` -- DOKS drains it server-side, respecting PDBs, before deleting; no separate cordon/drain step needed here), prints the Node events fired at the moment of reclaim, confirms the pool's node(s) are gone from the cluster, then scales the pre-provisioned on-demand pool from 0 to its target count and watches for it to come Ready and the demo workload to roll back to Ready on it. Prints total recovery time. The `ondemand-gpu-size` arg only matters if the on-demand pool doesn't already exist (normally `launch.sh` created it, so this is a no-op override).

```
./teardown.sh [--yes]
```

Deletes the cluster and its associated load balancers/volumes. Leaves the `doks-spot-demo` project in place (it's just an org container, no cost) for reuse on the next run. `--yes` skips the confirmation prompt.

## Watching it

kube-ops-view runs as a `LoadBalancer` Service on the cluster itself -- it's DO serving the dashboard, not your laptop. Get its public IP once `launch.sh` finishes:

```
kubectl -n doks-spot-demo-ops get svc kube-ops-view
open http://<EXTERNAL-IP>
```

Hover a node box to see its labels -- both GPU-workload pools carry
`doks-spot-demo-gpu-size=<slug>`; `gpu-pool-type=spot`/`on-demand` tells them apart.

It's unauthenticated -- anyone with the IP can see cluster/pod state (nothing secret, but it is a real public IP for as long as the cluster is up). That's also the tradeoff for a real DO Load Balancer versus a local port-forward: a few dollars/month while it exists, in exchange for something that isn't tied to your laptop staying open.

## Cost

The system and spot pools bill hourly from `launch.sh` onward. The on-demand pool bills nothing until `simulate-interruption.sh` scales it up from 0. Defaults are pennies (`c-2` ~$0.0625/hr, `g-2vcpu-8gb` ~$0.09375/hr, `m-2vcpu-16gb` ~$0.125/hr once scaled up); swapping in real GPU sizes later raises that a lot ($0.76-$4.47+/GPU/hr, see pricing page). Run `./teardown.sh` when you're done testing rather than leaving it up.

## Troubleshooting

- **`spot-gpu-size` or `ondemand-gpu-size` gets rejected.** For GPU slugs this is almost always capacity, not the slug -- retry in a different region: `DO_REGION=nyc2 ./launch.sh <system-size> <spot-size> <ondemand-size>`. Plain `c-`/`g-`/`m-`/`s-` sizes have never failed this way in practice.
- **Creating the on-demand pool at `--count 0` gets rejected.** Not verified against a live cluster while building this -- if DOKS requires `count >= 1` even without autoscaling, the fallback is to create it at `--count 1` (accepting the small always-on cost) instead of 0, and skip the scale-up-from-zero step in `simulate-interruption.sh` (just `node-pool update --auto-scale --min-nodes N --max-nodes N` from there).
- **A GPU-size demo workload stays `Pending` forever.** Means the pool's actual size doesn't have a matching device-plugin resource (`nvidia.com/gpu` / `amd.com/gpu`) -- check `doks-spot-demo-gpu-size` matches what you think it is, and that `--enable-nvidia-gpu-device-plugin` / `--enable-amd-gpu-device-plugin` were set at cluster creation (they are, by default, in `launch.sh`).
- **The on-demand pool comes up but the workload never reschedules onto it.** Confirm it carries `gpu-pool-type=on-demand` -- that's what the workload's node affinity matches on (it doesn't need the taint/toleration, only the spot pool is tainted). `simulate-interruption.sh` sets this automatically.
- **The spot pool disappears and no replacement ever shows up.** That's expected by design -- DOKS won't relaunch a reclaimed spot pool on its own; getting spot capacity back means running `launch.sh`-style pool creation again for a *new* spot pool. If the *on-demand* pool's node is lost after failover, check it's actually autoscaling: `doctl kubernetes cluster node-pool get doks-spot-demo od-doks-spot-demo -o json | jq '.[0] | {auto_scale, min_nodes, max_nodes}'`. If `auto_scale` is `false`, cluster-autoscaler has no coverage on that pool at all and a lost node just stays lost -- fix with `doctl kubernetes cluster node-pool update doks-spot-demo od-doks-spot-demo --auto-scale --min-nodes N --max-nodes N`.
- **kube-ops-view shows blank / connection refused right after `launch.sh`.** Give the pod a few seconds to pass its readiness probe, then retry the port-forward.

## Expanding this

- More nodes per pool (`DO_GPU_COUNT=2 ./launch.sh`) to test partial-fleet loss within the on-demand pool after failover, versus the spot pool's always-total reclaim.
- Swap `spot-gpu-size`/`ondemand-gpu-size` for real `gpu-*` slugs once capacity/PP allows -- note the demo workload's resource request (`nvidia.com/gpu` vs `amd.com/gpu`) is set once at `launch.sh` time from the spot pool's size, so an on-demand pool on a different GPU vendor would need that request updated too.
- Demonstrate the "no fallback configured" case from DO's spec (evicted pods just stay Pending): run `launch.sh`, then manually delete the on-demand pool before running `simulate-interruption.sh`.
- GPU-utilization-based autoscaling isn't in scope here (the demo workload doesn't actually use a GPU right now) -- if you want that, install [KEDA](https://keda.sh) and scale the pool/workload off a real utilization metric.
