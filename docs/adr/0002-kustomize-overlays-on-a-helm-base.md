# 0002. Kustomize overlays on top of a Helm-inflated base

## Status

Accepted · 2026-11-16

## Context

podinfo is published as a Helm chart. Each environment needs a few differences: replica
count, a PodDisruptionBudget in staging and prod, an HPA and topology spread in prod, and
different resources. The challenge asks for a "Kustomize/Helm pattern".

## Options considered

### Option A: Helm only, a values file per environment (Argo CD multi-source `$values`)

- ✅ The most common pattern; values files are easy to read.
- ✅ No `--enable-helm` flag needed in Argo CD.
- ❌ You can only change what the chart exposes as values. Anything else (a field the chart
  doesn't template, an extra resource) means forking the chart.
- ❌ Multi-source Applications are harder to reason about (two sources, one `ref`).

### Option B: Kustomize only, plain YAML copied from the chart

- ✅ No Helm at all; everything is visible YAML.
- ❌ We now own a copy of the chart's manifests and must merge every upstream release by hand.

### Option C: Kustomize base that inflates the chart (`helmCharts:`), overlays patch the result

- ✅ Helm does the packaging (upstream fixes arrive by bumping one version); Kustomize
  changes **anything** in the rendered output, per environment, with small patches.
- ✅ Each overlay is a short diff against the base: reviewers see only what differs.
- ✅ `kustomize build --enable-helm apps/podinfo/overlays/prod` shows exactly what Argo CD
  will apply; the static tests run on that output.
- ❌ Argo CD must run Kustomize with `--enable-helm` (a global setting, see
  `bootstrap/argocd/values.yaml`), and the repo-server downloads the chart at render time.
- ❌ Two tools to understand; patches target rendered names, so a chart that renames a
  resource breaks a patch (the build fails loudly, which is what we want).

## Decision

**Option C.** Shared settings (security contexts, base resources, the pinned chart version)
live in `apps/podinfo/base/values.yaml`; overlays only patch and add resources. `skipTests:
true` keeps the chart's `helm test` Pods out of the manifests.

## Consequences

- **Good:** prod's "no `replicas` when an HPA exists" is a one-line JSON patch, impossible with
  this chart's values alone without also changing dev and staging.
- **Good:** one chart version for every environment: promotion moves one artifact.
- **Bad:** the chart is fetched from its Helm repository on every render; if that repository is
  down, syncs fail. Production fix: mirror charts to an OCI registry you control.
- **Bad:** a chart upgrade can silently change what a patch matches; `make test` renders all
  overlays and checks invariants on every change, and kubeconform validates them in CI.
