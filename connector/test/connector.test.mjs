import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { CONTRACTS, validateConfig, validateDecision, validateProposalActions } from '../config.mjs';
import { newState, saveState, loadState, lockState, syncLogs, reconcile } from '../store.mjs';
import { decisionPlan, Engine } from '../engine.mjs';
import { Chain, FEEDBACK_TYPES, localSigner, contractsFor } from '../chain.mjs';
import { modelRequest } from '../model.mjs';
import { Wallet, TypedDataEncoder, verifyTypedData, keccak256, toUtf8Bytes, ZeroHash } from '../ethers.min.js';

await mkdir(resolve('test/scratch'), { recursive: true });

function fixture() {
  return { chainId: 1, rpcUrl: 'https://rpc.example.invalid', deploymentBlock: 100, confirmations: 12, maxLogRange: 10, maxBatches: 2, pollSeconds: 1,
    seat: '7', agentAddress: new Wallet('0x' + '11'.repeat(32)).address, privateKeyFile: 'fixture.key', stateFile: 'fixture-state.json', constitutionFile: 'fixture-constitution.md',
    constitutionHash: keccak256(toUtf8Bytes('test constitution')),
    contracts: Object.fromEntries(CONTRACTS.map((n, i) => [n, { address: '0x' + (i + 1000).toString(16).padStart(40, '0'), codeHash: keccak256(toUtf8Bytes(n)) }])),
    policy: { actions: ['feedback', 'accept', 'decline', 'vote', 'comment', 'acceptWork', 'propose', 'execute'], maxGasPerTransaction: 300000,
      maxFeePerGasWei: '1000000000', maxPriorityFeePerGasWei: '100000000', dailyGasBudgetWei: '1000000000000000', proposalTargets: [] } };
}
const commitment = keccak256(toUtf8Bytes('exact proposal'));
const relevant = [{ id: '1', commitment, canVote: true, canAccept: true, workHash: keccak256(toUtf8Bytes('work')) }];
const fakeBlocks = n => ({ number: n, hash: keccak256(toUtf8Bytes(`block-${n}`)), timestamp: 360000 + n * 12 });

test('configuration rejects wrong chain, absent addresses, confirmations and implicit spend limits', async () => {
  assert.equal(validateConfig(fixture()).chainId, 1);
  for (const change of [{ chainId: 2 }, { confirmations: 11 }, { deploymentBlock: 0 }, { agentAddress: 'FROM_HANDOFF' }]) assert.throws(() => validateConfig({ ...fixture(), ...change }));
  const c = fixture(); c.policy.maxFeePerGasWei = '0'; assert.throws(() => validateConfig(c));
  const noFeedback = fixture(); noFeedback.policy.actions = ['vote', 'comment']; assert.throws(() => validateConfig(noFeedback), /feedback permission/);
  const noRationale = fixture(); noRationale.policy.actions = ['vote', 'feedback']; assert.throws(() => validateConfig(noRationale), /readable rationale/);
  const template = JSON.parse(await readFile(new URL('../config.example.json', import.meta.url), 'utf8'));
  assert.throws(() => validateConfig(template));
});

test('untrusted model cannot add code, destination, key paths, or operations', () => {
  const c = fixture();
  for (const raw of [
    { action: 'exec', command: 'curl attacker' },
    { action: 'vote', proposalId: '1', choice: 1, rationale: 'yes', to: 'attacker' },
    { action: 'vote', proposalId: '2', choice: 1, rationale: 'yes' },
    { action: 'vote', proposalId: '1', choice: 7, rationale: 'yes' },
    { action: 'comment', proposalId: '1', rationale: 'x'.repeat(2049) },
    { action: 'acceptWork', proposalId: '1', rationale: 'yes', privateKeyFile: '/owner/key' }
  ]) assert.throws(() => validateDecision(c, raw, relevant));
  c.policy.actions = ['feedback']; assert.throws(() => validateDecision(c, { action: 'vote', proposalId: '1', choice: 1, rationale: 'yes' }, relevant));
});

