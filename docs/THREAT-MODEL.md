# Threat model

**Scope:** Argo CD on the management cluster, the cluster secrets that give it access to the
workload clusters, the AppProject and ApplicationSet in `platform/`, and the manifests in
`apps/`. Trust boundaries: *Git (anyone who can merge) → Argo CD*, *Argo CD → each workload
cluster (through its credential)*, *the Helm chart repository → the rendered manifests*.

**Out of scope:** the security of podinfo itself, the Kubernetes control planes, the cloud
accounts the clusters run in, and Argo CD's own UI/SSO hardening (only noted where it matters).

## Assets

- **Workload clusters**, prod first: what runs there and its availability.
- **Cluster credentials** stored by Argo CD (one per workload cluster).
- **The Git repository**: whoever can merge to `main` deploys to every cluster.
- **Argo CD itself** (management cluster): it holds every credential above.

## Threats

| # | Asset | Threat | Likelihood / Impact | Mitigation in this repo | Residual risk / NOT protected against |
|---|---|---|---|---|---|
| T1 | workload clusters | **Over-privileged Argo CD credential**: a compromised Argo CD (or a malicious manifest) gets cluster-admin on every cluster (`argocd cluster add` default) | M / H | `clusters/onboarding.yaml`: a ServiceAccount bound to `admin` in **one namespace**; cluster secret in namespace-scoped mode (`namespaces: podinfo`, `clusterResources: "false"`); test `test_onboarding_grants_one_namespace_only` | the token can still do anything inside `podinfo`, including reading its Secrets |
| T2 | cluster credentials | **Credential leak** from cluster secrets committed to Git or long-lived tokens copied around | M / H | only an example with placeholders is committed; README: deliver secrets with External Secrets / Sealed Secrets; gitleaks in CI | the lab uses long-lived ServiceAccount tokens; production should use short-lived ones (EKS IAM via `awsAuthConfig`, GKE/AKS workload identity) |
| T3 | workload clusters | **Malicious or mistaken manifest merged to `main`** deploys everywhere | M / H | AppProject: one source repo, one namespace, a whitelist of 4 kinds, no cluster-scoped kinds; restricted Pod Security on the namespace; RollingSync stops at the first unhealthy environment | a healthy-but-malicious change still reaches prod; branch protection + review on `main` are the control (GitHub settings) |
| T4 | prod availability | **Automatic deletion**: a removed/mistyped cluster label, a renamed ApplicationSet or a recreated cluster secret deletes the prod Application and its resources | M / H | `applicationsSync: create-update` + `preserveResourcesOnDeletion: true` (ADR 0004); e2e removes the prod label and asserts prod survives | `prune: true` still deletes resources removed from Git (intended); a human with Argo CD admin can delete anything |
| T5 | prod availability | **Change reaches prod too fast** (bad image, crash loop) | M / M | RollingSync dev → staging → prod, gated on health, `maxUpdate: 1` for prod clusters (ADR 0003); PDB and HPA in prod | health is the only gate: no soak time or metrics; config errors that stay "Healthy" pass |
| T6 | rendered manifests | **Supply chain of the Helm chart**: the chart repo serves a modified chart for the same version | L / H | chart version pinned; the static tests and kubeconform check every render; image pinned to one version for all envs | Helm repositories have no digest pinning here; mirror charts to an OCI registry you control and verify provenance |
| T7 | rendered manifests | **Template injection / wrong destination** from cluster labels (labels are attacker-controlled by whoever can edit cluster secrets) | L / M | label values only select among `dev`/`staging`/`prod` (generator `In` selector) and paths that exist (static test); `missingkey=error` | an admin who can edit cluster secrets can point an environment at another overlay |
| T8 | Argo CD | **Argo CD UI/API exposed** with the initial admin password | M / H | the lab never exposes the UI (port-forward only); dex disabled | production needs SSO, RBAC (`policy.csv`), no local admin, network policies: see LEARN further reading |
| T9 | Git | **Fork PR code runs in CI** with secrets | L / M | CI uses `pull_request` (no secrets for forks) and read-only permissions; the e2e needs no secret | — |
| T10 | workload clusters | **Manual drift stays**: a `kubectl edit` in a cluster (hotfix, attacker with namespace access) is not reverted, because RollingSync disables auto-sync | M / M | Argo CD still detects it (`OutOfSync`); the e2e asserts detection; README: alert on `OutOfSync` for more than 15 minutes | until someone syncs, the cluster differs from Git; drop RollingSync if self-heal matters more than ordering (ADR 0003) |

## Assumptions

- `main` is protected: reviews and the CI checks are required before merge.
- The management cluster is at least as protected as the most sensitive workload cluster:
  whoever owns Argo CD owns every cluster it can reach.
- Cluster onboarding (`clusters/onboarding.yaml`) is applied by the platform team, not by
  Argo CD, so the application can never widen its own permissions.

## How to verify

- `make test`: `test_project_is_locked_down`, `test_onboarding_grants_one_namespace_only`,
  `test_example_cluster_secret_is_namespace_scoped_and_has_no_real_credential`,
  `test_never_deletes_applications_or_their_resources`, `test_every_rendered_kind_is_allowed_by_the_appproject` (T1-T4).
- `make e2e`: step 7c (label removed, prod survives), RollingSync order (T4, T5).
- [Drills](DRILLS.md) 1-3.
