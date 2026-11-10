#!/usr/bin/env python3
"""Export an allowlisted public snapshot of this repository (local preparation only).

The snapshot is a fresh directory containing only files that belong in the public
GitHub tree: application sources/tests, packaging and check scripts, the static
site, user/contributor documentation and reviewed GitHub configuration. Internal
worker briefs, task briefs, the launch worksheet, reference-parity tooling and
local verification artifacts are excluded.

This script never publishes anything: it does not create a remote, push, tag or
run a GitHub command. It exports files byte-for-byte from a committed ref, so
uncommitted working-tree changes are deliberately not included.

Usage:
    python3 scripts/make_public_snapshot.py --ref HEAD --out /path/to/new-dir

The output directory must not exist. Inspect the result, run the CI gate inside
it, and only then decide whether to commit it (see docs/LAUNCH.md).
"""
import argparse
import pathlib
import re
import subprocess
import sys

# Files/directories that may appear in the public tree. Everything else is
# excluded, so new internal material does not leak into a snapshot by default.
INCLUDE_PREFIXES = (
    ".github/",
    "Resources/",
    "Sources/",
    "Tests/",
    "docs/",
    "scripts/",
    "site/",
)
INCLUDE_FILES = (
    ".gitignore",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "PRIVACY.md",
    "README.md",
    "SECURITY.md",
    "VERSION",
    "Package.swift",
)
# Internal material that must stay out even though it lives under an included
# prefix. Keep this list in sync with docs/LAUNCH.md.
EXCLUDE_PREFIXES = (
    "docs/tasks/",
    "docs/launch/",
    "docs/WORKER-BRIEF.md",
    "docs/LAUNCH.md",
    # Internal planning notes that name worker cards and unbuilt assets.
    "docs/website-assets.md",
    "docs/website-copy.md",
    "docs/MERGE-DATA.md",
    "docs/CONTACT-SUGGESTIONS.md",
    # Proposed design explorations kept for owner review, not shipped pages.
    "docs/mockups/",
    "scripts/parity.sh",
    "scripts/parity_vault.sh",
    "scripts/.private_identifiers",
    ".launch-doc-verification/",
)
TEXT_SUFFIXES = (".md", ".html", ".htm")
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML_LINK = re.compile(r"(?:href|src)=\"([^\"]+)\"")


def is_public_path(path):
    """True when a repository-relative path belongs in the public snapshot."""
    if path in INCLUDE_FILES:
        return True
    if any(path.startswith(prefix) for prefix in EXCLUDE_PREFIXES):
        return False
    return any(path.startswith(prefix) for prefix in INCLUDE_PREFIXES)


def select_paths(paths):
    """Filter tracked paths to the public allowlist, preserving order."""
    return [p for p in paths if is_public_path(p)]


def _candidate_targets(fragment):
    target = fragment.split("#", 1)[0].split("?", 1)[0].strip()
    return target


def find_broken_links(root):
    """Return repo-relative broken relative links found in Markdown/HTML files.

    Only local files are checked: absolute URLs, mail links and pure anchors are
    ignored, and this is not a substitute for a rendered-site check.
    """
    root = pathlib.Path(root)
    broken = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        pattern = LINK if path.suffix.lower() == ".md" else HTML_LINK
        for match in pattern.finditer(text):
            target = _candidate_targets(match.group(1))
            if not target or target.startswith(("#", "http://", "https://", "mailto:", "tel:", "data:", "//")):
                continue
            if target.startswith("/"):
                broken.append((rel, match.group(1), "root-absolute path"))
                continue
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(root.resolve())
            except ValueError:
                broken.append((rel, match.group(1), "escapes snapshot"))
                continue
            if not resolved.exists():
                broken.append((rel, match.group(1), "missing"))
    return broken


def _git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True)


def export(ref, out):
    out = pathlib.Path(out)
    if out.exists():
        raise SystemExit(f"Refusing to write into existing path: {out}")
    listing = _git("ls-tree", "-r", "-z", "--long", ref).stdout.split(b"\0")
    entries = []
    for row in listing:
        if not row:
            continue
        meta, _, name = row.partition(b"\t")
        mode, kind, _sha, _size = meta.split()
        if kind != b"blob":
            continue
        entries.append((mode.decode(), name.decode("utf-8", "surrogateescape")))
    selected = [(mode, name) for mode, name in entries if is_public_path(name)]
    if not selected:
        raise SystemExit("No files selected; refusing to create an empty snapshot.")
    out.mkdir(parents=True)
    for mode, name in selected:
        content = _git("show", f"{ref}:{name}").stdout
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        if mode == "100755":
            target.chmod(0o755)
    return selected, len(entries) - len(selected)


def main(argv=None):
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--ref", default="HEAD", help="committed ref to export (default: HEAD)")
    parser.add_argument("--out", required=True, help="new directory for the snapshot")
    parser.add_argument("--skip-link-check", action="store_true", help="skip relative-link validation")
    args = parser.parse_args(argv)
    try:
        _git("rev-parse", "--git-dir")
    except subprocess.CalledProcessError:
        print("Run this from inside the Saga Git checkout.", file=sys.stderr)
        return 2
    commit = _git("rev-parse", f"{args.ref}^{{commit}}").stdout.decode().strip()
    selected, excluded = export(args.ref, args.out)
    print(f"Exported {len(selected)} file(s) from {commit} into {args.out}")
    print(f"Excluded {excluded} tracked file(s) that are internal or unreviewed.")
    if not args.skip_link_check:
        broken = find_broken_links(args.out)
        if broken:
            print(f"Broken relative links: {len(broken)}", file=sys.stderr)
            for source, target, reason in broken:
                print(f"  {source}: {target} ({reason})", file=sys.stderr)
            return 1
        print("Relative links resolve within the snapshot.")
    print("Nothing was committed, tagged or pushed. Review the snapshot before publishing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
