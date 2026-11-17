# Versions used by the e2e test (sourced by run.sh). Renovate bumps them via the comments.
# shellcheck shell=bash disable=SC2034

# Not bumped by Renovate: the image and its digest come as a pair from the kind release notes
# (https://github.com/kubernetes-sigs/kind/releases). Bump them together with kind.
KIND_NODE_IMAGE="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
# renovate: datasource=helm registryUrl=https://argoproj.github.io/argo-helm depName=argo-cd
ARGOCD_CHART_VERSION="10.18.0"
# renovate: datasource=github-releases depName=kubernetes-sigs/metrics-server
METRICS_SERVER_VERSION="v0.9.1"
METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# renovate: datasource=docker depName=alpine
GIT_IMAGE="alpine:3.24.4"
