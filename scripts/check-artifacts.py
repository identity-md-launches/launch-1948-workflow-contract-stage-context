#!/usr/bin/env python3
"""Offline deployment-floor and ABI consistency checks; no chain or filesystem cheatcodes."""
import hashlib
import json
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAMES = ['LaunchToken', 'QuorumSeats', 'QuorumBoard', 'QuorumAssembly',
         'QuorumSafePolicy', 'QuorumGovernance', 'QuorumReleases']
config = tomllib.loads((ROOT / 'foundry.toml').read_text())['profile']['default']
assert config['solc'] == '0.8.26' and config['bytecode_hash'] == 'none'
assert not config.get('ffi', False) and not config.get('fs_permissions')
assert not config.get('offline', False)
report = {'compiler': '0.8.26', 'settings': {k: config[k] for k in
          ['evm_version', 'optimizer', 'optimizer_runs', 'via_ir', 'bytecode_hash']}, 'contracts': []}
for name in NAMES:
    artifact = json.loads((ROOT / 'out' / f'{name}.sol' / f'{name}.json').read_text())
    assert artifact['abi'] == json.loads((ROOT / 'docs' / 'abi' / f'{name}.json').read_text()), f'{name}: stale ABI'
    assert not artifact['bytecode'].get('linkReferences'), f'{name}: external library link'
    runtime = bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    init = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
    assert 0 < len(runtime) <= 24576 and len(init) <= 49152, f'{name}: deployment size'
    i = 0
    while i < len(runtime):
        op = runtime[i]
        assert op not in (0xf2, 0xf4, 0xff), f'{name}: forbidden opcode at {i}'
        i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
    constructor = next((a for a in artifact['abi'] if a['type'] == 'constructor'), {'inputs': []})
    assert len(constructor['inputs']) <= 16
    assert all(a['type'] in ('address', 'bytes32') for a in constructor['inputs'])
    report['contracts'].append({'name': name, 'source': f'src/{name}.sol',
        'runtimeBytes': len(runtime), 'creationBytes': len(init),
        'constructorTypes': [a['type'] for a in constructor['inputs']],
        'sourceSha256': hashlib.sha256((ROOT / 'src' / f'{name}.sol').read_bytes()).hexdigest()})
constitution = (ROOT / 'docs' / 'constitution.md').read_bytes()
report['constitutionKeccak256'] = subprocess.check_output(['cast', 'keccak', '0x' + constitution.hex()], text=True).strip()
report['note'] = 'Sizes and opcode scans concern compiled runtime templates. Deployed code hashes require actual immutable values from the deployment handoff. This is not an independent security review.'
(ROOT / 'docs' / 'evidence' / 'build.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
