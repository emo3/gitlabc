#!/usr/bin/env python3
"""Select a Helm chart only after its application release is announced."""

import datetime as dt
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def version(value):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", value or "")
    return tuple(map(int, match.groups())) if match else None


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def source_file(project, path, ref):
    project = urllib.parse.quote(project, safe="")
    path = urllib.parse.quote(path, safe="")
    return fetch(
        f"https://gitlab.com/api/v4/projects/{project}/repository/files/{path}"
        f"/raw?ref={ref}"
    )


def published_announcement(text, target, today):
    if not text or not text.startswith("---\n"):
        return False
    header = text.split("---", 2)[1]
    date = re.search(r"^date:\s*['\"]?(\d{4}-\d{2}-\d{2})", header, re.M)
    if not date or dt.date.fromisoformat(date[1]) > today:
        return False
    if re.search(r"^(draft|unpublished):\s*true\s*$", header, re.M | re.I):
        return False
    title = re.search(r"^title:\s*(.+)$", header, re.M)
    if not title:
        return False
    major, minor, patch = target
    number = f"{major}.{minor}.{patch}" if patch else f"{major}.{minor}"
    return bool(re.search(rf"(?<![\d.]){re.escape(number)}(?![\w.-])", title[1]))


def gitlab_announced(target, today):
    major, minor, patch = target
    if patch:
        text = source_file(
            "gitlab-org/release/patch-release-blogs",
            f"doc/releases/patch-release-gitlab-{major}-{minor}-{patch}-released.md",
            "main",
        )
    else:
        text = source_file(
            "gitlab-org/gitlab",
            f"doc/releases/{major}/gitlab-{major}-{minor}-released/index.md",
            "master",
        )
    return published_announcement(text, target, today)


def runner_announced(target, now):
    tag = "v" + ".".join(map(str, target))
    text = fetch(
        "https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab-runner/releases/" + tag
    )
    if not text:
        return False
    release = json.loads(text)
    if release.get("upcoming_release") or release.get("tag_name") != tag:
        return False
    released_at = release.get("released_at")
    return bool(
        released_at
        and dt.datetime.fromisoformat(released_at.replace("Z", "+00:00")) <= now
    )


def select_chart(rows, product, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    candidates = [
        row for row in rows
        if row.get("name") == f"gitlab/{product}"
        and version(row.get("version")) and version(row.get("app_version"))
    ]
    candidates.sort(
        key=lambda row: (version(row["app_version"]), version(row["version"])),
        reverse=True,
    )
    confirmed = {}
    for row in candidates:
        target = version(row["app_version"])
        if target not in confirmed:
            confirmed[target] = (
                gitlab_announced(target, now.date()) if product == "gitlab"
                else runner_announced(target, now)
            )
        if confirmed[target]:
            return row
    raise ValueError(f"No announced stable {product} release matches an available chart")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("gitlab", "gitlab-runner"):
        raise ValueError("Usage: announced_chart.py gitlab|gitlab-runner")
    row = select_chart(json.load(sys.stdin), sys.argv[1])
    print(row["version"], row["app_version"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f"ERROR: Cannot verify an announced stable chart: {error}")
