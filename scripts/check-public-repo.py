#!/usr/bin/env python3
"""Check public Git candidates without printing private matches or executing .env."""

import argparse
import pathlib
import re
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def private_path(name):
    path = pathlib.PurePosixPath(name)
    return any(
        part in {".env", ".notes", ".serena", "credentials.txt"}
        or part.startswith(".env.")
        for part in path.parts
    ) or name.endswith((".iso", ".AppImage", ".log")) or name.startswith(
        ("iso/input/", "iso/output/", "iso/work/", "iso/cache/", "iso/airootfs/")
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true")
    args = parser.parse_args()
    try:
        config = (ROOT / ".env").read_text()
        entries = re.findall(r"^PRIVATE_TERMS=(.*)$", config, re.MULTILINE)
        values = shlex.split(entries[-1], comments=True) if entries else []
        terms = [term.strip().lower().encode() for term in values[0].split("|")]
        if len(values) != 1 or not all(terms):
            raise ValueError
    except (OSError, ValueError, IndexError):
        print("FAIL: set a nonempty, single-line PRIVATE_TERMS value in local .env")
        return 1

    secret = re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
        rb"|\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"
        rb"|\bAKIA[A-Z0-9]{16}\b"
        rb"|https://(?:discord\.com|discordapp\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+"
    )
    failures = set()

    def check(scope, name, data):
        if private_path(name):
            failures.add((scope, "private file or artifact"))
        content = name.encode().lower() + b"\n" + data.lower()
        if any(term in content for term in terms):
            failures.add((scope, "private identifier"))
        if secret.search(data):
            failures.add((scope, "credential pattern"))

    # Check the index separately: staged content may differ from the working tree.
    tracked = git("ls-files", "-z").decode().split("\0")
    for name in filter(None, tracked):
        check("index:" + name, name, git("show", ":" + name))
    candidates = git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
    for name in sorted(set(filter(None, candidates.decode().split("\0")))):
        path = ROOT / name
        if path.is_symlink():
            check("worktree:" + name, name, str(path.readlink()).encode())
        elif path.is_file():
            check("worktree:" + name, name, path.read_bytes())

    if args.history:
        seen = set()
        for commit in git("rev-list", "--all").decode().splitlines():
            for entry in git("ls-tree", "-rz", commit).split(b"\0"):
                if not entry:
                    continue
                metadata, name = entry.split(b"\t", 1)
                _, kind, object_id = metadata.split()
                if kind != b"blob" or (object_id, name) in seen:
                    continue
                seen.add((object_id, name))
                decoded = name.decode()
                check("history:" + commit[:12] + ":" + decoded, decoded,
                      git("cat-file", "blob", object_id.decode()))

    for scope, reason in sorted(failures):
        # Redact filenames as well when a filename itself contains a private term.
        for term in terms:
            scope = re.sub(re.escape(term.decode()), "[redacted]", scope, flags=re.I)
        print(f"FAIL: {scope}: {reason}")
    if failures:
        return 1
    print("PASS: public file candidates and index" + (" and reachable history" if args.history else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
