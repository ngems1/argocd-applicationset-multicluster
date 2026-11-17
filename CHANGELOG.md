# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-17

### Added

- podinfo Helm chart (6.17.0) inflated by Kustomize in a base, with dev / staging / prod
  overlays: replicas, PodDisruptionBudgets, an HPA that owns prod's replica count, topology
  spread, restricted security contexts.
- AppProject `podinfo`: one repository, one namespace, four kinds, no cluster-scoped kinds.
- ApplicationSet `podinfo`: clusters generator selecting `code-clinic.io/env`, Go templates
  with `missingkey=error`, RollingSync dev → staging → prod, `applicationsSync: create-update`
  and `preserveResourcesOnDeletion`.
- Cluster onboarding with a namespace-scoped ServiceAccount, and a namespace-scoped cluster
  secret example. Argo CD Helm values (progressive syncs, `--enable-helm`).
- 45 static tests on the rendered manifests; kubeconform on Kubernetes 1.33-1.37 with the Argo
  CD CRD schemas; trivy config.
- End-to-end test on three kind clusters with the real Argo CD and an in-cluster git server:
  overlays per cluster, RollingSync order, drift detection, prod survives a lost label.

### Fixed (found by the end-to-end test)

- Namespace-scoped Argo CD could not build its cluster cache: it lists every namespaced kind,
  including ones the `admin` role doesn't cover (CSIStorageCapacity, the ApplicationSet CRD).
  Onboarding now adds a read-only Role in the managed namespace.
- The template's `selfHeal: true` has no effect while RollingSync is on: the controller sets
  `automated.enabled: false` on generated Applications, so drift is detected but not reverted.
  The e2e test first expected self-heal and failed; the template comment, ADR 0003, the README
  and the e2e test now state and check the real behaviour.
