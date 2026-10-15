#!/usr/bin/env python3
"""Audit the stage images of a build for version drift.

For every stage image of a run (in build order) it collects the installed
distributions, where each came from (index, local wheel, git commit) and the
git checkouts under /opt, then reports:
  - pins (--build-sh PACKAGES + --pins) not met by the final image
  - stages where a pinned distribution deviated from its pin (intermediate drift)
  - distributions whose version changed more than once along the chain
  - every version change per stage (downgrades marked)
  - git provenance of the final image and 'uv pip check' conflicts

Usage:
  ./audit.py [--log-dir logs/<run>] [--image IMAGE ...] --build-sh BUILD_SH
                [--pins pins.txt] [--all-changes]

Without --image, the stage images are read from the --tag of logs/<run>/build/*.sh
(default: the newest run). Exits 1 when a pin is not met by the final image.
"""

import argparse
import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_list as P  # noqa: E402

# runs inside each image: installed dists, their origin, and git checkouts under /opt
PROBE = r'''
import json, glob, os, subprocess
import importlib.metadata as md
dists = {}
for d in md.distributions():
    name = d.metadata["Name"]
    if not name:
        continue
    origin = ""
    try:
        du = json.loads(d.read_text("direct_url.json") or "null")
    except Exception:
        du = None
    if du:
        vcs = du.get("vcs_info") or {}
        origin = (vcs.get("commit_id", "")[:12] + " " + du.get("url", "")) if vcs else du.get("url", "")
    dists[name] = [d.version, origin]
repos = {}
for g in glob.glob("/opt/*/.git") + glob.glob("/opt/*/*/.git"):
    top = os.path.dirname(g)
    run = lambda *a: subprocess.run(["git", "-C", top, *a], capture_output=True, text=True).stdout.strip()
    repos[top] = [run("rev-parse", "--short=12", "HEAD"), run("describe", "--tags", "--always"), run("remote", "get-url", "origin")]
try:
    overrides = open(os.environ.get("UV_OVERRIDE") or "/etc/uv/overrides.txt").read().split()
except OSError:
    overrides = []
print(json.dumps({"dists": dists, "repos": repos, "overrides": overrides}))
'''


def stage_images(log_dir):
    """Stage image tags in build order from logs/<run>/build/NNoMM_*.sh."""
    tags = []
    for sh in sorted(
        Path(log_dir, 'build').glob('*.sh'),
        key=lambda p: int(re.match(r'\d+', p.name).group()),
    ):
        m = re.search(r'--tag\s+(\S+)', sh.read_text())
        if m:
            tags.append(m.group(1))
    return tags


def newest_run():
    runs = sorted(d for d in (P.ROOT / 'logs').glob('*/') if list(d.glob('build/*.sh')))
    if not runs:
        sys.exit("no logs/<run>/build/*.sh found; pass --log-dir or --image")
    return runs[-1]