test('vote plan preserves exact commitment and publishes readable rationale before voting', () => {
  const p = decisionPlan(fixture(), { action: 'vote', proposalId: '1', choice: 2, rationale: 'Insufficient evidence; abstain.' }, relevant);
  assert.equal(p.action, 'comment'); assert.equal(p.kind, 4); assert.equal(p.next.action, 'vote');
  assert.equal(p.commitment, commitment); assert.equal(p.next.commitment, commitment);
  assert.equal(p.next.rationale, p.body);
});

test('owner policy bounds exact proposal targets, selectors and values', () => {
  const c = fixture(); const target = c.contracts.LaunchToken.address;
  c.policy.proposalTargets = [{ address: target, selectors: ['0xa9059cbb'], maxValueWei: '0' }];
  const calls = [{ target, data: '0xa9059cbb', value: '0', expectedReturnHash: ZeroHash }];
  assert.equal(validateProposalActions(c, calls).length, 1);
  assert.throws(() => validateProposalActions(c, [{ ...calls[0], value: '1' }]));
  assert.throws(() => validateProposalActions(c, [{ ...calls[0], data: '0x095ea7b3' }]));
  assert.throws(() => validateProposalActions(c, [{ ...calls[0], target: c.contracts.QuorumSeats.address }]));
});

test('bounded log batches, restart cursor and reorg rollback use confirmed canonical blocks', async () => {
  const c = fixture(), s = newState(c); const requests = [];
  const provider = { getBlock: async n => fakeBlocks(n === 'latest' ? 160 : n), getLogs: async r => { requests.push(r); return []; } };
  const first = await syncLogs(s, provider, c); assert.equal(first.synced, false); assert.equal(s.cursor, 119);
  assert.deepEqual(requests.map(r => [r.fromBlock, r.toBlock]), [[100, 109], [110, 119]]);
  await syncLogs(s, provider, c); assert.equal(s.cursor, 139);
  s.events = [{ blockNumber: 119 }, { blockNumber: 139 }]; s.receipts = [{ blockNumber: 139 }]; s.decisions = { 1: 'vote' };
  provider.getBlock = async n => n === 139 ? { ...fakeBlocks(n), hash: 'changed' } : fakeBlocks(n);
  await reconcile(s, provider, c); assert.equal(s.cursor, 129); assert.equal(s.events.length, 1); assert.equal(s.receipts.length, 0); assert.deepEqual(s.decisions, {});
  provider.getBlock = async n => ({ ...fakeBlocks(n), hash: 'deep change' });
  await assert.rejects(reconcile(s, provider, c), /Reorg exceeds/);
});

test('atomic local persistence validates project identity and excludes concurrent writers', async () => {
  const dir = await mkdtemp(resolve('test/scratch/store-'));
  try {
    const c = fixture(), path = `${dir}/state.json`, state = newState(c);
    await saveState(path, state); assert.equal((await loadState(path, c)).cursor, 99);
    const unlock = await lockState(path); await assert.rejects(lockState(path), /already running/); await unlock();
    c.contracts.QuorumBoard.address = c.contracts.QuorumSeats.address; await assert.rejects(loadState(path, c), /another project/);
  } finally { await rm(dir, { recursive: true }); }
});

function engineFixture() {
  const c = fixture(), state = newState(c); let broadcasts = 0; const saved = [];
  const provider = {
    getBlock: async n => fakeBlocks(n === 'latest' ? 160 : n), getLogs: async () => [],
    estimateGas: async () => 100000n, getFeeData: async () => ({ maxFeePerGas: 500000000n }),
    getBalance: async () => 10n ** 18n, getTransactionCount: async () => 4,
    broadcastTransaction: async () => { broadcasts++; return {}; }, getTransactionReceipt: async () => null
  };
  const chain = { provider, contracts: {}, validate: async () => ({ constitution: 'public constitution' }),
    transaction: async () => ({ to: c.contracts.QuorumBoard.address, data: '0x12345678', value: 0n }), proposals: async () => ({ relevant: [], caughtUp: true }) };
  const signer = { address: c.agentAddress, signTransaction: async () => '0x1234' };
  const engine = new Engine({ config: c, chain, signer, state, save: async s => saved.push(JSON.parse(JSON.stringify(s))), model: async () => { throw Error('idle model must not run'); }, log: () => {} });
  return { c, state, saved, provider, chain, signer, engine, broadcasts: () => broadcasts };
}

