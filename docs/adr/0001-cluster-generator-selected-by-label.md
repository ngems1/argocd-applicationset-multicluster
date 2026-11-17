# 0001. Generate one Application per cluster from labelled cluster secrets

## Status

Accepted · 2026-11-16

## Context

The same application must run on several clusters, one environment per cluster (dev,
staging, prod today; a second prod region tomorrow). Something has to produce one Argo CD
`Application` per cluster, each pointing at the right overlay and destination. Adding a
cluster should be a small, reviewable change that can't break the clusters already there.

## Options considered

### Option A: hand-written Applications, one YAML per environment

- ✅ Nothing to learn beyond `Application`.
- ❌ N copies that drift apart (a sync option added to dev, forgotten in prod).
- ❌ Adding a cluster means copying a file and remembering every field.

### Option B: ApplicationSet with a `list` generator (the naive version)

- ✅ One template, explicit list of clusters in Git.
- ❌ The cluster list lives in two places: Argo CD's cluster secrets AND the list. A server URL
  typo in the list deploys nowhere (or to the wrong cluster).
- ❌ Removing an element deletes that environment's Application (and, without safeguards,
  everything it deployed).

### Option C: ApplicationSet with the `clusters` generator, selecting clusters by label

- ✅ Registering a cluster (a Secret with `code-clinic.io/env: prod`) is the only step; the
  ApplicationSet picks it up. One source of truth for "which clusters exist".
- ✅ Labels carry the metadata the template needs (`env`, later `region`, `tier`).
- ❌ Indirection: to know where podinfo runs you must look at cluster secrets, not this repo.
- ❌ A label typo or a removed label changes what is deployed: mitigated by ADR 0004.

### Option D: `matrix` of clusters × git directories (one app per cluster per env directory)

- ✅ Several environments per cluster (dev and staging on one non-prod cluster).
- ❌ More complex templates and selectors; not needed while each cluster hosts one environment.

## Decision

**Option C.** The generator selects clusters whose `code-clinic.io/env` label is one of
`dev`, `staging`, `prod`; the label value picks the overlay. Go templates with
`missingkey=error`, so a typo in the template fails instead of rendering `<no value>`.

## Consequences

- **Good:** adding the second prod cluster is one labelled Secret; RollingSync's
  `maxUpdate: 1` already handles several prod clusters one at a time.
- **Good:** the static tests prove every selected label value has an overlay, and every
  overlay is selected.
- **Bad:** cluster secrets become production configuration: they need review, and they hold
  credentials (THREAT-MODEL T2). Manage them as code (External Secrets, Sealed Secrets, or
  the cloud's cluster registration), never by hand.
- **Revisit** if one cluster must host several environments: move to Option D.
