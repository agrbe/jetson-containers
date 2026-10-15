#!/usr/bin/env python3
"""Check the package list of a build script for version divergences before building.

Resolves the build chain exactly like 'jetson-containers build' and reports:
  - pins dropped or replaced while resolving the chain (first occurrence wins)
  - version ARGs a Dockerfile declares but the package never passes (empty at build time)
  - hardcoded versions of pinned distributions that differ from the pin
  - pip/uv installs of a pinned distribution without a version
  - git clones without a ref (no --branch and no later checkout of the clone),
    or falling back to the default branch, and with --online whether the ref
    exists upstream

With --libs it also lists, per stage in build order, the pip distributions the
stage installs or builds (spec and source line), then the distributions whose
spec changes between stages, unversioned re-installs and incompatible specs.

Usage:
  ./collect_requirements.py --build-sh BUILD_SH [--env .env]
                               [--pins pins.txt] [--online] [--libs] [PACKAGES ...]

Exits 1 when an ERROR is found.
"""

import argparse
import contextlib
import io
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_list as P  # noqa: E402  (stdlib only, safe before the venv re-exec)

VENV_PY = P.ROOT / 'venv' / 'bin' / 'python3'

# jetson_containers needs the repo venv; re-exec under it when started elsewhere
if VENV_PY.exists() and Path(sys.prefix).resolve() != (P.ROOT / 'venv').resolve():
    os.execv(str(VENV_PY), [str(VENV_PY), *sys.argv])

sys.path.insert(1, str(P.ROOT))
from packaging.specifiers import InvalidSpecifier, SpecifierSet  # noqa: E402

INSTALL_RE = re.compile(r'(?:\buv\s+pip|\bpip3?|\bpython3?\s+-m\s+pip)\s+install\b(.*)')
CLONE_RE = re.compile(r'\bgit\s+clone\b(.*)')
# git commands that select the version of an existing clone
CHECKOUT_RE = re.compile(
    r'\bgit\s+(?:-C\s+(\S+)\s+)?(checkout|switch|reset\s+--hard|fetch)\b(.*)'
)
CD_RE = re.compile(r'(?:^|\s)(cd|pushd|popd)\b\s*([^\s;)]*)')
BUILD_RE = re.compile(
    r'\buv\s+build\b|bdist_wheel|--build_wheel|build_wheel\.py|\bpip3?\s+wheel\b'
    r'|\s-m\s+build\b'
)
UPGRADE_RE = re.compile(r'(?:^|\s)(?:-U|--upgrade|--force-reinstall|--reinstall)\b')
# options of 'git clone' that take a value
CLONE_OPTS = {'-b', '--branch', '--depth', '-c', '--config', '-o', '--origin'}
CLONE_OPTS |= {'--reference', '--filter', '-j', '--jobs', '--template', '-u'}
REQ_RE = re.compile(r'^([A-Za-z0-9][A-Za-z0-9_.\-]*)(\[[^\]]*\])?\s*(.*)$')
LITERAL_RE = re.compile(
    r'(?<![\w.\-/])([A-Za-z0-9][A-Za-z0-9_.\-]*)\s*(==|~=)\s*([0-9][0-9A-Za-z.+]*)'
)
# options of 'pip install' that take a value (skip the value too)
OPT_WITH_VALUE = {
    '-r',
    '--requirement',
    '-c',
    '--constraint',
    '-e',
    '--editable',
    '-i',
    '--index-url',
    '--extra-index-url',
    '--default-index',
    '--index',
    '-f',
    '--find-links',
    '--python',
    '-p',
    '--target',
    '--prefix',
    '--overrides',
    '--prerelease',
    '--index-strategy',
    '--python-platform',
    '--python-version',
    '--upgrade-package',
    '-P',
    '--reinstall-package',
    '--no-binary',
    '--only-binary',
    '--config-settings',
    '-C',
    '--torch-backend',
}