test('signed transaction and queue removal are durable before broadcast; restart reuses exact bytes', async () => {
  const f = engineFixture(); const plan = { action: 'feedback' }; f.state.queue.push(plan);
  f.provider.broadcastTransaction = async raw => { assert.equal(f.saved.at(-1).pending.raw, raw); assert.equal(f.saved.at(-1).queue.length, 0); throw Error('RPC disconnected after accepting transaction'); };
  await assert.rejects(f.engine.send(plan));
  assert.equal(f.state.pending.nonce, 4); assert.equal(f.state.queue.length, 0);
  f.signer.signTransaction = async () => { throw Error('must not sign again'); };
  const raws = []; f.provider.broadcastTransaction = async raw => raws.push(raw);
  assert.equal(await f.engine.pending(), true); assert.deepEqual(raws, ['0x1234']);
});

test('receipt confirmations and canonical block hash gate success and continuation', async () => {
  const f = engineFixture(); const plan = { action: 'comment', next: { action: 'vote', proposalId: '1' } };
  await f.engine.send(plan);
  f.provider.getTransactionReceipt = async () => ({ status: 1, blockNumber: 155, blockHash: fakeBlocks(155).hash, logs: [] });
  assert.equal(await f.engine.pending(), true); assert.equal(f.state.queue.length, 0);
  f.provider.getTransactionReceipt = async () => ({ status: 1, blockNumber: 140, blockHash: 'orphan', logs: [] });
  assert.equal(await f.engine.pending(), true);
  f.provider.getTransactionReceipt = async () => ({ status: 1, blockNumber: 140, blockHash: fakeBlocks(140).hash, logs: [] });
  assert.equal(await f.engine.pending(), false); assert.equal(f.state.queue[0].action, 'vote'); assert.equal(f.state.receipts.length, 1);
});

test('failed receipt does not continue work or report success, and permits fresh hourly retry', async () => {
  const f = engineFixture(); f.state.lastReadHour = 100;
  await f.engine.send({ action: 'comment', next: { action: 'vote' } });
  f.provider.getTransactionReceipt = async () => ({ status: 0, blockNumber: 140, blockHash: fakeBlocks(140).hash, logs: [] });
  await f.engine.pending(); assert.equal(f.state.queue.length, 0); assert.equal(f.state.lastReadHour, null); assert.equal(f.state.receipts[0].status, 0);
});

test('gas cap and daily bound prevent signing and balance exhaustion', async () => {
  const f = engineFixture(); let signed = 0; f.signer.signTransaction = async () => { signed++; return '0x1234'; };
  f.provider.estimateGas = async () => 300000n;
  await assert.rejects(f.engine.send({ action: 'feedback' }), /transaction limit/); assert.equal(signed, 0);
  f.provider.estimateGas = async () => 100000n; f.c.policy.dailyGasBudgetWei = '1';
  await assert.rejects(f.engine.send({ action: 'feedback' }), /daily gas/); assert.equal(signed, 0);
});

test('idle hour invokes no model and queues only feedback after bounded catch-up', async () => {
  const f = engineFixture(); f.state.cursor = 148; f.state.checkpoints = [{ number: 148, hash: fakeBlocks(148).hash }];
  assert.equal(await f.engine.tick(), 'submitted'); assert.equal(f.state.pending.plan.action, 'feedback');
  assert.equal(f.broadcasts(), 1);
});

test('new confirmed discussion reports read even without a new proposal or model decision', async () => {
  const f = engineFixture();
  f.state.cursor = 148; f.state.checkpoints = [{ number: 148, hash: fakeBlocks(148).hash }];
  f.state.lastContentRevision = '1';
  f.chain.proposals = async () => ({ relevant: [], caughtUp: true, revision: '2' });
  await f.engine.tick();
  assert.equal(f.state.pending.plan.status, 1); assert.equal(f.state.lastContentRevision, '2');
});

