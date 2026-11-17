# LEARN: one application, many clusters, with Argo CD

A guide for juniors. Read it once top to bottom, then keep it open while you run the e2e
test and the drills. Terms in *italics* link to the [course glossary](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md).

## 1. The problem, in plain words

Your company runs the same service in three places: a dev cluster where people try things,
a staging cluster that looks like production, and the production cluster (soon two, in two
regions). Each one needs slightly different settings: one replica in dev, autoscaling in
prod. Today someone runs `kubectl apply` by hand, or copies YAML between three folders. The
copies drift, prod gets a change nobody tested, and nobody can say what is actually running
where.

*[GitOps](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#gitops)* fixes the "what is
running" question: Git describes the desired state, and an agent
(*[Argo CD](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#argo-cd)*) makes every
cluster match it. This project answers the next questions: how to describe **one** app for
**many** clusters without copies, how to roll a change out **in order**, and how to make sure
a typo can't delete production.

## 2. Concepts from zero

### Application, AppProject, ApplicationSet

- An **Application** says "render *this path* of *this repo* at *this revision*, and keep
  *this namespace* of *this cluster* equal to it". One app, one cluster.
- An **AppProject** is the fence around Applications: which repositories, which destinations
  (cluster + namespace), which kinds of resources they may deploy. The built-in `default`
  project allows **everything**.
- An **[ApplicationSet](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#applicationset)**
  is a factory: a **generator** produces a list of parameter sets, and a **template** turns
  each set into an Application.

### The clusters generator

Argo CD stores each cluster it can deploy to as a Secret labelled
`argocd.argoproj.io/secret-type: cluster`. The **clusters generator** produces one parameter
set per such Secret (optionally filtered by labels), with the cluster's `name`, `server` and
`metadata.labels`. Our template reads the `code-clinic.io/env` label:

```yaml
name: 'podinfo-{{ index .metadata.labels "code-clinic.io/env" }}'    # podinfo-prod
path: 'apps/podinfo/overlays/{{ index .metadata.labels "code-clinic.io/env" }}'
destination: { name: "{{ .name }}", namespace: podinfo }
```

Register a cluster with `env=prod` and it gets the prod overlay. No list of clusters in Git
to keep in sync with reality ([ADR 0001](adr/0001-cluster-generator-selected-by-label.md)).

### Kustomize on top of Helm

*[Helm](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#helm)* packages an app as a
chart with values; *[Kustomize](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#kustomize)*
patches plain YAML. Here the **base** asks Kustomize to render the podinfo chart
(`helmCharts:`), and each **overlay** patches the result:

```text
base (chart 6.17.0 + shared values)
 ├─ overlays/dev      replicas 1, banner "dev"
 ├─ overlays/staging  replicas 2, + PodDisruptionBudget
 └─ overlays/prod     no replicas (the HPA decides), + HPA + PDB, spread over nodes
```

Removing `spec.replicas` in prod is the kind of change a chart's values usually can't express,
and a one-line JSON patch can ([ADR 0002](adr/0002-kustomize-overlays-on-a-helm-base.md)).

### Sync, health, drift

- **Synced** means the cluster matches Git; **OutOfSync** means it doesn't (a new commit, or
  someone changed the cluster: *[drift](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#drift)*).
- **Healthy** means the resources work (Deployment available, HPA able to scale...).
- **Automated sync** applies new commits by itself; **self-heal** also reverts drift;
  **prune** deletes resources that were removed from Git.

### RollingSync

Normally every Application syncs as soon as `main` changes, all at once. With
`strategy: RollingSync`, the ApplicationSet controller syncs Applications **in steps** (by a
label on the Application): step 1 (dev) first; step 2 (staging) only when every step-1 app is
Healthy; and so on. To control the order, the controller **takes over syncing**: it sets
`automated.enabled: false` on every generated Application. The consequence the e2e test
proves: drift is **detected** (OutOfSync) but **not reverted** until the next rollout or a
manual sync ([ADR 0003](adr/0003-progressive-rollout-with-rollingsync.md)).

### Namespace-scoped cluster access

Argo CD needs a credential for each cluster. `argocd cluster add` creates one with
**cluster-admin**: whoever controls Argo CD (or merges a malicious manifest) owns the cluster.
Here each workload cluster gets a ServiceAccount with `admin` **in the podinfo namespace only**,
plus read access there, and the cluster secret says `namespaces: podinfo` so Argo CD only
watches that namespace (*[least privilege](https://github.com/ngems1/code-clinic/blob/main/GLOSSARY.md#least-privilege)*).

## 3. The diagram, step by step

Watch [`architecture.svg`](images/architecture.svg) (a 12-second loop):

1. **0-1 s:** a commit lands on `main` (the "+1" badge on Git).
2. **1-2.5 s:** Argo CD notices the new revision; the ApplicationSet lights up. It has already
   generated three Applications, one per cluster secret it selects (`env=dev`, `staging`, `prod`).
3. **3-4 s, step 1:** RollingSync syncs `podinfo-dev` ("Syncing…"), which turns **Healthy**.
4. **5-6.5 s, step 2:** only now `podinfo-staging` syncs and turns Healthy.
5. **7.5-9 s, step 3:** only now `podinfo-prod` syncs (one prod cluster at a time).
6. **9.5-12 s:** "rolled out in order". The footnote is the safety net: a cluster that loses
   its label keeps its Application, and deleting an Application keeps its resources.

## 4. Naive vs production

The naive version is on the `naive` branch (tag `v0.1-naive`).

| Concern | Naive (`v0.1-naive`) | What goes wrong | Production (`v1.0.0`) |
|---|---|---|---|
| Per-environment config | three full copies of `deployment.yaml` | they drift: dev runs `:latest`, staging `6.16.0`, prod `6.15.0`; "tested in staging" means nothing | one chart version in a base, small overlays; a test asserts one pinned image everywhere |
| Which clusters | `list` generator with hard-coded server URLs | a second source of truth; a URL typo deploys nowhere | `clusters` generator selecting labelled cluster secrets |
| Template errors | fasttemplate, unknown keys render as text | a typo becomes a path like `envs/<no value>` | Go templates with `missingkey=error` |
| Deletion | default `applicationsSync` | removing an element (or the ApplicationSet) deletes the prod Application **and everything it deployed** | `create-update` + `preserveResourcesOnDeletion` ([ADR 0004](adr/0004-never-delete-automatically.md)) |
| Rollout order | all clusters sync at once | prod breaks together with dev | RollingSync dev → staging → prod |
| Project | `default` | any repo, any cluster, any namespace, any kind, cluster-scoped included | AppProject `podinfo`: one repo, one namespace, four kinds |
| Cluster credentials | `argocd cluster add` (cluster-admin) | Argo CD compromise = every cluster compromised | namespace-scoped ServiceAccount, namespace-scoped cluster secret |
| Namespace | `default` | everything mixed; no Pod Security | `podinfo` with restricted Pod Security enforced |
| Revision | `HEAD` | which branch is that, on the server? | `main`, explicitly |
| Scaling | fixed `replicas: 3` in prod | an HPA added later fights every sync | no `replicas` in prod, the HPA owns it |
| Availability | no PDB | a node drain can take every pod at once | PDB below the replica floor (tested) |

## 5. Common mistakes

- **Setting `replicas` and an HPA on the same Deployment.** Argo CD resets the count on every
  sync. Remove `replicas` (prod overlay) or use `ignoreDifferences`.
- **A PDB with `minAvailable` equal to the replica count.** No pod can ever be evicted; node
  drains and cluster upgrades hang. The static tests check `minAvailable < floor`.
- **Forgetting `skipTests: true`** when Kustomize inflates a chart: the chart's `helm test`
  Pods get deployed everywhere.
- **Using the `default` project.** It allows everything, including cluster-scoped resources.
- **Giving Argo CD cluster-admin** because `argocd cluster add` does it by default.
- **Thinking RollingSync keeps self-heal.** It doesn't; alert on OutOfSync.
- **Leaving `applicationsSync` at its default.** One label typo deletes prod.
- **Namespace-scoped credentials with only `admin`.** Argo CD also lists kinds `admin` doesn't
  cover (CRDs, CSIStorageCapacity): give it read access to the namespace too, or its cluster
  cache fails with "forbidden". The e2e test found exactly this.

## 6. Try it on your laptop

```bash
make setup
make render && diff rendered/staging.yaml rendered/prod.yaml   # what really differs
make test                                                       # 45 static checks
make e2e-up                                                     # ~10-15 minutes
export KUBECONFIG=.e2e/dev.kubeconfig
kubectl -n argocd get applicationset podinfo -o yaml | yq '.status'
kubectl -n argocd get applications
kubectl -n argocd port-forward svc/argocd-server 8080:443 &      # UI at https://localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Then do the [drills](DRILLS.md), and `make e2e-down` when you're done.

## 7. Build exercises

1. **A second prod region.** Create a fourth kind cluster `cc-prod-2`, onboard it, register it
   with `env=prod` and `code-clinic.io/region=eu-central-1`. Watch RollingSync update the two
   prod clusters one at a time.
   <details><summary>Hint</summary>Copy the cluster-secret block of <code>tests/e2e/run.sh</code>. The Application name must stay unique: add the region to <code>metadata.name</code> in the template, and think about what that rename does to the existing <code>podinfo-prod</code> (ADR 0004).</details>
2. **Pin prod to a release.** Let prod follow a Git tag (`targetRevision: v1.4.0`) while dev and
   staging follow `main`.
   <details><summary>Hint</summary>Put the revision on the cluster secret (an annotation) and read it in the template with a default; or use <code>templatePatch</code>. Which ADR would you supersede?</details>
3. **Health that means something.** Add a readiness gate so "Healthy" includes "answers
   `/readyz`". Then break `/readyz` in dev and confirm staging never syncs.
   <details><summary>Hint</summary>podinfo has <code>/readyz</code> and the chart already sets a readiness probe; break it with an overlay patch on the probe path.</details>
4. **Short-lived credentials.** Replace the long-lived ServiceAccount token with a token from
   `kubectl create token --duration` and a CronJob that refreshes the cluster secret.
   <details><summary>Hint</summary>Better still on EKS: <code>awsAuthConfig</code> with an IAM role. Write down what each option protects against (THREAT-MODEL T2).</details>
5. **ApplicationSet unit test.** Write a pytest that renders the template for a cluster labelled
   `env=qa` and asserts the ApplicationSet does **not** select it.
   <details><summary>Hint</summary>Reuse <code>render_template()</code> from <code>tests/test_platform.py</code> and the selector from the generator.</details>

## 8. 🎯 Interview questions

<details>
<summary>1. When would you use an ApplicationSet instead of App-of-Apps?</summary>

Both create many Applications. App-of-Apps is a parent Application whose manifests are child
Applications (written by hand or templated by Helm). ApplicationSets generate them from data
(clusters, Git directories, pull requests, lists, matrices) and can order syncs (RollingSync).
Use ApplicationSets when the set of Applications follows a pattern (same app × many clusters,
one app per directory, one preview per PR); App-of-Apps when the children are genuinely
different and hand-curated (a platform bootstrap).
</details>

<details>
<summary>2. How do you stop a GitOps tool from deleting production by accident?</summary>

Know every path to deletion: a generator element disappearing (label typo, renamed
ApplicationSet), an Application deleted with the resources finalizer, `prune` on removed
manifests. Close the automatic ones: `applicationsSync: create-update`,
`preserveResourcesOnDeletion: true`, `Prune=false` or `Delete=false` sync options on
stateful resources, and `PruneLast`. Make decommissioning a runbook. Then test it: the e2e
removes the prod label and asserts prod survives.
</details>

<details>
<summary>3. Helm values per environment, or Kustomize overlays? Why not both?</summary>

Values files are simplest when the chart exposes everything you need. Overlays can change
anything in the rendered output (remove `replicas`, add a PDB), but need `--enable-helm` and a
second tool. Combining them (chart inflated in a base, overlays patching) keeps upstream
upgrades cheap and per-environment differences small. The risk is patches silently missing
after a chart upgrade, so render every overlay in CI and test invariants.
</details>

<details>
<summary>4. What does Argo CD need on a workload cluster, at minimum?</summary>

Discovery of the API, and in namespace-scoped mode: list/watch on every namespaced kind in the
managed namespaces (to build its cache) plus write access to the kinds it deploys. No
cluster-scoped permissions if the project allows no cluster-scoped kinds. Credentials should
be short-lived (cloud IAM / workload identity) rather than long-lived tokens.
</details>

<details>
<summary>5. Your RollingSync rollout is stuck at staging. How do you investigate?</summary>

Read the ApplicationSet status: `.status.applicationStatus` gives each Application's step and
state (Waiting, Pending, Progressing, Healthy) with a message. Then look at the staging
Application: health of each resource, events, sync errors (a forbidden kind, a failing hook).
Fix forward with a commit (it rolls out from dev again) or revert. Don't hand-sync prod to
"unblock": that skips the gate RollingSync exists for.
</details>

## 9. ✅ Self-check quiz

1. What decides which overlay a cluster gets?
2. Why doesn't the prod overlay set `spec.replicas`?
3. You delete the ApplicationSet. What happens to the pods in prod?
4. Someone runs `kubectl scale deploy podinfo --replicas=4` in dev. What does Argo CD show, and
   does it change the replica count back by itself? Why?
5. Which AppProject field would make a ClusterRole in an overlay fail to sync?

<details>
<summary>Answers</summary>

1. The `code-clinic.io/env` label on the cluster's secret: the template uses it in the path.
2. The HPA owns the replica count; a fixed value would be re-applied on every sync, fighting
   the HPA.
3. Nothing: `preserveResourcesOnDeletion: true` keeps the resources (and with
   `create-update`, Applications aren't deleted when generators change either).
4. `podinfo-dev` turns OutOfSync. No: RollingSync disables automated sync (and so self-heal) on
   generated Applications; it stays at 4 until the next rollout or a manual sync.
5. `clusterResourceWhitelist: []`: no cluster-scoped kinds are allowed.
</details>

## 10. Further reading

- Argo CD: [ApplicationSet](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/),
  [Cluster generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/),
  [Progressive Syncs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/),
  [Controlling resource modification](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/).
- Argo CD: [Projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/),
  [Declarative clusters](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
  (namespace-scoped mode, `awsAuthConfig`), [Kustomize with Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/#kustomizing-helm-charts).
- Kustomize: [helmCharts](https://kubectl.docs.kubernetes.io/references/kustomize/builtins/#_helmchartinflationgenerator_).
- Kubernetes: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
  [PodDisruptionBudgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/).
- Next in the course: #11 (the Helm chart side: values schema, HPA, PDB), #46 (a full GitOps
  monorepo with promotion), #14 (a reusable chart library).
