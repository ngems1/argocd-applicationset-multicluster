"""Render every overlay once (kustomize build --enable-helm) and load the platform manifests.

These are STATIC tests: no cluster needed, a few seconds. They catch what kubeconform can't:
cross-file mistakes (a kind the AppProject forbids, a PDB that blocks every drain, an
overlay the ApplicationSet never selects). tests/e2e/run.sh proves the same on real clusters.
"""

from __future__ import annotations

import functools
import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
OVERLAYS = ROOT / "apps" / "podinfo" / "overlays"
ENVS = sorted(p.name for p in OVERLAYS.iterdir() if (p / "kustomization.yaml").is_file())

Manifest = dict[str, Any]


@functools.cache
def render(env: str) -> list[Manifest]:
    """The exact manifests Argo CD will apply for one environment."""
    kustomize = shutil.which("kustomize")
    if kustomize is None:
        pytest.fail("kustomize not found: run `make setup` (installs it in .bin/) or use the dev container")
    out = subprocess.run(
        [kustomize, "build", "--enable-helm", str(OVERLAYS / env)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [doc for doc in yaml.safe_load_all(out) if doc]


def by_kind(docs: list[Manifest], kind: str) -> list[Manifest]:
    return [d for d in docs if d["kind"] == kind]


def one(docs: list[Manifest], kind: str) -> Manifest:
    found = by_kind(docs, kind)
    assert len(found) == 1, f"expected exactly one {kind}, found {len(found)}"
    return found[0]


def load(path: str) -> Manifest:
    doc = yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))
    assert isinstance(doc, dict)
    return doc


def load_all(path: str) -> list[Manifest]:
    return [d for d in yaml.safe_load_all((ROOT / path).read_text(encoding="utf-8")) if d]


@pytest.fixture(params=ENVS)
def env(request: pytest.FixtureRequest) -> str:
    return str(request.param)