test('local signer signs EIP712 project/chain/seat and never exposes key in model context', async () => {
  const dir = await mkdtemp(resolve('test/scratch/signer-'));
  try {
    const c = fixture(); c.privateKeyFile = `${dir}/agent.key`;
    const testKey = '0x' + '11'.repeat(32); await writeFile(c.privateKeyFile, testKey, { mode: 0o600 });
    const signer = await localSigner(c);
    const feedback = { seat: '7', authorizationVersion: 1, generation: 1, hour: 30, anchorBlock: 123, anchorHash: keccak256(toUtf8Bytes('block')), revision: 0, contentHash: keccak256(toUtf8Bytes('content')), status: 0 };
    const domain = { name: 'QUORUM Feedback', version: '1', chainId: 1, verifyingContract: c.contracts.QuorumBoard.address };
    const signature = await signer.signFeedback(feedback);
    assert.equal(verifyTypedData(domain, FEEDBACK_TYPES, feedback, signature), c.agentAddress);
    assert.notEqual(TypedDataEncoder.hash(domain, FEEDBACK_TYPES, feedback), TypedDataEncoder.hash({ ...domain, chainId: 2 }, FEEDBACK_TYPES, feedback));
    assert.throws(() => signer.signFeedback({ ...feedback, seat: '8' }));
    const context = { constitution: 'public', proposals: relevant };
    await modelRequest({ url: 'https://model.example.invalid', name: 'owner-model' }, context, async (_url, options) => {
      assert.equal(options.body.includes(testKey), false); assert.equal(options.body.includes('privateKeyFile'), false);
      return new Response(JSON.stringify({ choices: [{ message: { content: '{"action":"none"}' } }] }), { status: 200 });
    });
  } finally { await rm(dir, { recursive: true }); }
});

test('pinned ABI set loads offline and feedback encoding preserves every authenticated field', async () => {
  const c = fixture(); const k = await contractsFor(c, null);
  const f = { seat: 7, authorizationVersion: 2, generation: 3, hour: 4, anchorBlock: 5, anchorHash: commitment, revision: 6, contentHash: commitment, status: 3 };
  const data = k.QuorumBoard.interface.encodeFunctionData('recordFeedback', [f, '0x' + '00'.repeat(65)]);
  const parsed = k.QuorumBoard.interface.parseTransaction({ data });
  assert.equal(parsed.args[0].seat, 7n); assert.equal(parsed.args[0].authorizationVersion, 2n); assert.equal(parsed.args[0].generation, 3n); assert.equal(parsed.args[0].status, 3n);
});

test('queued decision cannot change meaning after reorg reuses a proposal ID', async () => {
  const c = fixture(); const contracts = {
    QuorumSeats: { getSeat: async () => ({ agent: c.agentAddress, version: 1n }), validAgent: async () => true },
    QuorumGovernance: { getProposal: async () => ({ commitment: keccak256(toUtf8Bytes('other proposal')), end: 100n }) }
  };
  const chain = new Chain(c, {}, contracts);
  await assert.rejects(chain.transaction({ action: 'vote', proposalId: '1', commitment, choice: 1, rationale: 'Original proposal' }, {}), /commitment changed/);
});

test('accepting work does not suppress a later vote, and completed responsibilities do not invoke idle decisions', async () => {
  const c = fixture(), s = newState(c); let voted = false;
  const workHash = keccak256(toUtf8Bytes('exact work'));
  s.decisions['1'] = { action: 'acceptWork', revision: '1' };
  const contracts = {
    QuorumSeats: { getSeat: async () => ({ version: 1n, generation: 1n }) },
    QuorumBoard: { revisionAtBlock: async () => 1n, active: async () => true, getPost: async () => ({ body: 'Readable proposal' }) },
    QuorumGovernance: { proposalCount: async () => 1n, getProposal: async () => ({ executed: false, expires: 999999n, end: 999999n, snapshot: 1n, workHash, postId: 1n, commitment, kind: 1n, electorate: 10n, constitution: c.constitutionHash }), hasVoted: async () => voted, getActions: async () => [] },
    QuorumAssembly: { eligible: async () => true, getAcceptors: async () => [{ seat: 7n, agent: c.agentAddress, version: 1n, generation: 1n }], getWork: async () => ({ deadline: 999999n }) }
  };
  const chain = new Chain(c, { getBlock: async () => fakeBlocks(160) }, contracts);
  let result = await chain.proposals(s, 148);
  assert.equal(result.relevant.length, 1); assert.equal(result.relevant[0].canVote, true); assert.equal(result.relevant[0].canAccept, false);
  voted = true;
  result = await chain.proposals(s, 148); assert.equal(result.relevant.length, 0);
});
