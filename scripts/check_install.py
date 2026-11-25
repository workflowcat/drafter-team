"""Check the exact lean lock and upstream requirements with uv's exclusions.

uv pip check sees upstream metadata, not resolver overrides. It will report the
four intentionally absent packages. Do not suppress other missing dependencies.
No runtime libraries, models, or personal data are imported here.
"""
from importlib.metadata import distributions
from pathlib import Path
import sys

from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

ROOT = Path(__file__).resolve().parents[1]


def requirements(path):
    return [Requirement(line.strip()) for line in path.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def main():
    pins = {canonicalize_name(r.name): r for r in requirements(ROOT / 'requirements-lock.txt')}
    overrides = requirements(ROOT / 'requirements-overrides.txt')
    ignored = {canonicalize_name(r.name) for r in overrides if r.marker and not r.marker.evaluate()}
    assert ignored == {'torch', 'librosa', 'numba', 'scipy'}, 'Unexpected exclusion policy'
    installed = {canonicalize_name(d.metadata['Name']): d for d in distributions()}
    errors = []
    for name in sorted(pins.keys() | installed.keys()):
        if name not in pins:
            errors.append(f'Not in lock: {name}')
        elif name not in installed:
            errors.append(f'Missing locked package: {name}')
        elif not pins[name].specifier.contains(installed[name].version):
            errors.append(f'Wrong version: {name} {installed[name].version}, expected {pins[name]}')
    environment = {**default_environment(), 'extra': ''}
    for name, dist in installed.items():
        for raw in dist.requires or []:
            req = Requirement(raw)
            if req.marker and not req.marker.evaluate(environment):
                continue
            dependency = canonicalize_name(req.name)
            if dependency in ignored:
                continue
            if dependency not in installed:
                errors.append(f'{name} requires missing {req}')
            elif req.specifier and not req.specifier.contains(installed[dependency].version):
                errors.append(f'{name} requires {req}; installed {installed[dependency].version}')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'PASS: {len(installed)} exact pins; upstream dependencies checked with four explicit uv exclusions.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