class Report:
    def __init__(self):
        self.items = []

    def add(self, level, stage, msg, where=''):
        self.items.append((level, stage, msg, where))

    def print(self, chain, verbose=False):
        order = {name: i for i, name in enumerate(chain)}
        for level in ('ERROR', 'WARN', 'INFO') if verbose else ('ERROR', 'WARN'):
            rows = sorted(
                (i for i in self.items if i[0] == level),
                key=lambda i: (order.get(i[1], -1), i[2]),
            )
            if not rows:
                continue
            print(f"\n== {level} ({len(rows)})")
            for _, stage, msg, where in rows:
                print(f"  [{stage}] {msg}" + (f"\n      at {where}" if where else ''))
        counts = {
            lvl: sum(1 for i in self.items if i[0] == lvl)
            for lvl in ('ERROR', 'WARN', 'INFO')
        }
        print(
            f"\nsummary: {counts['ERROR']} errors, {counts['WARN']} warnings, {counts['INFO']} info"
        )
        return counts['ERROR']


def logical_lines(path):
    """(lineno, text) with backslash continuations joined and comment lines dropped."""
    out, buf, start = [], '', None
    for no, line in enumerate(Path(path).read_text(errors='ignore').splitlines(), 1):
        if line.lstrip().startswith('#') and not buf:
            continue
        start = start or no
        if line.rstrip().endswith('\\'):
            buf += line.rstrip()[:-1] + ' '
            continue
        if line.rstrip().endswith(
            ('||', '&&', '|')
        ):  # the shell keeps reading the next line
            buf += line.rstrip() + ' '
            continue
        out.append((start, buf + line))
        buf, start = '', None
    if buf:
        out.append((start, buf))
    return out


def segments(text):
    """Split a shell line on &&, ||, ; and | while remembering the separator after each part."""
    parts = re.split(r'(&&|\|\||;|\|)', text)
    return [
        (parts[i].strip(), parts[i + 1] if i + 1 < len(parts) else '')
        for i in range(0, len(parts), 2)
    ]


def substitute(text, values):
    """Expand ${VAR}, ${VAR:-default}, ${VAR:=default} and $VAR from values; unknown variables are left untouched."""

    def repl(m):
        key, default = m.group(1) or m.group(3), m.group(2)
        return values.get(key, default if default is not None else m.group(0))

    return re.sub(
        r'\$\{([A-Za-z_][A-Za-z0-9_]*|\d)(?::[-=]([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)',
        repl,
        text,
    )


def script_assignments(lines, values):
    """Plain NAME=value assignments of a script (no command substitution), resolved in order."""
    out, computed = dict(values), set()
    for _, line in lines:
        for seg, _ in segments(line):
            for name, value in re.findall(r'^\s*:\s+"?\$\{(\w+):=([^}]*)\}', seg):
                out.setdefault(name, substitute(value, out))
            m = re.match(
                r'\s*(?:export\s+|local\s+|readonly\s+|ENV\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$',
                seg,
            )
            if not m:
                continue
            value = m.group(2).strip()
            if '$(' in value or '`' in value:
                computed.add(m.group(1))
            elif re.fullmatch(r'"[^"]*"|\'[^\']*\'|\S+', value):
                out.setdefault(m.group(1), substitute(value.strip('"\''), out))
    out['__computed__'] = computed
    return out


def expand_arrays(lines):
    """lines with "${name[@]}" replaced by the items the script puts in array name."""
    arrays = {}
    for _, line in lines:
        for seg, _ in segments(line):
            m = re.match(r'\s*(?:local\s+)?(\w+)(\+?)=\((.*)\)\s*$', seg)
            if m:
                arrays[m.group(1)] = arrays.get(m.group(1), '') * bool(m.group(2))
                arrays[m.group(1)] += ' ' + m.group(3)
    return [
        (no, re.sub(r'"?\$\{(\w+)\[@\]\}"?', lambda m: arrays.get(m[1], m[0]), line))
        for no, line in lines
    ]


