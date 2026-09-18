#!/usr/bin/env python3
"""Cross-platform correctness gate.

Runs the solver on the reference replay against PINNED card data and scripts,
filters the report down to its platform-invariant lines, and compares them to
the committed reference. Two builds that pass this gate on the same source
commit re-executed the same duel to the same board with the same self-check
results — the cross-platform fingerprint check.

Everything nondeterministic or platform-flavoured (timings, throughput) is
stripped; everything else must match byte for byte.

Usage:
  python tools/ci/gate.py --binary <combosolver[.exe]> --scripts <scriptdir>
      [--assets <dir>] [--write-reference]

The reference replay is extracted from this repository's own history
(etalonB.yrpX at commit c9b9821); cards.cdb comes from BabelCDB at a pinned
commit, cloned into --assets on first use.
"""

import argparse
import pathlib
import re
import subprocess
import sys

REPLAY_REV = "c9b9821"
REPLAY_PATH = "wasm/web/etalonB.yrpX"
BABELCDB_URL = "https://github.com/ProjectIgnis/BabelCDB"
BABELCDB_COMMIT = "47fc046536bff9a39207fabb8541741620237593"

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
REFERENCE = HERE / "reference-invariants.txt"

# Lines whose content is timing/throughput, never correctness.
DROP_LINE = re.compile(r"us/|GHz|/s\b")
DROP_INLINE = re.compile(r"\s*\(\d+ ms\)")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def ensure_assets(assets: pathlib.Path) -> pathlib.Path:
    """Build the gate workdir: exactly one cards.cdb, at the pinned commit."""
    assets.mkdir(parents=True, exist_ok=True)
    babel = assets / "BabelCDB"
    if not babel.exists():
        run(["git", "clone", "--filter=blob:none", BABELCDB_URL, str(babel)])
    if (
        subprocess.run(
            ["git", "-C", str(babel), "cat-file", "-t", BABELCDB_COMMIT],
            capture_output=True,
        ).returncode
        != 0
    ):
        run(["git", "-C", str(babel), "fetch", "origin"])
    workdir = assets / "gate-workdir"
    workdir.mkdir(exist_ok=True)
    cdb = subprocess.run(
        ["git", "-C", str(babel), "show", f"{BABELCDB_COMMIT}:cards.cdb"],
        check=True,
        capture_output=True,
    ).stdout
    (workdir / "cards.cdb").write_bytes(cdb)
    replay = assets / "etalonB.yrpX"
    blob = subprocess.run(
        ["git", "-C", str(REPO), "show", f"{REPLAY_REV}:{REPLAY_PATH}"],
        check=True,
        capture_output=True,
    ).stdout
    replay.write_bytes(blob)
    return workdir


def invariants(report: str) -> str:
    lines = []
    for line in report.replace("\r\n", "\n").split("\n"):
        line = DROP_INLINE.sub("", line.rstrip())
        if DROP_LINE.search(line):
            continue
        lines.append(line)
    return "\n".join(lines).strip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--scripts", required=True)
    ap.add_argument("--assets", default=str(HERE / "assets"))
    ap.add_argument("--write-reference", action="store_true")
    args = ap.parse_args()

    assets = pathlib.Path(args.assets).resolve()
    workdir = ensure_assets(assets)

    proc = subprocess.run(
        [
            str(pathlib.Path(args.binary).resolve()),
            str(assets / "etalonB.yrpX"),
            "--workdir",
            str(workdir),
            "--scriptdir",
            str(pathlib.Path(args.scripts).resolve()),
        ],
        capture_output=True,
        text=True,
    )
    report = proc.stdout + proc.stderr
    print(report)
    if proc.returncode != 0:
        print(f"gate: solver exited {proc.returncode}", file=sys.stderr)
        return 1
    if "MSG_RETRY           : 0" not in report:
        print("gate: MSG_RETRY is not 0 — unfaithful replay", file=sys.stderr)
        return 1
    if "self-checks  : pass" not in report:
        print("gate: self-checks did not pass", file=sys.stderr)
        return 1

    got = invariants(report)
    if args.write_reference:
        with REFERENCE.open("w", newline="\n") as f:
            f.write(got)
        print(f"gate: reference written ({len(got.splitlines())} invariant lines)")
        return 0

    # A Windows checkout may CRLF the reference; compare normalized.
    want = REFERENCE.read_text().replace("\r\n", "\n")
    if got != want:
        import difflib

        sys.stderr.writelines(
            difflib.unified_diff(
                want.splitlines(keepends=True),
                got.splitlines(keepends=True),
                "reference",
                "this build",
            )
        )
        print("gate: INVARIANT MISMATCH — this build diverges from the reference",
              file=sys.stderr)
        return 1
    print(f"gate: PASS — {len(got.splitlines())} invariant lines match the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