def probe(image):
    """(image, data) or (image, None) when the image is missing or has no python."""
    if subprocess.run(
        ['docker', 'image', 'inspect', image], capture_output=True
    ).returncode:
        return image, None
    r = subprocess.run(
        ['docker', 'run', '--rm', '--entrypoint', 'python3', image, '-c', PROBE],
        capture_output=True,
        text=True,
    )
    try:
        return image, json.loads(r.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return image, None


def short(image):
    """Stage label: the tag without the r39.2.tegra-aarch64-cu132-24.04- style prefix."""
    tag = image.split(':', 1)[-1]
    return re.sub(r'^.*?-\d{2}\.\d{2}-', '', tag)


def vkey(version):
    """Sortable key for a version string (numbers numerically, text after numbers)."""
    return [
        (0, int(x)) if x.isdigit() else (1, x)
        for x in re.findall(r'\d+|[A-Za-z]+', version)
    ]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        '--log-dir',
        help="logs/<run> whose build/*.sh list the stage images (default: newest)",
    )
    parser.add_argument(
        '--image', action='append', help="audit these images instead (in build order)"
    )
    parser.add_argument('--build-sh', required=True, help="build script whose PACKAGES hold the pins")
    parser.add_argument(
        '--pins', help="extra pip pins, one 'name==version' per line (numpy, ...)"
    )
    parser.add_argument(
        '--all-changes',
        action='store_true',
        help="list every version change, not only pinned/flip-flops",
    )
    args = parser.parse_args()

    images = args.image or stage_images(args.log_dir or newest_run())
    pins = P.pip_pins(P.read_packages(args.build_sh), P.read_pip_pins(args.pins))

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(probe, images))
    stages = [(short(img), data) for img, data in results if data]
    final_image = [img for img, data in results if data][-1] if stages else None
    skipped = [short(img) for img, data in results if not data]
    print(
        f"audited {len(stages)} of {len(images)} stage images"
        + (
            f" (skipped, missing or without python: {', '.join(skipped)})"
            if skipped
            else ''
        )
    )
    if not stages:
        sys.exit(1)

    for spec in stages[-1][1].get('overrides', []):  # uv-pin pins of the final image
        m = re.match(r'([A-Za-z0-9_.\-]+)==(\S+)$', spec)
        if m:
            pins.setdefault(P.norm(m.group(1)), m.group(2))
    norm_dists = [
        {P.norm(k): v for k, v in data['dists'].items()} for _, data in stages
    ]
    final_name, final = stages[-1][0], norm_dists[-1]

    # 1. pins against the final image
    failed = []
    print(f"\n== pins in the final image ({final_name})")
    for dist, pin in sorted(pins.items()):
        got = final.get(dist, [None])[0]
        if got is None and dist.startswith('opencv'):
            continue  # one of the two opencv names
        # a pin not installed at all is reported, but only a wrong version fails
        status = (
            'absent' if got is None else 'ok' if P.version_matches(got, pin) else 'FAIL'
        )
        print(f"  {status:6s} {dist:28s} pin {pin:14s} installed {got or '-'}")
        if status == 'FAIL':
            failed.append(dist)

    # 2. intermediate drift of pinned dists, 3. flip-flops, 4. per-stage changes
    history = {}  # dist -> [(stage, old, new)]
    for i in range(1, len(stages)):
        before, after = norm_dists[i - 1], norm_dists[i]
        for dist in sorted(set(before) | set(after)):
            old, new = before.get(dist, [None])[0], after.get(dist, [None])[0]
            if old != new:
                history.setdefault(dist, []).append((stages[i][0], old, new))

    print("\n== pinned distributions off their pin in intermediate stages")
    any_drift = False
    for dist, pin in sorted(pins.items()):
        off = [
            name
            for (name, _), d in zip(stages, norm_dists)
            if dist in d and not P.version_matches(d[dist][0], pin)
        ]
        if off:
            any_drift = True
            versions = sorted(
                {
                    d[dist][0]
                    for d in norm_dists
                    if dist in d and not P.version_matches(d[dist][0], pin)
                }
            )
            print(
                f"  {dist}=={pin}: {', '.join(versions)} in {len(off)} stages ({off[0]} .. {off[-1]})"
            )
    if not any_drift:
        print("  none")

    print("\n== distributions changed more than once (flip-flops)")
    flips = {d: h for d, h in history.items() if sum(1 for _, o, n in h if o and n) > 1}
    for dist, h in sorted(flips.items()):
        print(f"  {dist}: " + ' | '.join(f"{s}: {o}->{n}" for s, o, n in h if o and n))
    if not flips:
        print("  none")

    print(
        "\n== version changes per stage"
        + (
            ""
            if args.all_changes
            else " (pinned or flip-flop only; --all-changes for all)"
        )
    )
    for name, _ in stages[1:]:
        rows = [
            (d, o, n)
            for d, h in history.items()
            for s, o, n in h
            if s == name and o and n and (args.all_changes or d in pins or d in flips)
        ]
        for d, o, n in sorted(rows):
            down = '  DOWNGRADE' if vkey(n) < vkey(o) else ''
            print(f"  [{name}] {d}: {o} -> {n}{down}")

    print(f"\n== provenance in the final image ({final_name})")
    for dist, (ver, origin) in sorted(final.items()):
        if origin:
            print(f"  {dist}=={ver}  {origin}")
    for path, (sha, desc, url) in sorted(stages[-1][1]['repos'].items()):
        print(f"  {path}: {sha} ({desc}) {url}")

    print(f"\n== uv pip check ({final_name})")
    r = subprocess.run(
        ['docker', 'run', '--rm', '--entrypoint', 'uv', final_image, 'pip', 'check'],
        capture_output=True,
        text=True,
    )
    print(
        '  '
        + '\n  '.join(
            line
            for line in (r.stdout + r.stderr).splitlines()
            if line.strip() and 'Using Python' not in line
        )
    )

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
