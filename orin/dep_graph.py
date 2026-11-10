#!/usr/bin/env python3
"""Dependency graph of a built image: who requires what, and what a bump would move.

Probes the image with 'docker run --rm' (nothing is built or installed):
  - every distribution of the image's environment (uv's, /opt/venv), its
    version and Requires-Dist with markers evaluated inside the image
    (packaging, including extras that dependents request), and the reverse map
    "who requires X with which spec" with satisfied/mismatch per edge
  - 'uv pip check' of the image, compared edge by edge with the mismatches above
  - --focus: per dist, installed version, requirements, dependents with spec
    and satisfied flag, plus uv's own 'uv pip tree' (normal and --invert) view
  - --what-if: 'uv pip compile' against the image's PIP_INDEX_URL, with the
    installed versions as preferences (an existing --output-file), the package
    pins of --packages as constraints, once without and once with the bump;
    the diff is what the bump moves (uv's own 'uv pip tree' has no JSON output
    and 'uv pip show' gives no specifiers, hence the in-image probe)

Usage:
  ./dep_graph.py [--image IMAGE] [--json]                      # whole graph
  ./dep_graph.py --focus numpy,transformers [--json]
  ./dep_graph.py --what-if transformers==5.22.2 [--what-if vllm] [--json]
      (dist without ==version means: the newest the index and pins allow)
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_list as P  # noqa: E402

IMAGE = 'bedrock:r39.2.tegra-aarch64-cu132-24.04'

# runs inside the image (python3 of /opt/venv, which ships packaging)
PROBE = r'''
import json, os, re, subprocess, sys, sysconfig, shutil, tempfile
import importlib.metadata as md
from packaging.requirements import Requirement
from packaging.specifiers import SpecifierSet
from packaging.utils import canonicalize_name as cn
from packaging.version import Version

args = json.loads(sys.argv[1])
site = sysconfig.get_paths()["purelib"]  # the environment uv inspects
dists = {}
for d in md.distributions(path=[site]):
    n = cn(d.metadata["Name"] or "")
    if n and n not in dists:
        dists[n] = d
ver = {n: d.version for n, d in dists.items()}

def origin(d):
    try:
        du = json.loads(d.read_text("direct_url.json") or "null") or {}
    except ValueError:
        du = {}
    return du.get("url", "")

# active requirements: base markers plus the extras dependents request (fixpoint)
extras = {n: set() for n in dists}
parsed = {n: [Requirement(r) for r in (d.requires or [])] for n, d in dists.items()}
def active(n):
    for r in parsed[n]:
        hit = [e for e in [""] + sorted(extras[n]) if not r.marker or r.marker.evaluate({"extra": e})]
        if hit:
            yield r, hit[0]
changed = True
while changed:
    changed = False
    for n in dists:
        for r, _ in active(n):
            t = cn(r.name)
            if t in extras and not r.extras <= extras[t]:
                extras[t] |= r.extras
                changed = True

def sat(spec, v):
    if v is None:
        return "missing"
    return "ok" if SpecifierSet(spec).contains(Version(v), prereleases=True) else "MISMATCH"

out = {"index": os.environ.get("PIP_INDEX_URL", ""), "site": site, "dists": {}, "rdeps": {}}
for n in sorted(dists):
    reqs = []
    for r, e in active(n):
        t = cn(r.name)
        spec = str(r.specifier)
        edge = {"name": t, "spec": spec, "extras": sorted(r.extras), "via_extra": e,
                "installed": ver.get(t), "status": sat(spec, ver.get(t))}
        reqs.append(edge)
        out["rdeps"].setdefault(t, []).append(dict(edge, by=n, by_version=ver[n], name=t))
    out["dists"][n] = {"version": ver[n], "extras_used": sorted(extras[n]),
                       "origin": origin(dists[n]), "requires": reqs}

uv = lambda *a, **k: subprocess.run(["uv", *a], capture_output=True, text=True, **k)
check = uv("pip", "check")
out["uv_pip_check"] = {"rc": check.returncode, "lines": [l for l in (check.stdout + check.stderr).splitlines() if l.startswith("The package")]}
out["uv_tree"] = {f: [uv("pip", "tree", "--show-version-specifiers", "--depth", "1", "--package", f).stdout,
                      uv("pip", "tree", "--show-version-specifiers", "--depth", "1", "--invert", "--package", f).stdout]
                  for f in args.get("focus", [])}

if args.get("whatif"):
    # dists installed from a local file/dir cannot come from the index: their requirements stand in
    local = {n for n in dists if out["dists"][n]["origin"].startswith("file:")}
    def spec_of(n):
        return n + ("[" + ",".join(sorted(extras[n])) + "]" if extras[n] else "")
    # conflicts uv pip check already reports are accepted in the image (installed --no-deps):
    # override the depended-on dist to its installed version so the baseline resolves like the image
    accepted = {cn(m.group(2)) for l in out["uv_pip_check"]["lines"]
                for m in [re.match(r"The package `([^`]+)` requires `([A-Za-z0-9_.\-]+)", l)] if m}
    out["whatif"] = []
    for w in args["whatif"]:
        t = cn(re.split(r"[=<>!~ \[]", w)[0])
        tmp = tempfile.mkdtemp()
        def f(name, lines):
            p = os.path.join(tmp, name)
            open(p, "w").write("\n".join(lines) + "\n")
            return p
        base_req = [spec_of(n) for n in dists if n not in local] + \
                   [str(r) for n in local for r, _ in active(n) if cn(r.name) not in local]
        cons = f("constraints.txt", [f"{n}{s}" for n, s in args["pins"].items() if n != t])
        ovr = f("overrides.txt", [f"{n}=={ver[n]}" for n in sorted(accepted) if n in ver and n != t])
        prefs = [f"{n}=={ver[n]}" for n in dists if n not in local]
        res = {"request": w, "dist": t, "constraints": open(cons).read().split(),
               "overrides": open(ovr).read().split(), "local_not_resolved": sorted(local)}
        for label, req, extra in (("baseline", base_req, []),
                                  ("bump", [r for r in base_req if cn(re.split(r"[=<>!~ \[;]", r)[0]) != t] + [w], ["-P", t])):
            o = f(label + ".txt", prefs)
            r = uv("pip", "compile", f(label + ".in", req), "-o", o, "-c", cons, "--overrides", ovr,
                   "--python-version", "3.12", "--python-platform", "aarch64-manylinux_2_39",
                   "--default-index", out["index"], "--no-header", "--no-annotate", "--quiet", *extra,
                   timeout=900)
            pins = {}
            if r.returncode == 0:
                for l in open(o).read().splitlines():
                    m = re.match(r"([A-Za-z0-9_.\-]+)(?:\[[^\]]*\])?==(\S+)", l)
                    if m:
                        pins[cn(m.group(1))] = m.group(2)
            res[label] = {"ok": r.returncode == 0, "pins": pins,
                          "error": "" if r.returncode == 0 else (r.stderr.strip()[-4000:])}
        shutil.rmtree(tmp)
        out["whatif"].append(res)
print(json.dumps(out))
'''


def constraint(pin):
    """PACKAGES pin -> specifier: 2.12 -> ==2.12.* (release prefix), 0.31.0 -> ==0.31.0."""
    return f"=={pin}.*" if re.fullmatch(r'\d+(\.\d+)?', pin) else f"=={pin}"


def probe(image, focus, whatif, pins):
    arg = json.dumps({'focus': focus, 'whatif': whatif, 'pins': pins})
    net = ['--network', 'host'] if whatif else []  # devpi on the host's localhost
    r = subprocess.run(
        ['docker', 'run', '--rm', *net, '--entrypoint', 'python3', image, '-c', PROBE, arg],
        capture_output=True, text=True,
    )
    if r.returncode:
        sys.exit(f"probe of {image} failed:\n{r.stderr[-3000:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def validate(data):
    """Compare our mismatch/missing edges with 'uv pip check' lines (by, dist) pairs."""
    uv = set()
    for line in data['uv_pip_check']['lines']:
        m = re.match(r"The package `([^`]+)` requires `([A-Za-z0-9_.\-]+)", line)
        if m:
            uv.add((P.norm(m.group(1)), P.norm(m.group(2))))
    ours = {
        (e['by'], name)
        for name, edges in data['rdeps'].items()
        for e in edges
        if e['status'] != 'ok'
    }
    return {'agree': uv == ours, 'only_uv': sorted(uv - ours), 'only_dep_graph': sorted(ours - uv)}


def diff(a, b):
    """{dist: [old, new]} for dists whose version differs (None = absent)."""
    return {n: [a.get(n), b.get(n)] for n in sorted(set(a) | set(b)) if a.get(n) != b.get(n)}


def edge(e, who):
    flag = '' if e['status'] == 'ok' else f"  <-- {e['status']}"
    x = f"[{','.join(e['extras'])}]" if e['extras'] else ''
    via = f" (extra {e['via_extra']})" if e['via_extra'] else ''
    return f"    {who}{x} {e['spec'] or '*'}{via}  installed {e['installed']}{flag}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--image', default=IMAGE)
    ap.add_argument('--focus', default='', help='dist[,dist...]')
    ap.add_argument('--what-if', action='append', default=[], metavar='DIST[==VERSION]')
    ap.add_argument('--packages', default=str(P.HERE / 'packages.txt'), help='package list whose pins are constraints')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()

    pins = {}
    for d, v in P.pip_pins(P.read_packages(a.packages)).items():
        pins[P.norm(d)] = constraint(v)
    focus = [P.norm(f) for f in a.focus.split(',') if f]
    data = probe(a.image, focus, a.what_if, pins)
    data['image'] = a.image
    data['validation'] = validate(data)
    installed = {n: d['version'] for n, d in data['dists'].items()}
    for w in data.get('whatif', []):
        b, u = w['baseline'], w['bump']
        w['resolves'] = u['ok']
        w['target_version'] = u['pins'].get(w['dist'])
        w['baseline_vs_installed'] = diff(installed, b['pins']) if b['ok'] else None
        w['moved_by_bump'] = diff(b['pins'], u['pins']) if b['ok'] and u['ok'] else None
        w['bump_vs_installed'] = diff(installed, u['pins']) if u['ok'] else None

    if focus:
        data['focus'] = {
            f: {'version': installed.get(f),
                'requires': data['dists'].get(f, {}).get('requires', []),
                'required_by': data['rdeps'].get(f, []),
                'mismatches': [e for e in data['rdeps'].get(f, []) if e['status'] != 'ok']}
            for f in focus
        }
    if a.json:
        print(json.dumps(data, indent=1))
        return

    print(f"# {a.image}  ({len(installed)} dists in {data['site']}, index {data['index']})")
    if not focus and not a.what_if:
        for n, d in data['dists'].items():
            ex = f" [{','.join(d['extras_used'])}]" if d['extras_used'] else ''
            print(f"{n}=={d['version']}{ex}  {d['origin']}".rstrip())
            for e in d['requires']:
                print(edge(e, e['name']))
        print("\n# reverse: who requires X")
        for n in sorted(data['rdeps']):
            print(f"{n} ({installed.get(n, 'not installed')})")
            for e in data['rdeps'][n]:
                print(edge(e, f"{e['by']}=={e['by_version']} requires"))
    for f, d in data.get('focus', {}).items():
        print(f"\n== {f} {d['version'] or 'NOT INSTALLED'}\n  requires:")
        for e in d['requires']:
            print(edge(e, e['name']))
        print("  required by:")
        for e in d['required_by']:
            print(edge(e, f"{e['by']}=={e['by_version']}"))
        print(f"  mismatches: {len(d['mismatches'])}")
        tree, inv = data['uv_tree'][f]
        print("  uv pip tree:\n    " + tree.strip().replace('\n', '\n    '))
        print("  uv pip tree --invert:\n    " + inv.strip().replace('\n', '\n    '))
    for w in data.get('whatif', []):
        print(f"\n== what-if {w['request']}  (overrides for accepted conflicts: {' '.join(w['overrides']) or '-'};"
              f" not resolvable from the index, their requirements used instead: {' '.join(w['local_not_resolved'])})")
        for label in ('baseline', 'bump'):
            r = w[label]
            print(f"  {label}: {'resolves' if r['ok'] else 'FAILS'}"
                  + (f", {w['dist']}=={r['pins'].get(w['dist'])}" if r['ok'] else ''))
            if not r['ok']:
                print('    ' + r['error'].replace('\n', '\n    '))
        for key in ('baseline_vs_installed', 'moved_by_bump'):
            if w[key] is not None:
                print(f"  {key}: " + (', '.join(f"{n} {o}->{v}" for n, (o, v) in w[key].items()) or 'nothing'))
    v = data['validation']
    print(f"\n# uv pip check: {len(data['uv_pip_check']['lines'])} incompatibilities; dep_graph agrees: {v['agree']}"
          + ('' if v['agree'] else f" (only uv: {v['only_uv']}, only dep_graph: {v['only_dep_graph']})"))


if __name__ == '__main__':
    main()
