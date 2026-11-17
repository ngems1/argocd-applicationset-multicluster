#!/usr/bin/env bash
# End-to-end test on three local kind clusters: the real ApplicationSet, the real Argo CD.
#
#   cc-dev      runs Argo CD (the management cluster) AND is registered as the "dev" cluster
#   cc-staging  workload cluster "staging"
#   cc-prod     workload cluster "prod" (with metrics-server, so the HPA works)
#
# Argo CD reads Git from a tiny git daemon inside cc-dev that serves THIS repository's HEAD,
# so nothing has to be pushed to GitHub. What is checked:
#   1. one Application per labelled cluster, each Synced + Healthy, each with its overlay
#   2. progressive sync: a change committed to the base reaches dev, then staging, then prod
#   3. self-heal: a manual `kubectl scale` in dev is reverted
#   4. safety: removing the env label from the prod cluster does NOT delete prod
#
# Usage: tests/e2e/run.sh            (needs docker, kind, kubectl, helm, git, jq)
#        KEEP=1 tests/e2e/run.sh     keep the clusters afterwards (then: tests/e2e/down.sh)
# `make e2e` runs it inside the course dev container image with the Docker socket mounted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=tests/e2e/versions.sh
source "$here/versions.sh"

state="${E2E_STATE:-$repo/.e2e}"
mkdir -p "$state"
CLUSTERS=(dev staging prod)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; exit 1; }
kc() { local c="$1"; shift; kubectl --kubeconfig "$state/$c.kubeconfig" "$@"; }
argo() { kc dev -n argocd "$@"; }

# wait_for <seconds> <description> <command...>: retry until the command succeeds.
wait_for() {
  local timeout="$1" what="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      fail "timed out after ${timeout}s waiting for: $what"
    fi
    sleep 5
  done
  pass "$what ($(( SECONDS - start ))s)"
}

cleanup() {
  [ -n "${pf_pid:-}" ] && kill "$pf_pid" 2>/dev/null || true
  if [ "${KEEP:-0}" != "1" ]; then
    for c in "${CLUSTERS[@]}"; do kind delete cluster --name "cc-$c" >/dev/null 2>&1 || true; done
  fi
}
trap cleanup EXIT

# `make e2e` runs this script in a container that shares the host's Docker daemon (socket
# mount): then the kind API servers are reached over the "kind" Docker network by container
# name. On a plain host, or with docker-in-docker (Codespaces), the daemon doesn't know us as
# a container, and the published localhost ports work instead.
in_container=0
if [ -f /.dockerenv ] && docker inspect "$(hostname)" >/dev/null 2>&1; then
  in_container=1
fi
# The repository may be a bind mount owned by another user: tell git it's fine to read it.
git config --global --add safe.directory "$repo"

log "1/7 kind clusters (Kubernetes ${KIND_NODE_IMAGE%%@*})"
for c in "${CLUSTERS[@]}"; do
  if ! kind get clusters 2>/dev/null | grep -qx "cc-$c"; then
    kind create cluster --name "cc-$c" --image "$KIND_NODE_IMAGE" --wait 120s
  fi
done
if (( in_container )); then
  docker network connect kind "$(hostname)" 2>/dev/null || true
  for c in "${CLUSTERS[@]}"; do kind get kubeconfig --internal --name "cc-$c" > "$state/$c.kubeconfig"; done
else
  for c in "${CLUSTERS[@]}"; do kind get kubeconfig --name "cc-$c" > "$state/$c.kubeconfig"; done
fi
for c in "${CLUSTERS[@]}"; do kc "$c" get nodes -o name >/dev/null; done
pass "3 clusters reachable"

log "2/7 onboard each cluster (namespace + least-privilege ServiceAccount)"
for c in "${CLUSTERS[@]}"; do
  kc "$c" apply -f "$repo/clusters/onboarding.yaml" >/dev/null
done
kc prod apply -f "$METRICS_SERVER_URL" >/dev/null
# kind's kubelets use self-signed certificates.
kc prod -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
wait_for 120 "argocd-manager tokens issued" bash -c "
  for c in ${CLUSTERS[*]}; do
    kubectl --kubeconfig '$state'/\$c.kubeconfig -n argocd-manager get secret argocd-manager-token -o jsonpath='{.data.token}' | grep -q . || exit 1
  done"

