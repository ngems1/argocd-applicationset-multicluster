# 0003. Roll changes out dev → staging → prod with RollingSync

## Status

Accepted · 2026-11-16

## Context

Every environment tracks the `main` branch. Without ordering, a merge to `main` syncs dev,
staging and prod **at the same time**: a broken change reaches prod before anyone has seen it
fail in dev. We want each change to prove itself in the lower environments first, without a
human clicking "sync" three times.

## Options considered

### Option A: all environments sync at once (automated sync everywhere)

- ✅ Simplest; what you get by default.
- ❌ No blast-radius control: prod breaks together with dev.

### Option B: a branch or tag per environment (`targetRevision: env/prod`), promoted by PRs

- ✅ Explicit, auditable promotion; prod can stay on an older revision for weeks.
- ✅ Works with any tool, no feature flags.
- ❌ Branches drift (hotfixes on one, not the others); promotion PRs are manual work.
- ❌ The ApplicationSet template needs a per-environment revision (a label or a list).

### Option C: ApplicationSet RollingSync (progressive syncs), one revision for all

- ✅ One merge, automatic ordering: dev syncs first; staging only when every dev Application is
  Healthy; prod only after staging; `maxUpdate: 1` limits prod to one cluster at a time.
- ✅ No extra tool, no branch juggling; the order is declared next to the template.
- ❌ Behind a feature flag (`applicationsetcontroller.enable.progressive.syncs`).
- ❌ "Healthy" is the only gate: no soak time, no metric analysis, no human approval.
  A change that is healthy but wrong (bad config value) still reaches prod minutes later.
- ❌ **Self-heal is off.** The controller drives every sync, so it sets
  `automated.enabled: false` on each generated Application. A manual change in a cluster is
  detected (the Application turns `OutOfSync`) but is **not reverted** until the next rollout
  or a manual sync. The e2e test proves this on real clusters (step 7b).

### Option D: a promotion tool (Kargo, Argo Rollouts analysis, a CD pipeline)

- ✅ Soak times, metric checks, approvals, per-stage artifacts.
- ❌ Another system to run; beyond this project's scope.

## Decision

**Option C** for this project: it shows the ordering concept with nothing but Argo CD. The
e2e test proves the order on real clusters: a change to the base reaches dev, then staging,
then prod.

## Consequences

- **Good:** a change that breaks health in dev (crash loop, failing readiness) never leaves dev.
- **Bad:** drift is no longer healed automatically. Alert on Applications that stay
  `OutOfSync` (README, "Running this in production"); a scheduled no-op commit or a manual
  sync puts them back. Teams that value self-heal over ordering should drop RollingSync and
  use Option B.
- **Bad:** health is a weak signal; teams that need approvals or soak times should combine
  this with Option B (prod on a release tag) or move to Option D. The README's production
  section explains how to pause a rollout.
- **Follow-up:** project #46 (GitOps monorepo) revisits promotion with environment branches.
