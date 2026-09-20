#!/usr/bin/env python3
"""
Registry tag retention for the local Docker registry (registry_stack_registry).

For each repository, keeps only the KEEP most-recently-built unique versions
(grouped by manifest digest, since tags like 'latest' commonly point to the
same digest as a commit-sha tag) and deletes older ones via the registry v2
API, then runs `registry garbage-collect` to actually reclaim blob storage.

Usage:
    registry-retention.py            # dry run, prints what WOULD be pruned
    registry-retention.py --apply    # actually deletes + runs GC

Meant to run as root (for `docker exec`) via /etc/cron.d/registry-retention.
"""
import json
import subprocess
import sys
import urllib.request

REGISTRY_URL = "http://192.168.100.10:10400"
KEEP = 5
REGISTRY_CONTAINER_FILTER = "registry_stack_registry"
LOG_PREFIX = "[registry-retention]"

MANIFEST_ACCEPT = ", ".join([
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.oci.image.index.v1+json",
])


def api_get(path, accept=None):
    req = urllib.request.Request(f"{REGISTRY_URL}{path}")
    if accept:
        req.add_header("Accept", accept)
    return urllib.request.urlopen(req, timeout=20)


def get_catalog():
    with api_get("/v2/_catalog?n=1000") as resp:
        return json.loads(resp.read())["repositories"]


def get_tags(repo):
    with api_get(f"/v2/{repo}/tags/list") as resp:
        return json.loads(resp.read()).get("tags") or []


def get_manifest(repo, ref):
    with api_get(f"/v2/{repo}/manifests/{ref}", accept=MANIFEST_ACCEPT) as resp:
        digest = resp.headers.get("Docker-Content-Digest")
        body = json.loads(resp.read())
    return digest, body


def get_created(repo, manifest_body):
    media_type = manifest_body.get("mediaType", "")
    if "index" in media_type or "manifest.list" in media_type:
        sub = manifest_body["manifests"][0]
        _, manifest_body = get_manifest(repo, sub["digest"])
    config_digest = manifest_body["config"]["digest"]
    with api_get(f"/v2/{repo}/blobs/{config_digest}") as resp:
        config = json.loads(resp.read())
    return config.get("created", "")


def delete_manifest(repo, digest):
    req = urllib.request.Request(f"{REGISTRY_URL}/v2/{repo}/manifests/{digest}", method="DELETE")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status


def get_registry_container():
    out = subprocess.check_output(["docker", "ps", "-q", "--filter", f"name={REGISTRY_CONTAINER_FILTER}"])
    cid = out.decode().split()
    if not cid:
        raise RuntimeError("registry container not found/running")
    return cid[0]


def main():
    apply_changes = "--apply" in sys.argv
    deleted_any = False

    for repo in get_catalog():
        tags = get_tags(repo)
        if not tags:
            continue

        by_digest = {}
        for tag in tags:
            digest, body = get_manifest(repo, tag)
            created = get_created(repo, body)
            entry = by_digest.setdefault(digest, {"tags": [], "created": created})
            entry["tags"].append(tag)

        ranked = sorted(by_digest.items(), key=lambda kv: kv[1]["created"] or "", reverse=True)
        keep, prune = ranked[:KEEP], ranked[KEEP:]

        print(f"{LOG_PREFIX} {repo}: {len(ranked)} unique version(s), "
              f"keeping {len(keep)}, pruning {len(prune)}")
        for digest, info in prune:
            tags_str = ", ".join(info["tags"])
            print(f"{LOG_PREFIX}   prune {repo}@{digest[:19]}... "
                  f"(tags: {tags_str}, created {info['created']})")
            if apply_changes:
                delete_manifest(repo, digest)
                deleted_any = True

    if not apply_changes:
        print(f"{LOG_PREFIX} dry run only, nothing deleted. Pass --apply to actually prune.")
        return

    if deleted_any:
        print(f"{LOG_PREFIX} running garbage-collect to reclaim blob storage...")
        container = get_registry_container()
        subprocess.run(
            ["docker", "exec", container, "registry", "garbage-collect",
             "-m", "/etc/docker/registry/config.yml"],
            check=True,
        )
    else:
        print(f"{LOG_PREFIX} nothing pruned, skipping garbage-collect.")


if __name__ == "__main__":
    main()