log "3/7 Argo CD ${ARGOCD_CHART_VERSION} (chart) on cc-dev"
helm --kubeconfig "$state/dev.kubeconfig" upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace -f "$repo/bootstrap/argocd/values.yaml" --wait --timeout 10m >/dev/null
pass "Argo CD $(argo get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')"

log "4/7 in-cluster git server with this repository's HEAD"
kc dev create namespace git --dry-run=client -o yaml | kc dev apply -f - >/dev/null
kc dev -n git apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: git-server}
spec:
  selector: {matchLabels: {app: git-server}}
  template:
    metadata: {labels: {app: git-server}}
    spec:
      containers:
        - name: git
          image: ${GIT_IMAGE}
          command: ["sh", "-c"]
          # git-daemon is a separate Alpine package (not in the alpine/git image).
          args:
            - apk add --no-cache git git-daemon >/dev/null && mkdir -p /srv/git &&
              git config --global --add safe.directory '*' &&
              exec git daemon --reuseaddr --export-all --enable=receive-pack --base-path=/srv/git /srv/git
          ports: [{containerPort: 9418}]
          # Ready only once the daemon listens, so `rollout status` can't pass on a crashing pod.
          readinessProbe:
            tcpSocket: {port: 9418}
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata: {name: git-server}
spec:
  selector: {app: git-server}
  ports: [{port: 9418, targetPort: 9418}]
EOF
kc dev -n git rollout status deploy/git-server --timeout=180s >/dev/null
gitpod="$(kc dev -n git get pod -l app=git-server -o jsonpath='{.items[0].metadata.name}')"
rm -rf "$state/repo.git" && git clone -q --bare "$repo" "$state/repo.git"
kc dev -n git exec "$gitpod" -- rm -rf /srv/git/repo.git
kc dev -n git cp "$state/repo.git" "$gitpod:/srv/git/repo.git" >/dev/null
GIT_URL="git://git-server.git.svc.cluster.local/repo.git"
pass "serving $(git -C "$repo" rev-parse --short HEAD) at $GIT_URL"

log "5/7 register the clusters and apply the platform manifests"
for c in "${CLUSTERS[@]}"; do
  token="$(kc "$c" -n argocd-manager get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)"
  ca="$(kc "$c" -n argocd-manager get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')"
  # Argo CD runs in cc-dev and reaches every API server by its container name.
  argo apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$c
  labels:
    argocd.argoproj.io/secret-type: cluster
    code-clinic.io/env: $c
type: Opaque
stringData:
  name: cc-$c
  server: https://cc-$c-control-plane:6443
  namespaces: podinfo
  clusterResources: "false"
  config: |
    {"bearerToken": "$token", "tlsClientConfig": {"insecure": false, "caData": "$ca"}}
EOF
done
# Same manifests as production, only the repository URL points at the local git server.
sed "s#https://github.com/ngems1/argocd-applicationset-multicluster.git#$GIT_URL#" \
  "$repo/platform/appproject.yaml" | argo apply -f - >/dev/null
sed "s#https://github.com/ngems1/argocd-applicationset-multicluster.git#$GIT_URL#" \
  "$repo/platform/applicationset.yaml" | argo apply -f - >/dev/null
pass "3 cluster secrets, AppProject and ApplicationSet applied"

app_ok() { # Synced + Healthy
  [ "$(argo get application "podinfo-$1" -o jsonpath='{.status.sync.status}/{.status.health.status}')" = "Synced/Healthy" ]
}
for c in "${CLUSTERS[@]}"; do
  wait_for 600 "podinfo-$c Synced + Healthy" app_ok "$c"
done

log "6/7 every cluster runs its own overlay"
for c in "${CLUSTERS[@]}"; do
  msg="$(kc "$c" -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}')"
  [ "$msg" = "$c" ] || fail "cc-$c runs message '$msg', expected '$c'"
  ready="$(kc "$c" -n podinfo get deploy podinfo -o jsonpath='{.status.readyReplicas}')"
  pass "cc-$c: message=$msg, ready replicas=$ready"
