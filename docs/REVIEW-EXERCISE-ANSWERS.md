# Code-review exercise: answers

The branch `review-exercise` contains a pull request, *"feat: onboard prod-eu-central-1 and
simplify the platform"* (description in `docs/REVIEW-EXERCISE-PR.md` on that branch). It looks
reasonable: a new prod cluster, "simpler" settings, tests updated so CI is green. It contains
**six** mistakes a senior reviewer should block. Review it first:

```bash
git fetch origin review-exercise
git diff main...origin/review-exercise
```

Write down every problem you find, why it matters, and what you'd ask the author to change.
Then open the answers one by one.

<details>
<summary>1. A real credential committed to Git (security hole)</summary>

`clusters/prod-eu-central-1.yaml` is a complete cluster Secret with a `bearerToken` and the
cluster's CA. Anyone with read access to the repository (and its history, forever) can now act
as Argo CD on that cluster. Deleting the file in a later commit doesn't help.

**Ask for:** remove the file, **revoke the token now** (delete the ServiceAccount token Secret
and recreate it), purge it from history if the repo is public, and deliver cluster secrets
with External Secrets / Sealed Secrets (README, THREAT-MODEL T2). gitleaks in CI would flag
it; the PR description says "gitleaks is noisy, ignore it", which is itself a red flag.
</details>

<details>
<summary>2. The AppProject now allows everything (security hole)</summary>

`sourceRepos: ["*"]` and `clusterResourceWhitelist: [{group: "*", kind: "*"}]` "to unblock the
ingress controller". Any repository can now deploy through this project, and any
cluster-scoped kind (ClusterRole, ClusterRoleBinding, CRDs, Namespaces...) is allowed: one
malicious manifest grants itself cluster-admin. The onboarding RBAC would still limit what
the credential can do, but the project was the second fence, and it's gone.

**Ask for:** keep the project locked to this repository; if an ingress controller is needed, it
belongs to the platform team's own project, with its own (reviewed) permissions.
</details>

<details>
<summary>3. Automatic deletion is back (dangerous default)</summary>

`applicationsSync: sync` "so decommissioned clusters get cleaned up automatically", and
`preserveResourcesOnDeletion` removed. Combined with mistake 4, a label typo (or the new
cluster secret being recreated) now **deletes** the prod Application **and every resource it
deployed**. The test that guarded this was changed to accept the new values.

**Ask for:** revert to `create-update` + `preserveResourcesOnDeletion: true` (ADR 0004). A
decommission is a runbook, not a side effect.
</details>

<details>
<summary>4. Any labelled cluster gets an Application, and template errors pass silently</summary>

The selector changed from `env In [dev, staging, prod]` to `env Exists`, and
`missingkey=error` was removed. Register a cluster with `env=qa` (or `env=Prod`) and the
ApplicationSet generates `podinfo-qa` pointing at `apps/podinfo/overlays/qa`, which doesn't
exist: a broken Application, or worse a wrong overlay. Without `missingkey=error`, a typo in
the template renders `<no value>` instead of failing.

**Ask for:** keep the explicit `In` list (adding an environment = adding an overlay + a list
entry in the same PR) and `missingkey=error`.
</details>

<details>
<summary>5. The prod PDB now blocks every drain (bad default, missing test)</summary>

Prod's PodDisruptionBudget went from `minAvailable: 2` to `3` "for more safety". With the HPA
at its minimum of 3 replicas, **no pod can ever be evicted**: node drains hang, so cluster and
node-group upgrades hang. The test `test_pdb_never_blocks_every_drain`, which catches exactly
this, was deleted ("flaky").

**Ask for:** `minAvailable: 2` (or `maxUnavailable: 1`), and the test back. A deleted test in a
PR that changes the thing it tested is always worth a question.
</details>

<details>
<summary>6. Prod runs whatever ":latest" is today (non-reproducible)</summary>

`image.tag: latest` was added to the base values "to always get security fixes". Every node
may now run a different image depending on when it pulled; a rollback to an older commit
doesn't roll the image back; dev, staging and prod no longer run the same tested artifact; and
RollingSync never sees a change, because the manifests didn't change. The image test was
weakened to only check that a tag exists.

**Ask for:** pin the chart (which pins the image) and let Renovate open a PR for new versions:
the update then goes through review and through dev → staging → prod.
</details>

## What a good review comment looks like

> **Blocking:** `clusters/prod-eu-central-1.yaml` contains a live bearer token. Please remove
> it, and I'll rotate the token on the cluster right away, since it's already in the history.
> Cluster secrets should come from our secret store (see THREAT-MODEL T2); happy to pair on the
> ExternalSecret.

Say what is wrong, why it matters, and what you'd like instead. Mark what blocks the merge,
and offer help.
