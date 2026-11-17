"""What each environment gets, and the rules every environment must follow."""

from __future__ import annotations

import re
from typing import Any

import pytest
from conftest import ENVS, by_kind, load, one, render

IMAGE = re.compile(r"^[\w.\-/]+:(\d+\.\d+\.\d+)(@sha256:[0-9a-f]{64})?$")


def containers(env: str) -> list[dict[str, Any]]:
    pod = one(render(env), "Deployment")["spec"]["template"]["spec"]
    return list(pod["containers"])


def test_there_are_exactly_three_environments() -> None:
    assert ENVS == ["dev", "prod", "staging"]


def test_kinds_per_environment() -> None:
    kinds = {env: sorted(d["kind"] for d in render(env)) for env in ENVS}
    assert kinds == {
        "dev": ["Deployment", "Service"],
        "staging": ["Deployment", "PodDisruptionBudget", "Service"],
        "prod": ["Deployment", "HorizontalPodAutoscaler", "PodDisruptionBudget", "Service"],
    }


def test_no_helm_test_pods_leak_into_the_manifests(env: str) -> None:
    # Without `skipTests: true` the chart's `helm test` Pods would be deployed everywhere.
    assert by_kind(render(env), "Pod") == []


def test_everything_lands_in_the_podinfo_namespace(env: str) -> None:
    assert {d["metadata"].get("namespace") for d in render(env)} == {"podinfo"}


def test_every_object_is_labelled_with_its_environment(env: str) -> None:
    for doc in render(env):
        assert doc["metadata"]["labels"]["code-clinic.io/env"] == env, doc["kind"]


def test_the_banner_names_the_environment(env: str) -> None:
    (container,) = containers(env)
    variables = {e["name"]: e.get("value") for e in container["env"]}
    assert variables["PODINFO_UI_MESSAGE"] == env


def test_same_pinned_image_in_every_environment() -> None:
    # Promotion moves ONE artifact through the environments; a different tag per overlay is
    # how "it worked in staging" stops meaning anything.
    images = {env: containers(env)[0]["image"] for env in ENVS}
    assert len(set(images.values())) == 1, images
    (image,) = set(images.values())
    assert IMAGE.match(str(image)), f"image must be pinned to a version, got {image}"


def test_restricted_pod_security(env: str) -> None:
    pod = one(render(env), "Deployment")["spec"]["template"]["spec"]
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    for c in pod["containers"]:
        sc = c["securityContext"]
        assert sc["allowPrivilegeEscalation"] is False
        assert sc["capabilities"]["drop"] == ["ALL"]
        assert sc["readOnlyRootFilesystem"] is True


def test_requests_and_memory_limits(env: str) -> None:
    for c in containers(env):
        resources = c["resources"]
        assert resources["requests"]["cpu"]
        assert resources["requests"]["memory"]
        assert resources["limits"]["memory"]


@pytest.mark.parametrize(("env", "replicas"), [("dev", 1), ("staging", 2)])
def test_fixed_replicas_without_hpa(env: str, replicas: int) -> None:
    assert one(render(env), "Deployment")["spec"]["replicas"] == replicas


def test_prod_lets_the_hpa_own_the_replica_count() -> None:
    docs = render("prod")
    # If the Deployment also set replicas, every Argo CD sync would undo the HPA's decision.
    assert "replicas" not in one(docs, "Deployment")["spec"]
    hpa = one(docs, "HorizontalPodAutoscaler")["spec"]
    assert hpa["scaleTargetRef"] == {"apiVersion": "apps/v1", "kind": "Deployment", "name": "podinfo"}
    assert hpa["minReplicas"] >= 3


@pytest.mark.parametrize("env", ["staging", "prod"])
def test_pdb_never_blocks_every_drain(env: str) -> None:
    # minAvailable >= the replica count means NO pod may ever be evicted: node drains (and
    # cluster upgrades) hang forever.
    docs = render(env)
    min_available = one(docs, "PodDisruptionBudget")["spec"]["minAvailable"]
    deployment = one(docs, "Deployment")["spec"]
    floor = deployment.get("replicas") or one(docs, "HorizontalPodAutoscaler")["spec"]["minReplicas"]
    assert 0 < min_available < floor


def test_pdb_selects_the_pods(env: str) -> None:
    docs = render(env)
    for pdb in by_kind(docs, "PodDisruptionBudget"):
        labels = one(docs, "Deployment")["spec"]["template"]["metadata"]["labels"]
        assert pdb["spec"]["selector"]["matchLabels"].items() <= labels.items()


def test_prod_spreads_pods_across_nodes() -> None:
    pod = one(render("prod"), "Deployment")["spec"]["template"]["spec"]
    assert pod["topologySpreadConstraints"][0]["topologyKey"] == "kubernetes.io/hostname"


def test_every_rendered_kind_is_allowed_by_the_appproject(env: str) -> None:
    # A kind missing from the whitelist makes the sync fail in the cluster, not in review.
    project = load("platform/appproject.yaml")["spec"]
    allowed = {(k["group"], k["kind"]) for k in project["namespaceResourceWhitelist"]}
    for doc in render(env):
        group = doc["apiVersion"].rpartition("/")[0]
        assert (group, doc["kind"]) in allowed, f"{doc['kind']} ({group or 'core'}) not whitelisted"
