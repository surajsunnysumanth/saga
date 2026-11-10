#!/usr/bin/env python3
"""Check tracked working-tree files; report counts, never matching content.

Owner-specific strings (names, emails, phone numbers, private paths) must not be
committed, so they are supplied through a local identifiers file instead:
``scripts/.private_identifiers`` (gitignored), one literal per line, ``#``
comments, or an explicit ``--identifiers PATH`` argument. When present, any
occurrence in any tracked file fails the check. Without the file the
owner-identifier check is skipped; generic detectors still run.
"""
import collections
import pathlib
import re
import subprocess
import sys


def load_identifiers(explicit):
    """Return (lowercased literals, source description) for the first usable file."""
    candidates = [explicit] if explicit else [pathlib.Path(__file__).with_name(".private_identifiers")]
    for path in candidates:
        if path and path.is_file():
            values = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
            values = [v for v in values if v and not v.startswith("#")]
            if values:
                return [v.lower().encode("utf-8") for v in values], str(path)
            return [], str(path)
    return [], None


def main():
    explicit = None
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--identifiers":
        explicit = pathlib.Path(args[1])
    elif args:
        print("Usage: check_repository.py [--identifiers PATH]", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        print("Repository check requires a Git working tree.", file=sys.stderr)
        return 2
    identifiers, identifier_source = load_identifiers(explicit)
    if identifiers:
        print(f"Owner-identifier check enabled ({len(identifiers)} literal(s) from {identifier_source}); matches count as failures.")
    else:
        print("Owner-identifier check skipped: no identifiers file. Owner-specific values are not in this repository, so they cannot be matched generically.")
    failures = collections.Counter()
    private_key = re.compile(rb"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")
    for name in result.stdout.split(b"\0"):
        if not name:
            continue
        path = pathlib.Path(name.decode("utf-8", errors="surrogateescape"))
        if re.search(r"\.(?:db|sqlite3?)(?:-(?:wal|shm|journal))?$|\.(?:vcf|key|crypt\w*)$|\.ndjson(?:\.gz)?$",
                     path.name, re.IGNORECASE) or path.name == ".env" or path.name.startswith(".env."):
            failures["private-artifact"] += 1
            continue  # Never open a potentially private database, key or archive.
        if path.is_symlink():
            failures["tracked-symlink"] += 1
            continue  # Do not follow links to files outside the checkout.
        try:
            content = path.read_bytes()
        except OSError:
            failures["unreadable-tracked-file"] += 1
            continue
        if private_key.search(content):
            failures["private-key"] += 1
        if (re.search(rb"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})", content)
                or re.search(rb"(?i)(?:crypt15[_-]?key|key)\s*[:=]\s*[\"'][0-9a-f]{64}[\"']", content)):
            failures["credential"] += 1
        if re.search(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/", content):
            failures["home-path"] += 1
        lowered = content.lower()
        if any(value in lowered for value in identifiers):
            failures["owner-identifier"] += 1
    for rule, count in sorted(failures.items()):
        print(f"Repository check: {rule}: {count} file(s)")
    if not failures:
        print("Repository check passed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
