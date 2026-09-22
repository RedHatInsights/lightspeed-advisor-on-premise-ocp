#!/usr/bin/env python3
"""Helpers for scripts/update_rpm_lockfile.sh.

The shell script orchestrates the lockfile update. This module contains the
Python-only parsing and text transformation logic used during that process.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tarfile
from pathlib import Path

UBI_REPO_PATH = "etc/yum.repos.d/ubi.repo"
UBI_REPO_WHITEOUT_PATH = "etc/yum.repos.d/.wh.ubi.repo"
YUM_REPOS_OPAQUE_WHITEOUT_PATH = "etc/yum.repos.d/.wh..wh..opq"


def normalize_tar_name(name: str) -> str:
    """Normalize tar member names for matching image filesystem paths."""
    return name.lstrip("./")


def rhel_repo_id(repo_id: str, arch: str = "x86_64") -> str:
    """Translate public UBI repo IDs to their RHEL lockfile equivalents."""
    match = re.fullmatch(
        r"ubi-(?P<version>\d+)-(?P<repo>baseos|appstream)"
        r"(?P<kind>-debug|-source)?-rpms",
        repo_id,
    )
    if match:
        kind = match.group("kind") or ""
        return (
            f"rhel-{match.group('version')}-for-{arch}-{match.group('repo')}{kind}-rpms"
        )

    match = re.fullmatch(
        r"ubi-(?P<version>\d+)-codeready-builder"
        r"(?P<kind>-debug|-source)?-rpms",
        repo_id,
    )
    if match:
        kind = match.group("kind") or ""
        return f"codeready-builder-for-rhel-{match.group('version')}-{arch}{kind}-rpms"

    return repo_id


def rewrite_repo_ids(repo_contents: bytes) -> str:
    """Rewrite UBI repo section IDs to RHEL section IDs."""
    repo_text = repo_contents.decode()
    return re.sub(
        r"^\[(?P<repo_id>[^]]+)]$",
        lambda match: f"[{rhel_repo_id(match.group('repo_id'))}]",
        repo_text,
        flags=re.MULTILINE,
    )


def iter_manifest_layers(image_dir: Path) -> list[tuple[str, Path]]:
    """Return (digest, tar path) pairs from a skopeo dir: image copy."""
    with (image_dir / "manifest.json").open() as manifest_file:
        manifest = json.load(manifest_file)

    layers = []
    for layer in manifest["layers"]:
        digest = layer["digest"].split(":", 1)[1]
        layers.append((digest, image_dir / digest))
    return layers


def read_ubi_repo_from_layer(layer_path: Path) -> tuple[bool, bool, bytes | None]:
    """Read ubi.repo state changes from one image layer.

    Returns a tuple of:
      * whether /etc/yum.repos.d was marked opaque
      * whether ubi.repo was whiteouted
      * the layer's ubi.repo content, if present

    Whiteouts are interpreted by the caller in layer order to model the merged
    image filesystem.
    """
    repo_contents = None
    repo_whiteouted = False
    yum_repos_opaque = False

    with tarfile.open(layer_path) as tf:
        members_by_name = {normalize_tar_name(member.name): member for member in tf}

        yum_repos_opaque = YUM_REPOS_OPAQUE_WHITEOUT_PATH in members_by_name
        repo_whiteouted = UBI_REPO_WHITEOUT_PATH in members_by_name

        repo_member = members_by_name.get(UBI_REPO_PATH)
        if repo_member is not None:
            repo_file = tf.extractfile(repo_member)
            if repo_file is not None:
                repo_contents = repo_file.read()

    return yum_repos_opaque, repo_whiteouted, repo_contents


def extract_repo(image_dir: Path, out: Path) -> None:
    """Extract and rewrite ubi.repo from an image copied with skopeo dir:."""
    repo_contents = None
    repo_layer = None

    for digest, layer_path in iter_manifest_layers(image_dir):
        try:
            yum_repos_opaque, repo_whiteouted, layer_repo_contents = (
                read_ubi_repo_from_layer(layer_path)
            )
        except tarfile.TarError:
            continue

        if yum_repos_opaque or repo_whiteouted:
            repo_contents = None
            repo_layer = None

        if layer_repo_contents is not None:
            repo_contents = layer_repo_contents
            repo_layer = digest

    if repo_contents is None:
        sys.exit("Error: could not find /etc/yum.repos.d/ubi.repo in base image layers")

    out.write_text(rewrite_repo_ids(repo_contents))
    print(f"Extracted ubi.repo from layer {repo_layer[:12]} as redhat.repo")


def rewrite_lockfile(path: Path) -> None:
    """Rewrite UBI download URLs in the lockfile to RHEL CDN URLs."""
    text = path.read_text()
    text = re.sub(
        r"https://cdn-ubi\.redhat\.com/content/public/ubi/dist/ubi(?P<version>\d+)/"
        r"(?P<releasever>[^/]+)/(?P<arch>[^/]+)/"
        r"(?P<repo>baseos|appstream|codeready-builder)/",
        r"https://cdn.redhat.com/content/dist/rhel\g<version>/"
        r"\g<releasever>/\g<arch>/\g<repo>/",
        text,
    )
    path.write_text(text)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract_parser = subparsers.add_parser(
        "extract-repo",
        help="extract /etc/yum.repos.d/ubi.repo from a skopeo dir: image copy",
    )
    extract_parser.add_argument("image_dir", type=Path)
    extract_parser.add_argument("output_file", type=Path)

    rewrite_parser = subparsers.add_parser(
        "rewrite-lockfile",
        help="rewrite UBI CDN URLs in rpms.lock.yaml to RHEL CDN URLs",
    )
    rewrite_parser.add_argument("lockfile", type=Path)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "extract-repo":
        extract_repo(args.image_dir, args.output_file)
    elif args.command == "rewrite-lockfile":
        rewrite_lockfile(args.lockfile)
    else:
        raise AssertionError(f"Unhandled command: {args.command}")


if __name__ == "__main__":
    main()
