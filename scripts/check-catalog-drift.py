#!/usr/bin/env python3
"""Fail when services.yaml disagrees with the CVHome application repo.

This is the check that would have caught the four services (billing, pod-registry,
content, inventory) that shipped with no infrastructure at all, and the two that were
renamed underneath it (tenancy <- control-plane, console-ui <- seller-ui).

Three independent sources in the app repo, because they can drift from each other too:

  common-config.yml   com.asrevo.cvhome.services.<name>.port      names + ports
  fargate-config.yml  ecs.discovery.service-ports                 names + ports
                      loadbalancer.eager-load.clients             names
  build.gradle        imageName = createImageName("<path>", ...)  image paths
                      imageGroup = "<group>"  (the three UI apps)

Usage:
    check-catalog-drift.py [--app-repo PATH] [--catalog PATH]

Exits 0 when every source agrees, 1 on any drift, 2 if a source could not be read.
Deliberately dependency-free: no yq, no PyYAML — CI should not need a package install
to answer "does the infrastructure know about every service?".
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_APP = REPO.parent / "cvhome"

AUTOCONF = "store-commons/autoconfigure/src/main/resources"
COMMON_CONFIG = f"{AUTOCONF}/common-config.yml"
FARGATE_CONFIG = f"{AUTOCONF}/fargate-config.yml"


class Drift(Exception):
    """A source could not be read at all — distinct from the sources disagreeing."""


# --------------------------------------------------------------------------- catalog


def parse_catalog(path: Path) -> dict[str, dict]:
    """Read services.yaml without a YAML library.

    The catalog's shape is fixed and shallow: two-space layer keys, four-space service
    keys, six-space scalar fields. Anything deeper (edge, extra_env) is ignored here —
    this check is only about names, ports and image paths.
    """
    services: dict[str, dict] = {}
    layer = current = None

    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        line = raw.strip()

        if indent == 0 and line.endswith(":"):
            layer = line[:-1]
            current = None
        elif indent == 2 and line.endswith(":") and layer:
            current = line[:-1]
            services[current] = {"layer": layer}
        elif indent == 4 and current and ":" in line:
            key, _, value = line.partition(":")
            key, value = key.strip(), value.strip()
            # `layer` is owned by the block a service sits in; an entry cannot claim
            # a different one, or an infra service would masquerade as an app service.
            if key != "layer" and value and not value.startswith(("#", "[", "{")):
                services[current][key] = value.strip('"\'')

    if not services:
        raise Drift(f"parsed no services from {path}")
    return services


# ------------------------------------------------------------------------- app repo


def parse_common_config(path: Path) -> dict[str, int]:
    """com.asrevo.cvhome.services.<name>: { port: N } — the authoritative name/port map."""
    text = _read(path)
    block = re.search(r"^      services:\n(.*?)^      [a-z]", text, re.S | re.M)
    if not block:
        raise Drift(f"no `services:` block in {path}")

    ports: dict[str, int] = {}
    name = None
    for raw in block.group(1).splitlines():
        indent = len(raw) - len(raw.lstrip())
        line = raw.strip()
        if indent == 8 and line.endswith(":"):
            name = line[:-1]
        elif indent == 10 and name and line.startswith("port:"):
            ports[name] = int(line.split(":", 1)[1].strip())
    if not ports:
        raise Drift(f"parsed no service ports from {path}")
    return ports


def parse_fargate_config(path: Path) -> tuple[dict[str, int], set[str]]:
    """The discovery service-ports map and the eager-load client list."""
    text = _read(path)

    ports = {
        m.group(1): int(m.group(2))
        for m in re.finditer(r'^\s+"([a-z0-9\-]+)":\s*(\d+)\s*$', text, re.M)
    }
    clients_block = re.search(r"clients:\n((?:\s+-\s+\".*\"\n)+)", text)
    clients = set(re.findall(r'-\s+"([^"]+)"', clients_block.group(1))) if clients_block else set()

    if not ports:
        raise Drift(f"parsed no service-ports from {path}")
    return ports, clients


def parse_image_paths(app: Path) -> set[str]:
    """Every container image the application build publishes.

    Spring services set imageName explicitly; the three UI apps set imageGroup and
    inherit `${imageGroup}/${project.name}` from com.asrevo.docker-conventions.gradle.
    """
    images: set[str] = set()

    for gradle in app.rglob("build.gradle"):
        if "/build/" in str(gradle) or "/bin/" in str(gradle):
            continue
        text = gradle.read_text(errors="replace")

        for m in re.finditer(r'imageName\s*=\s*createImageName\(\s*"([^"]+)"', text):
            images.add(m.group(1))

        m = re.search(r'imageGroup\s*=\s*"([^"]+)"', text)
        if m:
            images.add(f"{m.group(1)}/{gradle.parent.name}")

    if not images:
        raise Drift(f"found no container image definitions under {app}")
    return images


def _read(path: Path) -> str:
    if not path.is_file():
        raise Drift(f"missing: {path}")
    return path.read_text()


# ---------------------------------------------------------------------------- report


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app-repo", type=Path, default=DEFAULT_APP, help="path to the cvhome application repo")
    ap.add_argument("--catalog", type=Path, default=REPO / "services.yaml")
    args = ap.parse_args()

    try:
        catalog = parse_catalog(args.catalog)
        cc_ports = parse_common_config(args.app_repo / COMMON_CONFIG)
        fc_ports, fc_clients = parse_fargate_config(args.app_repo / FARGATE_CONFIG)
        images = parse_image_paths(args.app_repo)
    except Drift as exc:
        print(f"cannot check: {exc}", file=sys.stderr)
        return 2

    app_services = {k: v for k, v in catalog.items() if v["layer"] in ("core", "pod")}
    problems: list[str] = []

    # 1. Every application service has a catalog entry, and vice versa.
    for name in sorted(set(cc_ports) - set(app_services)):
        problems.append(
            f"{name}: in common-config.yml (port {cc_ports[name]}) but MISSING from the catalog "
            f"— it would deploy with no infrastructure and no ECR repository"
        )
    for name in sorted(set(app_services) - set(cc_ports)):
        problems.append(f"{name}: in the catalog but not in common-config.yml — renamed or removed upstream?")

    # 2. Ports agree across all three sources.
    for name, entry in sorted(app_services.items()):
        port = int(entry["port"])
        if name in cc_ports and cc_ports[name] != port:
            problems.append(f"{name}: catalog port {port} != common-config.yml {cc_ports[name]}")
        if name in fc_ports and fc_ports[name] != port:
            problems.append(f"{name}: catalog port {port} != fargate-config.yml {fc_ports[name]}")

    # 3. Every catalog image path is one the application build actually publishes.
    for name, entry in sorted(app_services.items()):
        image = entry.get("image")
        if image and image not in images:
            problems.append(
                f"{name}: image '{image}' is not built by any build.gradle "
                f"— the ECR repository would never receive a push"
            )

    # 4. Discovery clients are declared for every service (a soft but real coupling).
    for name in sorted(set(app_services) - fc_clients):
        problems.append(f"{name}: not in fargate-config.yml eager-load.clients — discovery may not resolve it")

    print(f"catalog: {len(app_services)} services  ({sum(1 for v in app_services.values() if v['layer'] == 'core')} core, "
          f"{sum(1 for v in app_services.values() if v['layer'] == 'pod')} pod)")
    print(f"app repo: {len(cc_ports)} in common-config.yml, {len(images)} images built")

    if problems:
        print(f"\nDRIFT — {len(problems)} problem(s):\n", file=sys.stderr)
        for p in problems:
            print(f"  ✗ {p}", file=sys.stderr)
        print(file=sys.stderr)
        return 1

    print("no drift — catalog agrees with the application on every service, port and image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
