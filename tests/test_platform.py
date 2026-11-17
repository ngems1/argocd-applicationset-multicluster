"""The ApplicationSet, the AppProject and the cluster onboarding agree with each other."""

from __future__ import annotations

import re
from pathlib import Path

from conftest import ENVS, ROOT, load, load_all

APPSET = load("platform/applicationset.yaml")
PROJECT = load("platform/appproject.yaml")
REPO = "https://github.com/ngems1/argocd-applicationset-multicluster.git"
ENV_EXPR = '{{ index .metadata.labels "code-clinic.io/env" }}'


def render_template(value: str, env: str, cluster: str) -> str:
    """The two expressions the template uses, evaluated like Argo CD's Go templates would."""
    out = value.replace(ENV_EXPR, env).replace("{{ .name }}", cluster)
    assert "{{" not in out, f"unexpected template expression left in {value!r}"
    return out


def test_go_templates_fail_on_missing_keys() -> None:
    spec = APPSET["spec"]
    assert spec["goTemplate"] is True
    assert spec["goTemplateOptions"] == ["missingkey=error"]


def test_never_deletes_applications_or_their_resources() -> None:
    policy = APPSET["spec"]["syncPolicy"]
    assert policy["applicationsSync"] == "create-update"
    assert policy["preserveResourcesOnDeletion"] is True


def test_selector_covers_exactly_the_overlays() -> None:
    (generator,) = APPSET["spec"]["generators"]
    (expr,) = generator["clusters"]["selector"]["matchExpressions"]
    assert expr["key"] == "code-clinic.io/env"
    assert expr["operator"] == "In"
    assert sorted(expr["values"]) == ENVS


def test_rolling_sync_goes_dev_then_staging_then_prod() -> None:
    strategy = APPSET["spec"]["strategy"]
    assert strategy["type"] == "RollingSync"
    steps = [s["matchExpressions"][0]["values"] for s in strategy["rollingSync"]["steps"]]
    assert steps == [["dev"], ["staging"], ["prod"]]
    assert strategy["rollingSync"]["steps"][-1]["maxUpdate"] == 1


def test_rolling_sync_steps_match_a_label_the_template_sets() -> None:
    labels = APPSET["spec"]["template"]["metadata"]["labels"]
    for step in APPSET["spec"]["strategy"]["rollingSync"]["steps"]:
        for expr in step["matchExpressions"]:
            assert expr["key"] in labels


def test_template_renders_to_an_existing_overlay_for_every_environment() -> None:
    template = APPSET["spec"]["template"]
    for env in ENVS:
        path = render_template(template["spec"]["source"]["path"], env, f"cc-{env}")
        assert (ROOT / path / "kustomization.yaml").is_file(), path
        assert render_template(template["metadata"]["name"], env, "x") == f"podinfo-{env}"
        assert render_template(template["metadata"]["labels"]["env"], env, "x") == env


def test_template_targets_the_project_repository_and_namespace() -> None:
    spec = APPSET["spec"]["template"]["spec"]
    assert spec["project"] == PROJECT["metadata"]["name"] != "default"
    assert spec["source"]["repoURL"] in PROJECT["spec"]["sourceRepos"]
    assert spec["source"]["repoURL"] == REPO
    assert {"name": "*", "namespace": spec["destination"]["namespace"]} in PROJECT["spec"]["destinations"]
    assert spec["syncPolicy"]["automated"] == {"prune": True, "selfHeal": True}


def test_project_is_locked_down() -> None:
    spec = PROJECT["spec"]
    assert spec["sourceRepos"] == [REPO]  # never "*"
    assert spec["clusterResourceWhitelist"] == []  # no cluster-scoped resources
    assert all(d["namespace"] != "*" for d in spec["destinations"])


def test_onboarding_grants_one_namespace_only() -> None:
    docs = load_all("clusters/onboarding.yaml")
    namespace = next(d for d in docs if d["kind"] == "Namespace" and d["metadata"]["name"] == "podinfo")
    assert namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "restricted"
    bindings = [d for d in docs if d["kind"] in ("RoleBinding", "ClusterRoleBinding")]
    assert {b["kind"] for b in bindings} == {"RoleBinding"}, "no cluster-wide grants to Argo CD"
    assert {b["metadata"]["namespace"] for b in bindings} == {"podinfo"}
    assert {b["roleRef"]["name"] for b in bindings} == {"admin", "argocd-manager-read"}
    # The read Role may only read: Argo CD caches every namespaced kind (CRDs included).
    (read,) = [d for d in docs if d["kind"] == "Role"]
    assert read["metadata"]["namespace"] == "podinfo"
    assert all(set(rule["verbs"]) == {"get", "list", "watch"} for rule in read["rules"])


def test_example_cluster_secret_is_namespace_scoped_and_has_no_real_credential() -> None:
    secret = load("clusters/cluster-secret.example.yaml")
    assert secret["metadata"]["labels"]["argocd.argoproj.io/secret-type"] == "cluster"
    assert secret["metadata"]["labels"]["code-clinic.io/env"] in ENVS
    data = secret["stringData"]
    assert data["namespaces"] == "podinfo"
    assert data["clusterResources"] == "false"
    assert "<token of argocd-manager" in data["config"]


def test_argocd_values_enable_what_the_platform_needs() -> None:
    values = load("bootstrap/argocd/values.yaml")
    assert values["configs"]["params"]["applicationsetcontroller.enable.progressive.syncs"] is True
    assert "--enable-helm" in values["configs"]["cm"]["kustomize.buildOptions"]


def test_e2e_uses_the_versions_file() -> None:
    versions = (ROOT / "tests/e2e/versions.sh").read_text(encoding="utf-8")
    chart = re.search(r'ARGOCD_CHART_VERSION="([\d.]+)"', versions)
    assert chart is not None
    readme = (ROOT / "bootstrap/argocd/values.yaml").read_text(encoding="utf-8")
    assert f"--version {chart.group(1)}" in readme, (
        "bootstrap instructions and e2e must install the same chart"
    )
    assert Path(ROOT / "tests/e2e/run.sh").is_file()
