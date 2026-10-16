import { readFile, writeFile, rename, open, unlink, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { check } from './config.mjs';

export const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);

export function newState(c) {
  return { version: 1, chainId: c.chainId, project: c.contracts.QuorumBoard.address.toLowerCase(), cursor: c.deploymentBlock - 1,
    checkpoints: [], events: [], receipts: [], notes: [], pending: null, queue: [], decisions: {}, lastReadHour: null, gasDay: null, gasReserved: '0' };
}

export async function loadState(path, c) {
  let state;
  try { state = JSON.parse(await readFile(path, 'utf8')); }
  catch (e) { if (e.code === 'ENOENT') return newState(c); throw new Error('Cannot read local state; preserve it and repair before signing'); }
  check(state.version === 1 && state.chainId === c.chainId && state.project === c.contracts.QuorumBoard.address.toLowerCase(), 'State belongs to another project or version');
  check(Number.isSafeInteger(state.cursor) && state.cursor >= c.deploymentBlock - 1 && Array.isArray(state.checkpoints) && Array.isArray(state.events), 'Invalid state cursor');
  return state;
}
export async function saveState(path, state) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temp = `${path}.next`;
  await writeFile(temp, json(state) + '\n', { mode: 0o600 });
  await rename(temp, path);
}
export async function lockState(path) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  let handle;
  try { handle = await open(`${path}.lock`, 'wx', 0o600); }
  catch { throw new Error('Connector already running or stale state lock; verify no process is running before removing the lock'); }
  await handle.writeFile(String(process.pid));
  return async () => { await handle.close(); await unlink(`${path}.lock`); };
}

export async function reconcile(state, provider, c) {
  if (!state.checkpoints.length) return;
  const last = state.checkpoints.at(-1);
  if ((await provider.getBlock(last.number))?.hash === last.hash) return;
  let ancestor;
  for (let i = state.checkpoints.length - 2; i >= 0; --i) {
    const cp = state.checkpoints[i];
    if ((await provider.getBlock(cp.number))?.hash === cp.hash) { ancestor = cp; break; }
  }
  check(ancestor, 'Reorg exceeds retained checkpoints; stop signing and explicitly resync from deployment');
  state.cursor = ancestor.number;
  state.checkpoints = state.checkpoints.filter(p => p.number <= ancestor.number);
  state.events = state.events.filter(e => e.blockNumber <= ancestor.number);
  state.receipts = state.receipts.filter(r => r.blockNumber <= ancestor.number);
  state.decisions = {}; state.lastReadHour = null; state.lastContentRevision = null; state.proposalCursor = 0; state.proposalIds = [];
}

export async function syncLogs(state, provider, c) {
  await reconcile(state, provider, c);
  const head = await provider.getBlock('latest');
  check(head && head.number >= c.deploymentBlock + c.confirmations, 'Deployment is not confirmed');
  const confirmed = head.number - c.confirmations;
  for (let batch = 0; batch < c.maxBatches && state.cursor < confirmed; ++batch) {
    const end = Math.min(state.cursor + c.maxLogRange, confirmed);
    const logs = await provider.getLogs({ address: Object.values(c.contracts).map(v => v.address), fromBlock: state.cursor + 1, toBlock: end });
    check(logs.length <= 20000, 'RPC log batch exceeds local limit; reduce maxLogRange');
    const block = await provider.getBlock(end);
    check(block, 'Missing canonical block');
    state.events.push(...logs.map(l => ({ address: l.address, topics: l.topics, data: l.data, blockNumber: l.blockNumber, blockHash: l.blockHash, index: l.index, transactionHash: l.transactionHash })));
    // Keep at most 50k recent logs. Proposal discovery also uses a bounded onchain proposal cursor.
    state.events = state.events.slice(-50000);
    state.checkpoints.push({ number: end, hash: block.hash });
    state.checkpoints = state.checkpoints.slice(-128);
    state.cursor = end;
  }
  return { head, synced: state.cursor >= confirmed, confirmed };
}
