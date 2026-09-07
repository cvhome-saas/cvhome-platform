#!/usr/bin/env python3
"""Refuse a release whose protected environments still deploy `latest`.

    check-release-pins.py [--envs DIR] [--flavours PATH]

Every envs/<env>.tfvars names a flavour from flavours.yaml and the product version the
environment runs (image_tag). A flavour marked `protected: true` (prod) must pin a
released version, X.Y.Z, never `latest`: `latest` is whatever the last branch build
pushed, and a tag of this repository is a statement that the platform at this commit
was validated against one specific product version (cvhome-saas/orchestrator
docs/release-plan.md).

Run by the release-guard job on every vX.Y.Z tag; the same rule is enforced at plan
time by the precondition in main.tf, so this only moves the failure earlier.
"""

import argparse
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent

ASSIGNMENT = re.compile(r'^\s*(?P<key>flavour|image_tag)\s*=\s*"(?P<value>[^"]*)"', re.MULTILINE)
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$")


def read_tfvars(path: Path) -> dict[str, str]:
    """The two string assignments this check cares about. Comments are not parsed:
    a commented-out `# image_tag = ...` starts with `#`, which the anchor rejects."""
    return {m["key"]: m["value"] for m in ASSIGNMENT.finditer(path.read_text())}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--envs", type=Path, default=REPO / "envs")
    ap.add_argument("--flavours", type=Path, default=REPO / "flavours.yaml")
    args = ap.parse_args()

    flavours = yaml.safe_load(args.flavours.read_text())
    files = sorted(args.envs.glob("*.tfvars"))
    if not files:
        print(f"FAIL  no tfvars under {args.envs}", file=sys.stderr)
        return 1

    failures = 0
    for path in files:
        values = read_tfvars(path)
        flavour = values.get("flavour")
        tag = values.get("image_tag")
        protected = bool(flavours.get(flavour, {}).get("protected", False))
        label = f"{path.name:16} flavour={flavour} protected={str(protected).lower():5} image_tag={tag}"

        if flavour not in flavours:
            print(f"FAIL  {label}  (no such flavour in {args.flavours.name})")
            failures += 1
        elif tag is None:
            print(f"FAIL  {label}  (image_tag is not set)")
            failures += 1
        elif protected and not VERSION.match(tag):
            print(f"FAIL  {label}  (a protected flavour must pin a released version X.Y.Z)")
            failures += 1
        else:
            print(f"ok    {label}")

    if failures:
        print(f"\n{failures} environment(s) cannot be released. Promotion is a PR that sets "
              "image_tag in envs/<env>.tfvars to a version from cvhome-saas/orchestrator releases/.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