done
[ "$(kc prod -n podinfo get hpa podinfo -o jsonpath='{.spec.minReplicas}')" = "3" ] || fail "prod HPA missing"
wait_for 300 "prod scaled to the HPA minimum (3 ready)" bash -c \
  "[ \"\$(kubectl --kubeconfig '$state/prod.kubeconfig' -n podinfo get deploy podinfo -o jsonpath='{.status.readyReplicas}')\" = 3 ]"
kc dev -n podinfo get pdb podinfo >/dev/null 2>&1 && fail "dev must not have a PDB"
[ "$(kc staging -n podinfo get pdb podinfo -o jsonpath='{.spec.minAvailable}')" = "1" ] || fail "staging PDB"
pass "prod: HPA min 3, staging: PDB minAvailable 1, dev: no PDB"

log "7/7 behaviour: progressive sync, self-heal, safe cluster removal"
# 7a. Commit a change to the BASE (all environments) and push it to the in-cluster git server.
kc dev -n git port-forward svc/git-server 19418:9418 >/dev/null 2>&1 &
pf_pid=$!
sleep 3
work="$state/work" && rm -rf "$work" && git clone -q "$state/repo.git" "$work"
sed -i 's/^  message: .*/  message: "podinfo v2, deployed by Argo CD"/' "$work/apps/podinfo/base/values.yaml"
# The overlays override PODINFO_UI_MESSAGE, so change something every environment sees.
sed -i 's/^logLevel: .*//; s/^replicaCount: 1$/replicaCount: 1\nlogLevel: debug/' "$work/apps/podinfo/base/values.yaml"
git -C "$work" -c user.name=e2e -c user.email=e2e@example.invalid commit -qam "feat: log level debug everywhere"
git -C "$work" push -q git://localhost:19418/repo.git HEAD:main
new_rev="$(git -C "$work" rev-parse HEAD)"
argo annotate applicationset podinfo argocd.argoproj.io/refresh=true --overwrite >/dev/null 2>&1 || true
for c in "${CLUSTERS[@]}"; do argo annotate application "podinfo-$c" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; done

level() { kc "$1" -n podinfo get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null | grep -q -- '--level=debug'; }
at_rev() { [ "$(argo get application "podinfo-$1" -o jsonpath='{.status.sync.revision}')" = "$new_rev" ] && app_ok "$1"; }
order=()
deadline=$((SECONDS + 900))
pending=(dev staging prod)
while ((${#pending[@]})); do
  (( SECONDS > deadline )) && fail "progressive sync did not finish; still pending: ${pending[*]}"
  still=()
  for c in "${pending[@]}"; do
    if at_rev "$c" && level "$c"; then order+=("$c"); pass "$c updated at +$((SECONDS))s"; else still+=("$c"); fi
  done
  pending=("${still[@]}")
  sleep 5
done
[ "${order[*]}" = "dev staging prod" ] || fail "rollout order was '${order[*]}', expected 'dev staging prod'"
pass "RollingSync order: ${order[*]}"

# 7b. Self-heal: a manual change in the cluster is reverted to what Git says.
kc dev -n podinfo scale deploy podinfo --replicas=4 >/dev/null
wait_for 180 "self-heal reverted dev to 1 replica" bash -c \
  "[ \"\$(kubectl --kubeconfig '$state/dev.kubeconfig' -n podinfo get deploy podinfo -o jsonpath='{.spec.replicas}')\" = 1 ]"

# 7c. Safety: the prod cluster loses its label (a typo, a botched migration...).
argo label secret cluster-prod code-clinic.io/env- >/dev/null
sleep 30
argo get application podinfo-prod >/dev/null 2>&1 || fail "podinfo-prod was DELETED when its cluster lost the label"
[ "$(kc prod -n podinfo get deploy podinfo -o jsonpath='{.status.readyReplicas}')" -ge 3 ] || fail "prod lost pods"
pass "label removed: Application podinfo-prod kept, prod still serving (applicationsSync: create-update)"
argo label secret cluster-prod code-clinic.io/env=prod >/dev/null

log "e2e PASSED"
