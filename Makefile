# Every target mirrors a CI job: green here = green in CI.
#   make all     lint + test + validate + security + docs   (no cluster needed, ~1 min)
#   make e2e     the real thing: 3 kind clusters + Argo CD   (Docker, ~10-15 min)
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
UV ?= uv
HUB_RAW := https://raw.githubusercontent.com/ngems1/code-clinic/v1
IMAGE := ghcr.io/ngems1/code-clinic-devcontainer:1.1.0
KUBE_VERSIONS := 1.33.0 1.35.0 1.37.0
PATHS := apps/podinfo/overlays/dev apps/podinfo/overlays/staging apps/podinfo/overlays/prod platform clusters
CRDS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
# Run e2e inside the course image, with the host's Docker socket (works on Linux, macOS, Windows).
DOCKER_E2E := docker run --rm --user root -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(CURDIR):/work" -w /work

.PHONY: help setup lint test validate render security docs e2e e2e-up e2e-down ci-local all

help:      ## list targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup:     ## install dev dependencies and git hooks
	$(UV) sync --locked
	pre-commit install
	@command -v kustomize >/dev/null || echo "kustomize missing: use the dev container (image 1.1.0) or install kustomize 5.8.3"

lint:      ## ruff, mypy, shellcheck, actionlint (CI: static, shell, repo)
	$(UV) run ruff check .
	$(UV) run ruff format --check .
	$(UV) run mypy
	shellcheck tests/e2e/*.sh
	actionlint

test:      ## static tests on the rendered overlays + platform manifests (CI: static)
	$(UV) run pytest

validate:  ## kustomize build + kubeconform on every Kubernetes version (CI: kustomize)
	@for dir in $(PATHS); do for k in $(KUBE_VERSIONS); do \
	  kustomize build --enable-helm "$$dir" | kubeconform -strict -summary -kubernetes-version "$$k" \
	    -schema-location default -schema-location '$(CRDS)' | sed "s#^#$$dir@$$k: #"; \
	done; done

render:    ## write what Argo CD will apply to rendered/<env>.yaml
	@mkdir -p rendered
	@for env in dev staging prod; do kustomize build --enable-helm "apps/podinfo/overlays/$$env" > "rendered/$$env.yaml"; done
	@ls rendered

security:  render ## gitleaks (files + history) and trivy config on the rendered manifests (CI: repo, static)
	gitleaks git --redact --no-banner .
	gitleaks dir --redact --no-banner .
	trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 rendered

docs:      ## course self-check: README structure, links, <details>, SVG, encoding (CI: repo)
	@if [ -f ../code-clinic/scripts/check_repo.py ]; then \
	  python3 ../code-clinic/scripts/check_repo.py --profile project; \
	else \
	  tmp="$$(mktemp)"; trap 'rm -f "$$tmp"' EXIT; \
	  curl -fsSL "$(HUB_RAW)/scripts/check_repo.py" -o "$$tmp"; \
	  python3 "$$tmp" --profile project; \
	fi

e2e:       ## 3 kind clusters, Argo CD, ApplicationSet; deleted afterwards (CI: e2e)
	$(DOCKER_E2E) $(IMAGE) bash tests/e2e/run.sh

e2e-up:    ## same as e2e but KEEP the clusters to explore (then: make e2e-down)
	$(DOCKER_E2E) -e KEEP=1 $(IMAGE) bash tests/e2e/run.sh

e2e-down:  ## delete the e2e clusters
	$(DOCKER_E2E) $(IMAGE) bash tests/e2e/down.sh

ci-local:  ## run .github/workflows/ci.yml with act on a clean clone (Docker + ../code-clinic)
	docker run --rm --user root -v /var/run/docker.sock:/var/run/docker.sock \
	  -v act-cache:/cache -v "$(CURDIR):/src:ro" -v "$(CURDIR)/../code-clinic:/hub:ro" \
	  $(IMAGE) bash /hub/tools/act-local.sh

all: lint test validate security docs
