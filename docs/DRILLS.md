# Failure drills

Three ways to break a multi-cluster GitOps setup, on the local kind lab. Nothing here touches
a real cluster or costs money.

**Setup** (once, ~10 minutes):

```bash
make e2e-up       # three kind clusters + Argo CD + the ApplicationSet, all checks green
make e2e-shell    # a shell on the kind network; KUBECONFIG points at cc-dev (Argo CD)
```

Inside that shell, a helper to change "Git" (the in-cluster git server that Argo CD reads):

```bash
kubectl -n git port-forward svc/git-server 19418:9418 >/dev/null 2>&1 &
git clone -q git://localhost:19418/repo.git /tmp/lab && cd /tmp/lab
git config user.name me && git config user.email me@example.invalid
push() { git push -q origin HEAD:main; kubectl -n argocd annotate applicationset podinfo argocd.argoproj.io/refresh=true --overwrite >/dev/null; }
apps() { kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status; }
```

`make e2e-down` deletes everything when you're done.

## Drill 1: A typo in the prod cluster's label

**Scenario.** Someone edits the prod cluster secret and types `prd` instead of `prod`:

```bash
kubectl -n argocd label secret cluster-prod code-clinic.io/env=prd --overwrite
sleep 45; apps
kubectl -n argocd get applicationset podinfo -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

Then repeat it with the **default** deletion policy, as most tutorials have it:

```bash
kubectl -n argocd patch applicationset podinfo --type merge -p '{"spec":{"syncPolicy":{"applicationsSync":"sync"}}}'
sleep 45; apps
kubectl --kubeconfig .e2e/prod.kubeconfig -n podinfo get deploy podinfo
```

Restore: set `applicationsSync` back to `create-update` and the label back to `prod`.

**What to observe.** With this repo's settings, all three Applications are still there and
Synced/Healthy; the ApplicationSet reports `InvalidRolloutConfig=True: Steps [3] have no
applications matching their criteria`. With `applicationsSync: sync`, **`podinfo-prod`
disappears** from the list, yet prod still has 3 ready pods.

**Questions**

1. Why did the generator stop "seeing" the prod cluster?
2. With the default policy, what deleted `podinfo-prod`? Why are the pods still running?
3. In that state, what happens if someone `kubectl edit`s the prod Deployment? Who notices?
4. Which condition would you alert on to catch this within minutes?

<details>
<summary>Explanation and fix</summary>

The clusters generator selects `code-clinic.io/env In [dev, staging, prod]`; `prd` isn't in
the list, so the generator produces two elements instead of three.

With `applicationsSync: sync` (the default), the ApplicationSet deletes Applications that are
no longer generated. The pods survived only because `preserveResourcesOnDeletion: true` is
still set; without it, the Application's finalizer would have **deleted every resource in
prod**. Even with it, prod is now *unmanaged*: no sync, no drift detection, invisible in Argo
CD. Nobody notices a `kubectl edit` until something breaks.

With `create-update` (this repo, [ADR 0004](adr/0004-never-delete-automatically.md)) the
Application is kept, and the ApplicationSet tells you something is off: `InvalidRolloutConfig`
(step 3 has no Applications). Alert on that condition, and on `ErrorOccurred`.
</details>

## Drill 2: A broken image tag in the base

**Scenario.** A "simple version bump" with a tag that doesn't exist, for every environment:

```bash
sed -i 's/^replicaCount: 1$/replicaCount: 1\nimage:\n  tag: 0.0.0-does-not-exist/' apps/podinfo/base/values.yaml
git commit -qam "feat: bump podinfo" && push
sleep 180; apps
kubectl -n podinfo get pods                                   # dev
kubectl -n argocd get applicationset podinfo -o jsonpath='{range .status.applicationStatus[*]}{.application} step={.step} {.status}: {.message}{"\n"}{end}'
for e in staging prod; do kubectl --kubeconfig .e2e/$e.kubeconfig -n podinfo get deploy podinfo -o jsonpath="$e {.spec.template.spec.containers[0].image}{\"\n\"}"; done
```

Then fix it: `git revert --no-edit HEAD && push`.

**What to observe.** `podinfo-dev` is Synced but **Progressing** (its new pod is in
`ImagePullBackOff`; the old pod keeps serving). `podinfo-staging` and `podinfo-prod` are
**OutOfSync** and the ApplicationSet says `step=2 Waiting` / `step=3 Waiting: Application has
pending changes`. Staging and prod still run `ghcr.io/stefanprodan/podinfo:6.17.0`. After the
revert, all three converge again, dev first.

**Questions**

1. Why did the change stop at dev?
2. Why is dev still answering requests even though the new pod can't start?
3. If this repo didn't use RollingSync, what would prod look like now?
4. What would NOT be stopped by this gate? Give an example.

<details>
<summary>Explanation and fix</summary>

RollingSync syncs step 2 (staging) only when every step-1 Application is Healthy. The dev
Deployment can't finish its rollout, so its health is Progressing (and Degraded after the
progress deadline): the rollout halts and staging/prod just wait
([ADR 0003](adr/0003-progressive-rollout-with-rollingsync.md)).

Dev keeps serving because a Deployment's rolling update only removes old pods once new ones are
ready; with a broken image, it never gets there. Without RollingSync, all three clusters sync at
once: prod would be in the same state as dev (still serving from old pods if lucky; down if
pods were rescheduled, e.g. by a node drain, and the image can't be pulled).

The gate only knows "healthy". A change that keeps pods healthy but is wrong (a wrong feature
flag, a slower query, a wrong color) goes straight to prod. That's what soak times, metrics
analysis (Argo Rollouts) or a manual promotion step are for. Fix: revert, as above; the revert
rolls out in order too.
</details>

## Drill 3: A kind the project doesn't allow

**Scenario.** A developer adds a ConfigMap to prod only:

```bash
cat > apps/podinfo/overlays/prod/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: podinfo-extra, namespace: podinfo}
data: {feature: "on"}
EOF
sed -i 's/^  - pdb.yaml$/  - pdb.yaml\n  - configmap.yaml/' apps/podinfo/overlays/prod/kustomization.yaml
git add -A && git commit -qm "feat: extra config in prod" && push
sleep 150; apps
kubectl -n argocd get application podinfo-prod -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}'
kubectl --kubeconfig .e2e/prod.kubeconfig -n podinfo get configmap podinfo-extra
```

Revert with `git revert --no-edit HEAD && push`. Also run `make test` on your laptop with the
same change: what fails?

**What to observe.** dev and staging are unaffected (their manifests didn't change).
`podinfo-prod` is **OutOfSync**, and the operation is stuck `Running: one or more
synchronization tasks are not valid: resource :ConfigMap is not permitted in project podinfo.
Retrying attempt #3`. The ConfigMap does not exist in prod. Locally, `make test` fails two
tests: `test_every_rendered_kind_is_allowed_by_the_appproject[prod]` with `ConfigMap (core) not
whitelisted`, and `test_kinds_per_environment` (prod's list of kinds changed).

**Questions**

1. Which object refused the change, and on what basis?
2. Why is it good that this failed in prod's sync instead of being silently skipped?
3. Why did the static test catch it before any cluster did, and why does that matter?
4. What is the right fix if the ConfigMap is legitimate?

<details>
<summary>Explanation and fix</summary>

The AppProject `podinfo` only allows Deployment, Service, PodDisruptionBudget and
HorizontalPodAutoscaler (`namespaceResourceWhitelist`). Argo CD validates every resource of a
sync against the project before applying anything, so the whole sync fails; nothing partial
is applied, and the retry loop keeps the error visible.

Failing loudly is the point of an allow-list: a kind nobody reviewed (a ServiceAccount with a
RoleBinding, a CronJob...) can't slip in. The static test compares every rendered kind with
the project's whitelist, so the mistake shows up in CI on the pull request instead of as a
stuck prod sync after merge: same rule, an hour and an incident earlier.

If the ConfigMap is legitimate: add `{group: "", kind: ConfigMap}` to the whitelist **in the
same PR**, so the project change is reviewed together with the reason for it.
</details>