def unresolved(text, values):
    """Variables left in text: (computed in the script, defined nowhere in the package)."""
    names = set(re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', text))
    names -= set(values.get('__inherited__', {}))
    computed = values.get('__computed__', set())
    return names & computed, names - computed


def install_requirements(args, paths=None):
    """Requirement specs named on a pip/uv install command line; local paths, wheels
    and VCS URLs go to paths when given."""
    tokens, reqs, skip = args.split(), [], False
    for tok in tokens:
        tok = tok.strip('\'"')
        if skip:
            skip = False
            continue
        if tok.startswith('-'):
            skip = tok in OPT_WITH_VALUE
            continue
        if (
            not tok
            or tok in ('.', '..')
            or '/' in tok
            or tok.endswith(('.whl', '.txt', '.tar.gz'))
        ):
            if paths is not None and tok and not tok.endswith('.txt'):
                paths.append(tok)
            continue
        if tok.startswith(('>', '<', '=', '!', '~', '#', '2>', '$(')) or tok in (
            '\\',
            '||',
            '&&',
        ):
            continue
        reqs.append(tok)
    return reqs


def dockerfile_args(dockerfile):
    """{ARG name: default or None} declared in a Dockerfile (multi-name ARG lines included)."""
    args = {}
    for _, line in logical_lines(dockerfile):
        m = re.match(r'\s*ARG\s+(.*)', line)
        if not m:
            continue
        for item in m.group(1).split():
            name, _, default = item.partition('=')
            if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', name):
                args[name] = default.strip('"\'') if default else None
    return args


def dockerfile_envs(dockerfile, values):
    """{ENV name: value} set by a Dockerfile (KEY=VALUE and legacy 'KEY VALUE' forms)."""
    envs = {}
    for _, line in logical_lines(dockerfile):
        m = re.match(r'\s*ENV\s+(.*)', line)
        if not m:
            continue
        try:
            items = shlex.split(m.group(1))
        except ValueError:
            continue
        if items and '=' not in items[0]:
            items = [f"{items[0]}={' '.join(items[1:])}"]
        for item in items:
            name, _, value = item.partition('=')
            envs[name] = substitute(value, {**values, **envs})
    return envs


def uv_pins(chain, resolved):
    """{dist: (version, stage)} registered by 'uv-pin' along the chain."""
    found = {}
    for name in chain:
        pkg = resolved[name]
        values = {k: str(v) for k, v in (pkg.get('build_args') or {}).items()}
        specs = []
        if pkg.get('dockerfile'):
            dockerfile = Path(pkg['path']) / pkg['dockerfile']
            if dockerfile.is_file():
                for _, line in logical_lines(dockerfile):
                    for arg in re.findall(r'\buv-pin\s+("[^"]+"|\S+)', line):
                        specs.append(substitute(arg.strip('"\''), values))
        for spec in specs:
            m = re.match(r'([A-Za-z0-9_.\-]+)\s*==\s*([^\s;]+)$', spec)
            if m:
                found[P.norm(m.group(1))] = (m.group(2), pkg['name'])
    return found


def git_ls_remote(url, ref):
    try:
        out = subprocess.run(
            ['git', 'ls-remote', url, ref, f'{ref}^{{}}'],
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'},
        ).stdout
    except subprocess.TimeoutExpired:
        return None
    lines = [line.split() for line in out.splitlines() if line.strip()]
    peeled = [sha for sha, r in lines if r.endswith('^{}')]
    return (peeled or [sha for sha, _ in lines] or [''])[0]


def clone_target(seg):
    """(url, directory) of a substituted 'git clone' segment."""
    rest = seg.split('clone', 1)[1]
    try:
        tokens = shlex.split(rest)
    except ValueError:
        tokens = rest.split()
    pos, skip = [], False
    for tok in tokens:
        if skip:
            skip = False
        elif tok.startswith('-'):
            skip = tok in CLONE_OPTS
        elif not re.match(r'\d?[<>|&]', tok):
            pos.append(tok)
    url = pos[0] if pos else ''
    default = re.sub(r'\.git$', '', url.rstrip('/').rsplit('/', 1)[-1])
    return url, pos[1] if len(pos) > 1 else default


def same_repo(a, b):
    return re.sub(r'(\.git)?/*$', '', a) == re.sub(r'(\.git)?/*$', '', b)


def checkout_after(flat, start, target):
    """(ref, lineno, conditional) a script checks out in the clone at target after
    flat[start] (cd/pushd into it, or git -C); None if it never selects one."""
    name, inside, fetched = Path(target).name, False, None
    for no, seg in flat[start + 1 :]:
        if CLONE_RE.search(seg):  # the next clone starts another repo
            break
        m = CD_RE.search(seg)
        if m:
            path = m.group(2).strip('"\'').split('/')
            inside = m.group(1) != 'popd' and name in path
            continue
        m = CHECKOUT_RE.search(seg)
        if not m or not (
            Path(m.group(1).strip('"\'')).name == name if m.group(1) else inside
        ):
            continue
        toks = [t.strip('"\'') for t in m.group(3).split()]
        toks = toks[: toks.index('--')] if '--' in toks else toks
        toks = [t for t in toks if not t.startswith('-') and not re.match(r'\d?>', t)]
        if m.group(2) == 'fetch':
            fetched = toks[-1] if len(toks) > 1 else fetched
        elif toks and toks[-1] != '.':
            ref = fetched if toks[-1] == 'FETCH_HEAD' and fetched else toks[-1]
            return ref, no, bool(re.match(r'(el)?if\s', seg))
    return None


def cache_user(scripts, url, target, clone_where):
    """file:line that checks out from the clone at target or, for a cache clone,
    clones the same url with a ref."""
    found = None
    for rel, flat in scripts:
        for no, seg in flat:
            where = f"{rel}:{no}"
            if where == clone_where or re.match(r'\s*(rm|echo|mkdir)\b', seg):
                continue
            reuse = re.search(re.escape(target) + r'(?![\w.\-])', seg)
            if target.startswith('/') and reuse and CHECKOUT_RE.search(seg):
                return where
            if 'cache' not in target:
                continue
            if CLONE_RE.search(seg) and re.search(r'--branch|-b\s', seg):
                if same_repo(clone_target(seg)[0], url):
                    found = found or where
    return found


def check_clone(
    report,
    stage,
    seg,
    sep,
    next_seg,
    prev,
    values,
    where,
    online,
    later=None,
    cache=None,
):
    inherited = values.get('__inherited__', {})
    used = set(re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', seg))
    for name in sorted(used & set(inherited) - set(values.get('__own__', ()))):
        report.add(
            'WARN',
            stage,
            f"git clone ref uses ${{{name}}}={inherited[name][0]} inherited from "
            f"{inherited[name][1]}, not a value of this package",
            where,
        )
    args = substitute(seg, {**{k: v for k, (v, _) in inherited.items()}, **values})
    ref = re.search(r'(?:--branch[= ]|-b\s+)(\S+)', args)
    url = re.search(r'((?:https?|git|ssh)://\S+|git@\S+)', args)
    url = url.group(1).strip('\'"') if url else None
    ref = ref.group(1).strip('\'"') if ref else None
    url = url or clone_target(args)[0]
    if not ref and (
        prev[1] == '||'
        and CLONE_RE.search(prev[0])
        and re.search(r'--branch|-b\s', prev[0])
    ):
        return  # fallback of a clone with a ref: reported on that clone
    cond = None
    if not ref and later:
        ref, at, cond = later
        ref = substitute(ref, {**{k: v for k, (v, _) in inherited.items()}, **values})
        report.add('INFO', stage, f"git clone {url} then checks out {ref}", at)
        where, sep, next_seg = at, '', ''
    if not ref:
        if cache:
            report.add(
                'INFO',
                stage,
                f"cache clone of {url} into {clone_target(args)[1]}, version selected in {cache}",
                where,
            )
        else:
            report.add(
                'WARN',
                stage,
                f"git clone {url} without a ref tracks the default branch",
                where,
            )
        return
    if ref in ('main', 'master', 'HEAD'):
        # a <X>_REF/_TAG build arg paired with <X>_SHA: the script checks the commit
        var = re.search(r'(?:--branch[= ]|-b\s+)["\']?\$\{?([A-Za-z_]\w*?)_(?:REF|TAG)\b', seg)
        sha = values.get(f"{var.group(1)}_SHA") if var else None
        if sha:
            report.add(
                'INFO',
                stage,
                f"git clone {url} uses the branch {ref}, verified against {var.group(1)}_SHA={sha[:12]}",
                where,
            )
        else:
            report.add(
                'WARN', stage, f"git clone {url} uses the moving branch {ref}", where
            )
    if '$' in ref:
        computed, undefined = unresolved(ref, values)
        if undefined:
            report.add(
                'WARN',
                stage,
                f"git clone {url} ref {ref}: ${{{', '.join(sorted(undefined))}}} is not defined"
                " by this package (inherited from an earlier image, or empty)",
                where,
            )
        else:
            report.add(
                'INFO',
                stage,
                f"git clone {url} ref {ref} is computed at build time (not checked)",
                where,
            )
    elif online and url and re.fullmatch(r'[0-9a-f]{7,40}', ref):
        report.add('INFO', stage, f"{url} {ref} is a commit (not checked)", where)
    elif online and url:
        sha = git_ls_remote(url, ref)
        if sha is None:
            report.add('WARN', stage, f"git ls-remote {url} {ref} timed out", where)
        elif not sha:
            nxt = sep == '||' and 'git clone' in next_seg
            default = nxt and not re.search(r'--branch|-b\s', next_seg)
            fails = "clone fails" if cond is None else "checkout fails"
            report.add(
                'WARN' if cond else 'ERROR',
                stage,
                f"ref {ref} not found in {url} -> "
                + (
                    "falls back to the default branch"
                    if default
                    else (
                        "falls back to the next git clone"
                        if nxt
                        else fails + (" (the script handles it)" if cond else '')
                    )
                ),
                where,
            )
        else:
            report.add('INFO', stage, f"{url} {ref} -> {sha[:12]}", where)
    if (
        sep == '||'
        and 'git clone' in next_seg
        and not re.search(r'--branch|-b\s', next_seg)
    ):
        report.add(
            'INFO',
            stage,
            f"git clone {url} --branch {ref} falls back to the default branch if the ref is missing",
            where,
        )


def package_files(pkg):
    """(Dockerfile or None, build values, [Dockerfile and *.sh helpers]) of a package."""
    pkg_dir = Path(pkg['path'])
    values = {k: str(v) for k, v in (pkg.get('build_args') or {}).items()}
    dockerfile = pkg_dir / pkg['dockerfile'] if pkg.get('dockerfile') else None
    if not (dockerfile and dockerfile.is_file()):
        dockerfile = None
    for name, default in (dockerfile_args(dockerfile) if dockerfile else {}).items():
        if default is not None:
            values.setdefault(name, default)
    files = [dockerfile] if dockerfile else []
    files += sorted(f for f in pkg_dir.glob('*.sh') if not f.name.startswith('test'))
    return dockerfile, values, files


def scan_package(report, stage, pkg, pins, online, inherited):
    """Scan one package; returns the ENV it sets for the images built on top of it."""
    dockerfile, values, files = package_files(pkg)
    if dockerfile:
        for name, default in dockerfile_args(dockerfile).items():
            if default is None and (
                re.search(r'VERSION|BRANCH|PACKAGE', name)
                and name not in values
                and name != 'BASE_IMAGE'
                and name not in os.environ
                and name
                not in inherited  # an ENV of an earlier image wins over an empty ARG
            ):
                report.add(
                    'WARN',
                    stage,
                    f"ARG {name} is declared but the package passes no value (empty at build time)",
                    str(dockerfile.relative_to(P.ROOT)),
                )

    own = set(P.dists_for(pkg['name']))
    env0 = {k: v for k, (v, _) in inherited.items()}
    scripts = []
    for path in files:
        lines = expand_arrays(logical_lines(path))
        local = script_assignments(lines, values)
        flat = [
            (no, substitute(seg, {**env0, **local}))
            for no, line in lines
            for seg, _ in segments(line)
        ]
        scripts.append((path.relative_to(P.ROOT), lines, local, flat))
    linked = [(rel, flat) for rel, _, _, flat in scripts]
    for rel, lines, local, flat in scripts:
        local['__own__'] = (
            set(local) | set(dockerfile_args(dockerfile)) if dockerfile else set(local)
        )
        local['__inherited__'] = inherited
        note = " (source build only)" if rel.name == 'build.sh' else ''
        k = -1  # index of the current segment in flat
        for no, line in lines:
            where = f"{rel}:{no}{note}"
            segs = segments(line)
            for i, (seg, sep) in enumerate(segs):
                k += 1
                prev = segs[i - 1] if i else ('', '')
                fallback = prev[1] == '||'
                env = {**env0, **local}
                for dist, op, ver in LITERAL_RE.findall(substitute(seg, env)):
                    d = P.norm(dist)
                    if d in pins and not P.version_matches(ver, pins[d]):
                        report.add(
                            'WARN' if fallback else 'ERROR',
                            stage,
                            f"{dist}{op}{ver} differs from the pin {d}=={pins[d]}"
                            + (" (fallback after ||)" if fallback else ''),
                            where,
                        )
                m = INSTALL_RE.search(seg)
                if m:
                    for req in install_requirements(substitute(m.group(1), env)):
                        r = REQ_RE.match(req)
                        if not r:
                            continue
                        d, spec = P.norm(r.group(1)), r.group(3)
                        if d in pins and not spec:
                            level = 'INFO' if d in own else 'WARN'
                            report.add(
                                level,
                                stage,
                                f"installs pinned {d} without a version (pin {pins[d]})",
                                where,
                            )
                        elif d in pins and '$' in spec:
                            computed, undefined = unresolved(spec, local)
                            report.add(
                                'WARN' if undefined else 'INFO',
                                stage,
                                f"installs {req}: version "
                                + (
                                    "is not defined by this package"
                                    if undefined
                                    else "is computed at build time"
                                ),
                                where,
                            )
                m = CLONE_RE.search(seg)
                if m:
                    next_seg = segs[i + 1][0] if i + 1 < len(segs) else ''
                    url, target = clone_target(flat[k][1])
                    later = checkout_after(flat, k, target)
                    cache = cache_user(linked, url, target, f"{rel}:{no}")
                    check_clone(
                        report,
                        stage,
                        seg,
                        sep,
                        next_seg,
                        prev,
                        local,
                        where,
                        online,
                        later and (later[0], f"{rel}:{later[1]}{note}", later[2]),
                        cache,
                    )
            if re.search(r'\bADD\b.*api\.github\.com/repos/\S+/git/refs/heads/', line):
                report.add(
                    'WARN',
                    stage,
                    "Dockerfile ADDs a branch ref: the image tracks a moving branch",
                    where,
                )
    return dockerfile_envs(dockerfile, values) if dockerfile else {}


def req_file_rows(path, via):
    """(dist, spec, where, tag) of a requirements file shipped with the package."""
    rows, rel = [], path.relative_to(P.ROOT)
    for no, line in enumerate(path.read_text(errors='ignore').splitlines(), 1):
        line = line.split('#')[0].strip()
        nested = re.match(r'(?:-r|--requirement)[= ]\s*(\S+)', line)
        if nested and (path.parent / nested[1]).is_file():
            rows += req_file_rows(path.parent / nested[1], via)
        elif line and not line.startswith('-') and REQ_RE.match(line):
            r = REQ_RE.match(line)
            rows.append(
                (P.norm(r[1]), r[3].split(';')[0].strip(), f"{rel}:{no}{via}", '')
            )
    return rows


def script_libs(path, values, own, version, by_dir, via=''):
    """(dist, spec, where, tag) for the pip installs and wheel builds of a script.

    tag: built (wheel of the package itself), wheel (local .whl), git (VCS URL),
    -U (upgrade/reinstall flag), req (requirements file known only at build time).
    """
    rel = path.relative_to(P.ROOT)
    lines = expand_arrays(logical_lines(path))
    local = script_assignments(lines, values)
    note = " (source build only)" if path.name == 'build.sh' else ''
    rows, repo, seds = [], None, {}
    for no, line in lines:
        where = f"{rel}:{no}{note}{via}"
        for seg, _ in segments(line):
            seg = substitute(seg, local)
            if CLONE_RE.search(seg):
                repo = clone_target(seg)[0]
            if re.search(r'\bsed\b.*\s-i', seg):
                for f in re.findall(r'[\w./\-]*requirements[\w.\-]*\.txt', seg):
                    seds[Path(f).name] = f"{rel}:{no}"
            if BUILD_RE.search(seg):
                rows += [(d, version, where, 'built') for d in own]
            for name in re.findall(r'/tmp/([\w.\-]+)/install\.sh', seg):
                if name != path.parent.name and name in by_dir and not via:
                    rows += script_libs(
                        by_dir[name] / 'install.sh',
                        local,
                        P.dists_for(name),
                        '',
                        by_dir,
                        f" (rerun via {rel}:{no})",
                    )
            m = INSTALL_RE.search(seg)
            if not m:
                continue
            tag, paths = '-U' if UPGRADE_RE.search(m[1]) else '', []
            for req in install_requirements(m[1], paths):
                r = REQ_RE.match(req)
                if r:
                    rows.append((P.norm(r[1]), r[3].split(';')[0].strip(), where, tag))
            for path_ in paths:
                whl = re.match(r'([A-Za-z0-9_.]+)-(\d[^-]*)-.*\.whl$', Path(path_).name)
                git = re.match(r'git\+\S+/([^/@]+?)(?:\.git)?(?:@(\S+))?$', path_)
                if whl:
                    rows.append((P.norm(whl[1]), '==' + whl[2], where, 'wheel'))
                elif git:
                    rows.append(
                        (P.norm(git[1]), '@' + (git[2] or 'default'), where, 'git')
                    )
                else:  # local source tree or wheel glob: the package's own dist
                    rows += [(d, version, where, 'built') for d in own]
            for f in re.findall(r'(?:-r|--requirement)[= ]\s*(\S+)', m[1]):
                f = f.strip('\'"')
                shipped = path.parent / Path(f).name
                if f.startswith('/tmp/') and shipped.is_file():
                    rows += req_file_rows(shipped, via)
                    continue
                edited = seds.get(Path(f).name)
                rows.append(
                    (
                        f"-r {Path(f).name}",
                        (f"requirements of {repo}" if repo else f"{f}")
                        + " (resolved at build time)"
                        + (f", edited by sed at {edited}" if edited else ''),
                        where,
                        'req',
                    )
                )
    return rows


def compatible(a, b):
    """False when no version satisfies both specs; unknown specs count as compatible."""
    try:
        sa, sb = SpecifierSet(a), SpecifierSet(b)
    except InvalidSpecifier:
        return True
    # ponytail: tries the versions the specs name plus nearby ones, not a solver
    names = re.findall(r'\d+(?:\.\d+)*', f"{a} {b}")
    cands = [v + s for v in names for s in ('', '.1', '.post1', '.dev0')]
    cands += ['0'] + [str(int(v.split('.')[0]) - 1) for v in names]
    return any(sa.contains(c, True) and sb.contains(c, True) for c in cands)


def print_libs(stages):
    """Per-stage pip distributions, then the cross-stage analysis."""
    print("\n== libs: pip distributions each stage installs or builds (build order)")
    print("   build.sh rows run only on a source build; (any) = no version given")
    empty = []
    for i, stage, rows in stages:
        if not rows:
            empty.append(f"#{i} {stage}")
            continue
        print(f"\n  #{i} {stage}")
        for d, spec, where, tag in rows:
            spec = (spec or '(any)') + (f" [{tag}]" if tag and tag != 'req' else '')
            wrap = '\n' + ' ' * 61 if len(spec) > 24 else ' '
            print(f"     {d:<30} {spec:<24}{wrap}{where}")
    if empty:
        print("\n  no pip installs: " + ', '.join(empty))

    by_dist = {}
    for i, stage, rows in stages:
        for d, spec, where, tag in rows:
            if tag != 'req':
                by_dist.setdefault(d, []).append((i, stage, spec, where, tag))
    changes, unversioned, conflicts = [], [], []
    for d, rows in sorted(by_dist.items()):
        versioned = [r for r in rows if r[2]]
        if len({r[2] for r in versioned}) > 1 and len({r[0] for r in versioned}) > 1:
            steps = []
            for i, stage, spec, _, _ in versioned:
                if f"#{i} {stage} {spec}" not in steps:
                    steps.append(f"#{i} {stage} {spec}")
            changes.append(f"{d}: " + ' -> '.join(steps))
        pinned = next((r for r in rows if re.match(r'(==|~=)', r[2])), None)
        for i, stage, spec, where, tag in rows:
            if pinned and i > pinned[0] and not spec:
                unversioned.append(
                    f"{d}: {pinned[2]} at #{pinned[0]} {pinned[1]}, then (any)"
                    f"{' [-U]' if tag == '-U' else ''} at #{i} {stage}\n        {where}"
                )
        seen = []
        for i, stage, spec, _, _ in versioned:
            for j, other, prev in seen:
                if j != i and '$' not in spec + prev and not compatible(spec, prev):
                    conflicts.append(
                        f"{d}: {prev} (#{j} {other}) vs {spec} (#{i} {stage})"
                    )
            seen.append((i, stage, spec))
    reqs = [
        f"#{i} {stage} {d}"
        for i, stage, rows in stages
        for d, _, _, t in rows
        if t == 'req'
    ]
    print("\n== cross-stage")
    for title, items in (
        ("spec changes between stages", changes),
        (
            "installed without a version after a versioned install"
            " (uv keeps the installed version unless -U or another requirement moves it)",
            unversioned,
        ),
        ("INCOMPATIBLE specs", conflicts),
        (
            "requirements files read from cloned sources (known only at build time)",
            reqs,
        ),
    ):
        print(f"\n  {title}: {len(items) or 'none'}")
        for item in items:
            print(f"     {item}")
    print(
        "\n  build-time only: resolver picks for (any)/range specs and for the"
        " dependencies of every install, requirements of cloned repos, and which"
        " branch of 'install.sh || build.sh' runs"
    )


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        'packages',
        nargs='*',
        help="packages to check (default: PACKAGES in --build-sh)",
    )
    parser.add_argument('--build-sh', help="build script whose PACKAGES are checked")
    parser.add_argument(
        '--env', default=str(P.ROOT / '.env'), help="pin file sourced by build.sh"
    )
    parser.add_argument(
        '--pins', help="extra pip pins, one 'name==version' per line (numpy, ...)"
    )
    parser.add_argument(
        '--online', action='store_true', help="resolve git refs with git ls-remote"
    )
    parser.add_argument(
        '--libs',
        action='store_true',
        help="list the pip distributions each stage installs, and cross-stage changes",
    )
    parser.add_argument(
        '-v', '--verbose', action='store_true', help="also list INFO findings"
    )
    args = parser.parse_args()
    if not args.packages and not args.build_sh:
        parser.error("pass --build-sh or a list of PACKAGES")

    P.load_env(args.env)
    requested = args.packages or P.read_packages(args.build_sh)
    pins = P.pip_pins(requested, P.read_pip_pins(args.pins))

    with contextlib.redirect_stdout(io.StringIO()):
        from jetson_containers.packages import find_package, resolve_dependencies

        try:
            chain = resolve_dependencies(list(requested))
        except KeyError as e:  # a listed package/variant does not exist
            missing = str(e).strip('"\'').split(':', 1)[-1].strip()
            sys.stdout = sys.__stdout__
            print(f"ERROR: package not found: {missing} (check {args.build_sh})")
            sys.exit(1)
        except ValueError as e:  # conflicting variants of one package
            sys.stdout = sys.__stdout__
            print(f"ERROR: {e}")
            sys.exit(1)
        resolved = {name: find_package(name) for name in chain}

    report = Report()
    names = {name: pkg['name'] for name, pkg in resolved.items()}
    chain_pins = uv_pins(chain, resolved)
    pins = {**pins, **{d: v for d, (v, _) in chain_pins.items()}}
    if chain_pins:
        print(
            "uv-pin: "
            + ' '.join(
                f"{d}=={v} ({src})" for d, (v, src) in sorted(chain_pins.items())
            )
        )
    print(f"chain: {len(chain)} stages")
    print('  ' + ' '.join(names[n] for n in chain))

    # pins dropped while resolving: the chain keeps the first variant it meets
    for pin in requested:
        with contextlib.redirect_stdout(io.StringIO()):
            want = find_package(pin)['name']
        base = pin.split(':')[0]
        got = [names[n] for n in chain if n.split(':')[0] == base]
        if want not in got:
            pullers = [
                names[n]
                for n in chain
                if any(d.split(':')[0] == base for d in resolved[n].get('depends', []))
            ]
            report.add(
                'ERROR',
                pin,
                f"pin replaced by {', '.join(got) or 'nothing'}"
                + (
                    f" (pulled unpinned by {', '.join(pullers[:4])})" if pullers else ''
                ),
            )
        if len(set(got)) > 1:
            report.add('WARN', pin, f"several variants in the chain: {', '.join(got)}")

    inherited = {}  # ENV set by earlier images: name -> (value, stage)
    stages, by_dir = [], {}  # --libs rows per stage; package dir name -> path
    for i, name in enumerate(chain, 1):
        pkg = resolved[name]
        if args.libs:
            _, values, files = package_files(pkg)
            values = {**{k: v for k, (v, _) in inherited.items()}, **values}
            by_dir[Path(pkg['path']).name] = Path(pkg['path'])
            ver = re.match(r'\d[\w.]*', pkg['name'].partition(':')[2])
            own, ver = P.dists_for(pkg['name']), '==' + ver[0] if ver else ''
            rows = [r for f in files for r in script_libs(f, values, own, ver, by_dir)]
            first = {}  # the same dist and spec from several lines: keep the first
            for row in rows:
                first.setdefault(row[:2], row)
            stages.append((i, names[name], list(first.values())))
        envs = scan_package(report, names[name], pkg, pins, args.online, inherited)
        inherited.update({k: (v, names[name]) for k, v in envs.items()})

    if args.libs:
        print_libs(stages)

    errors = report.print([names[n] for n in chain] + requested, args.verbose)
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
