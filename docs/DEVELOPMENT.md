# Development and repository checks

Read [CONTRIBUTING.md](../CONTRIBUTING.md) before editing. Preserve unrelated work, and use synthetic fixtures. Sources and user archives are read-only; never commit private data, keys or machine-specific home paths.

## Local and CI gate

On macOS with Swift 6 (Xcode or Command Line Tools), Git and Python 3:

```bash
scripts/check.sh
```

The script resolves the checkout from its own location and fails on the first
unsuccessful step, without pipelines that could hide an exit code:

1. Check tracked working-tree files for private artifacts, secret patterns and
   hard-coded home paths. Matching values and file contents are never printed.
2. Run synthetic Python script tests with `unittest` (no extra dependencies).
3. Run `swift build -c release`.
4. Run `swift test`.

New files must be staged before the privacy scan includes them. The scan uses
Git's NUL-delimited tracked-file list, so generated, ignored and untracked user
files are not read. It rejects tracked database files (including SQLite sidecars),
contacts, keys, encrypted backups, NDJSON segments and `.env` files **before**
opening them. Symlinks are rejected without following their targets. It also
matches PEM private-key headers, common GitHub/OpenAI/AWS credential formats,
literal 64-hex key assignments, and absolute macOS/Linux user home paths. Use
`~/...`, placeholders or paths resolved at runtime instead of home-directory
literals. There are no per-file exemptions.

This is a conservative regression guard, **not** an exhaustive secret detector,
a history audit or proof that arbitrary message/contact text is absent. Review
staged diffs before committing; don't paste suspect values into logs or reports.

### Owner-identifier check (local only)

Generic detectors cannot know the owner's real name, email, phone numbers or
private paths, and those values must never be committed. Instead, put them in
`scripts/.private_identifiers` (gitignored, one literal per line, `#` comments;
an explicit path can be passed as `check_repository.py --identifiers PATH`).
When the file exists beside the scanner, any case-insensitive occurrence in any
tracked file fails the check with an `owner-identifier` count — matched values
are never printed. The file stays on your machine, so CI (which has no such
file) skips this check while still running every generic detector. Fill in real
phone numbers and any additional names before publishing or exporting a public
snapshot. For a quick scan or script-only test run:

```bash
python3 scripts/check_repository.py
python3 -m unittest discover -s scripts/tests -v
```

## App and parity validation

Before handing off, also run `scripts/make_app.sh` and confirm the resulting
`build/Saga.app` launches. Bundle creation/signing is deliberately separate from
the CI gate. UI changes should include an app launch and visual check using synthetic demo data only.

Performance work additionally requires before/after timings and zero row
differences from `scripts/parity_vault.sh` against scratch indexes. The hygiene gate
never opens the real archive or benchmarks it.

## Legacy code

`Compactor.swift` remains reachable through `saga compact`; it is not dead code.
Keep it and its tests until that legacy CLI is explicitly retired. The modern
vault uses append-only segments and does not require legacy DB compaction.
