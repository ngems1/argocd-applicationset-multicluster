# 0004. The ApplicationSet never deletes Applications or their resources by itself

## Status

Accepted · 2026-11-16

## Context

An ApplicationSet owns the Applications it generates. By default, when a generator stops
producing an element, the ApplicationSet **deletes** that Application, and an Application with
the resources finalizer **deletes everything it deployed**. Things that make a generator
"stop producing" prod:

- someone removes or mistypes the `code-clinic.io/env` label on the prod cluster secret;
- someone deletes or recreates the ApplicationSet (a rename, a move to another namespace);
- the cluster secret is rotated by deleting and recreating it.

Each of these is a routine change that turns into a prod outage with this default.

## Options considered

### Option A: defaults (`applicationsSync: sync`, resources deleted with the Application)

- ✅ Fully declarative: removing a cluster from Git cleans it up.
- ❌ One label typo deletes production. No confirmation, no undo.

### Option B: `preserveResourcesOnDeletion: true` only

- ✅ Workloads survive the deletion of their Application.
- ❌ The Application still disappears: prod is running but **unmanaged** (no self-heal, no
  sync, no visibility) until someone notices.

### Option C: `applicationsSync: create-update` + `preserveResourcesOnDeletion: true`

- ✅ The controller creates and updates Applications but never deletes them; and if an
  Application is deleted anyway (by hand, or with the ApplicationSet), its resources stay.
- ✅ A missing label shows up as a stale Application that someone must remove on purpose.
- ❌ Decommissioning a cluster needs a manual step (delete the Application, then clean up).
- ❌ Stale Applications can accumulate if nobody looks.

## Decision

**Option C.** Deletion of anything in production is an explicit, human action. The e2e test
removes the env label from the prod cluster and asserts that `podinfo-prod` and its pods are
still there.

## Consequences

- **Good:** the most dangerous class of GitOps accident (automatic deletion through a label or
  a rename) is closed.
- **Bad:** a decommission runbook is needed (README, "Running this in production").
- **Bad:** `prune: true` inside each Application still deletes resources removed from Git.
  That is intended (Git is the source of truth for what runs *inside* the app); `PruneLast`
  orders it after new resources are applied.
