#!/usr/bin/env python3
"""Re-sync the pins in nix/source.nix that are copied from upstream's lockfiles.

    scripts/sync-upstream-pins.py <unpacked upstream source>

Called by scripts/update-hashes.sh once the upstream source hash is correct.
It rewrites, in place:

  * `commit`            -> the commit the `v<version>` tag points at (git ls-remote)
  * `pnpm.version`      -> `packageManager` in upstream's package.json
  * `celPython`         -> version + py3-none-any wheel sha256 from uv.lock
  * `pythonPins.<name>` -> version + sdist sha256 from uv.lock

It only updates pins that already exist; deciding *which* Python packages need
pinning stays a human decision. `pnpm.hash` is not touched here: it is a Nix
(SRI) hash of the npm tarball and update-hashes.sh regenerates it by building.
Fails loudly if anything it expects is missing, rather than leaving a stale pin.
"""

import json
import pathlib
import re
import subprocess
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_NIX = ROOT / "nix" / "source.nix"
REPO = "https://github.com/omnigent-ai/omnigent"


def die(msg: str) -> None:
    sys.exit(f"sync-upstream-pins: {msg}")


def sub_once(pattern: str, repl, text: str, what: str) -> str:
    new, n = re.subn(pattern, repl, text, count=1, flags=re.DOTALL | re.MULTILINE)
    if n != 1:
        die(f"could not find {what} in {SOURCE_NIX.name}")
    return new


def tag_commit(tag: str) -> str:
    out = subprocess.run(
        ["git", "ls-remote", REPO, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    refs = dict(reversed(line.split("\t")) for line in out.splitlines() if line)
    # An annotated tag's own object is not a commit; prefer the peeled ref.
    sha = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    if not sha:
        die(f"tag {tag} not found on {REPO}")
    return sha


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: sync-upstream-pins.py <upstream source dir>")
    src = pathlib.Path(sys.argv[1])
    text = SOURCE_NIX.read_text()

    version = re.search(r'^\s*version\s*=\s*"([^"]+)";', text, re.MULTILINE)
    if not version:
        die("no top-level version")
    tag = f"v{version.group(1)}"

    text = sub_once(
        r'(\bcommit\s*=\s*")[0-9a-f]{40}(")',
        lambda m: m.group(1) + tag_commit(tag) + m.group(2),
        text,
        "commit",
    )

    pm = json.loads((src / "package.json").read_text()).get("packageManager", "")
    m = re.fullmatch(r"pnpm@([0-9][^+]*)(?:\+.*)?", pm)
    if not m:
        die(f"unexpected packageManager {pm!r} in upstream package.json")
    text = sub_once(
        r'(\bpnpm\s*=\s*\{\s*version\s*=\s*")[^"]+(")',
        lambda mm: mm.group(1) + m.group(1) + mm.group(2),
        text,
        "pnpm.version",
    )

    lock = tomllib.loads((src / "uv.lock").read_text())
    pkgs = {p["name"]: p for p in lock.get("package", [])}

    def locked(name: str) -> dict:
        if name not in pkgs:
            die(f"{name} is pinned in source.nix but absent from upstream uv.lock")
        return pkgs[name]

    def hexhash(h: str) -> str:
        if not h.startswith("sha256:"):
            die(f"unexpected hash format {h!r}")
        return h.removeprefix("sha256:")

    cel = locked("cel-python")
    wheel = [w for w in cel.get("wheels", []) if w["url"].endswith("-py3-none-any.whl")]
    if len(wheel) != 1:
        die("expected exactly one py3-none-any wheel for cel-python")
    text = sub_once(
        r'(\bcelPython\s*=\s*\{\s*version\s*=\s*")[^"]+(";.*?wheelSha256\s*=\s*")[0-9a-f]{64}(")',
        lambda mm: (
            mm.group(1)
            + cel["version"]
            + mm.group(2)
            + hexhash(wheel[0]["hash"])
            + mm.group(3)
        ),
        text,
        "celPython",
    )

    block = re.search(r"\bpythonPins\s*=\s*\{(.*)\n  \};", text, re.DOTALL)
    if not block:
        die("no pythonPins block")
    names = re.findall(r"^    ([A-Za-z0-9_-]+)\s*=\s*\{", block.group(1), re.MULTILINE)
    if not names:
        die("pythonPins is empty")
    for name in names:
        p = locked(name)
        if "sdist" not in p:
            die(f"{name} has no sdist in upstream uv.lock")
        text = sub_once(
            rf'(^    {re.escape(name)}\s*=\s*\{{\s*version\s*=\s*")[^"]+(";[^}}]*?sha256\s*=\s*")[0-9a-f]{{64}}(")',
            lambda mm, p=p: (
                mm.group(1)
                + p["version"]
                + mm.group(2)
                + hexhash(p["sdist"]["hash"])
                + mm.group(3)
            ),
            text,
            f"pythonPins.{name}",
        )

    SOURCE_NIX.write_text(text)
    print(
        f"synced commit, pnpm, celPython and pythonPins ({', '.join(names)}) to {tag}"
    )


if __name__ == "__main__":
    main()
