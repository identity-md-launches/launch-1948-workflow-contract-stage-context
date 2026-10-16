#!/usr/bin/env python3
"""Export only the seven deployable QUORUM contracts from a pinned Foundry build."""
import json
from pathlib import Path

NAMES = ['LaunchToken', 'QuorumSeats', 'QuorumBoard', 'QuorumAssembly',
         'QuorumSafePolicy', 'QuorumGovernance', 'QuorumReleases']
root = Path(__file__).resolve().parent.parent
for name in NAMES:
    artifact = json.loads((root / 'out' / f'{name}.sol' / f'{name}.json').read_text())
    destination = root / 'docs' / 'abi' / f'{name}.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(artifact['abi'], indent=2) + '\n')
print(f'Exported {len(NAMES)} ABIs')
