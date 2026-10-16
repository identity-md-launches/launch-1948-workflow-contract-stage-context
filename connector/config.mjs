import { getAddress, isHexString } from './ethers.min.js';

export const ACTIONS = Object.freeze(['feedback', 'accept', 'decline', 'vote', 'comment', 'acceptWork', 'propose', 'execute', 'requestExit']);
export const CONTRACTS = Object.freeze(['LaunchToken', 'QuorumSeats', 'QuorumBoard', 'QuorumAssembly', 'QuorumSafePolicy', 'QuorumGovernance', 'QuorumReleases']);
const nonzero = (v) => getAddress(v) !== '0x0000000000000000000000000000000000000000';
export function check(condition, message) { if (!condition) throw new Error(message); }
export function integer(value, min, max, name) {
  check(Number.isSafeInteger(value) && value >= min && value <= max, `Invalid ${name}`);
  return value;
}
export function validateConfig(c) {
  check(c && c.chainId === 1, 'Ethereum mainnet chainId must be 1');
  const rpc = new URL(c.rpcUrl);
  check(['https:', 'http:'].includes(rpc.protocol), 'RPC must use HTTP(S)');
  integer(c.deploymentBlock, 1, Number.MAX_SAFE_INTEGER, 'deploymentBlock');
  integer(c.confirmations, 12, 64, 'confirmations');
  integer(c.maxLogRange, 1, 2000, 'maxLogRange');
  integer(c.maxBatches, 1, 8, 'maxBatches');
  integer(c.pollSeconds, 1, 3600, 'pollSeconds');
  check(/^\d+$/.test(String(c.seat)) && BigInt(c.seat) < (1n << 256n) - 1n, 'Invalid seat token ID');
  check(nonzero(c.agentAddress), 'Agent address required');
  check(typeof c.stateFile === 'string' && c.stateFile.length > 0, 'Local stateFile required');
  check(typeof c.privateKeyFile === 'string' && c.privateKeyFile.length > 0, 'Owner-selected privateKeyFile required');
  for (const name of CONTRACTS) {
    check(nonzero(c.contracts?.[name]?.address), `Missing ${name} address`);
    check(isHexString(c.contracts[name].codeHash, 32) && BigInt(c.contracts[name].codeHash) !== 0n, `Missing ${name} runtime hash`);
  }
  check(new Set(CONTRACTS.map(n => c.contracts[n].address.toLowerCase())).size === CONTRACTS.length, 'Contract addresses must be distinct');
  check(isHexString(c.constitutionHash, 32) && BigInt(c.constitutionHash) !== 0n, 'Exact constitution hash required');
  check(typeof c.constitutionFile === 'string' && c.constitutionFile.length > 0, 'Local reviewed constitution required');
  check(Array.isArray(c.policy?.actions) && c.policy.actions.every(a => ACTIONS.includes(a)), 'Invalid signing policy actions');
  if (c.policy.actions.some(a => ['vote', 'propose', 'acceptWork'].includes(a))) check(c.policy.actions.includes('feedback'), 'Governance participation requires feedback permission');
  if (c.policy.actions.includes('vote')) check(c.policy.actions.includes('comment'), 'Voting requires permission to publish readable rationale');
  for (const name of ['maxFeePerGasWei', 'maxPriorityFeePerGasWei', 'dailyGasBudgetWei']) {
    check(/^\d+$/.test(c.policy[name]) && BigInt(c.policy[name]) > 0n, `Positive ${name} required`);
  }
  check(BigInt(c.policy.maxPriorityFeePerGasWei) <= BigInt(c.policy.maxFeePerGasWei), 'Priority fee exceeds fee cap');
  integer(c.policy.maxGasPerTransaction, 21000, 16000000, 'maxGasPerTransaction');
  check(Array.isArray(c.policy.proposalTargets), 'Explicit proposalTargets policy required');
  for (const t of c.policy.proposalTargets) {
    check(nonzero(t.address) && Array.isArray(t.selectors) && t.selectors.every(s => isHexString(s, 4) || s === '0x'), 'Invalid proposal target policy');
    check(/^\d+$/.test(t.maxValueWei), 'Target value cap required');
  }
  if (c.model) {
    const u = new URL(c.model.url);
    check(u.protocol === 'https:' || (u.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname)), 'Model URL must be HTTPS or owner-local HTTP');
    check(typeof c.model.name === 'string' && c.model.name.length > 0, 'Model name required');
  }
  return c;
}

export function allowed(c, action) { check(c.policy.actions.includes(action), `Owner policy forbids ${action}`); }

export function validateProposalActions(c, calls) {
  allowed(c, 'propose');
  check(Array.isArray(calls) && calls.length > 0 && calls.length <= 8, 'Proposal needs 1–8 actions');
  check(calls.reduce((n, a) => n + ((a.data?.length ?? 2) - 2) / 2, 0) <= 4096, 'Proposal exceeds total calldata bound');
  for (const a of calls) {
    check(nonzero(a.target) && /^\d+$/.test(String(a.value)) && isHexString(a.data), 'Invalid proposal action');
    check((a.data.length - 2) / 2 <= 4096 && isHexString(a.expectedReturnHash, 32), 'Proposal data or return hash invalid');
    const rule = c.policy.proposalTargets.find(t => t.address.toLowerCase() === a.target.toLowerCase());
    check(rule && rule.selectors.includes(a.data.length >= 10 ? a.data.slice(0, 10) : a.data) && BigInt(a.value) <= BigInt(rule.maxValueWei), 'Proposal outside owner target/selector/value policy');
  }
  return calls;
}

// Model responses are DATA. They cannot add operations, destinations, code, fees, paths or permissions.
export function validateDecision(c, raw, eligible) {
  check(raw && typeof raw === 'object' && !Array.isArray(raw), 'Model decision must be an object');
  const fields = ['action', 'proposalId', 'choice', 'rationale'];
  check(Object.keys(raw).every(k => fields.includes(k)), 'Unexpected model decision field');
  check(['none', 'vote', 'comment', 'acceptWork'].includes(raw.action), 'Unsupported model action');
  if (raw.action === 'none') return { action: 'none' };
  allowed(c, raw.action);
  const p = eligible.find(p => String(p.id) === String(raw.proposalId));
  check(p, 'Model selected an unavailable proposal');
  check(typeof raw.rationale === 'string' && Buffer.byteLength(raw.rationale) > 0 && Buffer.byteLength(raw.rationale) <= 2048, 'Rationale must be 1–2048 UTF-8 bytes');
  if (raw.action === 'vote') check([0, 1, 2].includes(raw.choice) && p.canVote, 'Invalid or ineligible vote');
  if (raw.action === 'acceptWork') check(p.workHash && BigInt(p.workHash) !== 0n && p.canAccept, 'No available work responsibility');
  return { ...raw, proposalId: String(p.id) };
}
