#!/usr/bin/env python3
"""Create a deterministic source/connector inventory, never an IMD launch manifest."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
paths = [root / n for n in ['foundry.toml', 'package.json', 'README.md', 'LICENSE']]
for directory in ['src', 'test', 'vendor', 'connector', 'scripts', 'docs']:
    for p in (root / directory).rglob('*'):
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        if rel.startswith('test/scratch/') or rel == 'docs/release-manifest.json':
            continue
        if p.suffix == '.key' or p.name.startswith('local-state') or p.name == 'config.local.json' or '__pycache__' in p.parts:
            continue
        paths.append(p)
inventory = {
    'schema': 'quorum-source-contribution/v1',
    'status': 'Unapproved source contribution; not a launch manifest or a deployed official release',
    'build': 'Solidity 0.8.26, settings in foundry.toml; forge build; python3 scripts/export-abi.py',
    'test': 'forge test with the documented seed; node --test connector/test/*.test.mjs',
    'registryHashConvention': 'Keccak-256 of exact published artifacts. Individual inventory entries below use SHA-256.',
    'files': [{ 'path': p.relative_to(root).as_posix(), 'bytes': p.stat().st_size,
                'sha256': hashlib.sha256(p.read_bytes()).hexdigest() } for p in sorted(set(paths))]
}
(root / 'docs' / 'release-manifest.json').write_text(json.dumps(inventory, indent=2) + '\n')
print(f'Inventoried {len(inventory["files"])} ordinary files; no private configuration or scratch files')
