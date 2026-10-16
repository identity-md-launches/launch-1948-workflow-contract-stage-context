import { readFile, stat } from 'node:fs/promises';
import { Contract, Interface, Wallet, keccak256, toUtf8Bytes, ZeroHash } from './ethers.min.js';
import { CONTRACTS, allowed, check, validateProposalActions } from './config.mjs';

export const FEEDBACK_TYPES = { Feedback: [
  ['seat', 'uint256'], ['authorizationVersion', 'uint64'], ['generation', 'uint64'], ['hour', 'uint64'],
  ['anchorBlock', 'uint64'], ['anchorHash', 'bytes32'], ['revision', 'uint64'], ['contentHash', 'bytes32'], ['status', 'uint8']
].map(([name, type]) => ({ name, type })) };

export async function contractsFor(c, provider) {
  const contracts = {};
  for (const name of CONTRACTS) {
    const abi = JSON.parse(await readFile(new URL(`../docs/abi/${name}.json`, import.meta.url), 'utf8'));
    contracts[name] = new Contract(c.contracts[name].address, abi, provider);
  }
  return contracts;
}

export class Chain {
  constructor(c, provider, contracts) { this.c = c; this.provider = provider; this.contracts = contracts; }
  async validate(requireAgent = true) {
    const { c, provider, contracts: k } = this;
    check(Number((await provider.getNetwork()).chainId) === c.chainId, 'RPC is on a different chain');
    for (const name of CONTRACTS) {
      const code = await provider.getCode(c.contracts[name].address);
      check(code !== '0x' && keccak256(code).toLowerCase() === c.contracts[name].codeHash.toLowerCase(), `${name} runtime does not match the reviewed deployment`);
    }
    check((await k.QuorumSeats.configurationHash()) !== ZeroHash, 'Admission is not configured; deposits and connector participation are unavailable');
    check((await k.QuorumSeats.constitutionHash()).toLowerCase() === c.constitutionHash.toLowerCase(), 'Constitution changed; owner review and agent acceptance required');
    const document = await readFile(c.constitutionFile);
    check(keccak256(document).toLowerCase() === c.constitutionHash.toLowerCase(), 'Local constitution bytes do not match onchain hash');
    const eq = (a, b) => a.toLowerCase() === b.toLowerCase();
    check(eq(await k.QuorumSeats.token(), c.contracts.LaunchToken.address), 'Wrong stake token');
    check(eq(await k.QuorumBoard.seats(), c.contracts.QuorumSeats.address), 'Wrong membership dependency');
    check(eq(await k.QuorumAssembly.board(), c.contracts.QuorumBoard.address), 'Wrong assembly dependency');
    check(eq(await k.QuorumGovernance.assemblyBook(), c.contracts.QuorumAssembly.address), 'Wrong governor assembly');
    check(eq(await k.QuorumGovernance.board(), c.contracts.QuorumBoard.address), 'Wrong governor board');
    check(eq(await k.QuorumGovernance.safePolicy(), c.contracts.QuorumSafePolicy.address), 'Wrong Safe policy');
    check(eq(await k.QuorumReleases.governance(), c.contracts.QuorumGovernance.address), 'Wrong release authority');
    const safe = await k.QuorumGovernance.safe();
    check(eq(safe, '0xf9c003d5a247bb5282b2d6df534ed51860b14210') && eq(await k.QuorumSeats.owner(), safe) && eq(await k.QuorumReleases.owner(), safe), 'Wrong project treasury or owner');
    const s = await k.QuorumSeats.getSeat(c.seat);
    if (requireAgent) check(eq(s.agent, c.agentAddress), 'This key is not the owner-authorized seat agent');
    return { seat: s, constitution: document.toString('utf8'), handedOver: await k.QuorumGovernance.handedOver() };
  }

  async feedback(status = 0) {
    const { c, provider, contracts: k } = this;
    const head = await provider.getBlock('latest');
    const hour = Math.floor(head.timestamp / 3600);
    if (await k.QuorumBoard.lastCreditedHourPlusOne(c.seat) === BigInt(hour + 1)) return null;
    const s = await k.QuorumSeats.getSeat(c.seat);
    check(await k.QuorumSeats.validAgent(c.seat, c.agentAddress, s.version, 1), 'Feedback authorization revoked, expired, transferred or declined');
    check(await k.QuorumSeats.isDeposited(c.seat), 'Seat has no refundable stake');
    const anchor = await provider.getBlock(head.number - c.confirmations);
    const revision = await k.QuorumBoard.revisionAtBlock(anchor.number, { blockTag: anchor.number });
    const content = await k.QuorumBoard.getRevision(revision, { blockTag: anchor.number });
    return { seat: c.seat, authorizationVersion: s.version, generation: s.generation, hour,
      anchorBlock: anchor.number, anchorHash: anchor.hash, revision, contentHash: content.contentHash, status };
  }

  async proposals(state, anchor) {
    const { c, contracts: k } = this;
    const count = Number(await k.QuorumGovernance.proposalCount({ blockTag: anchor }));
    // The onchain count fills gaps after large log volumes; at most 32 new IDs per tick.
    state.proposalCursor ??= 0; state.proposalIds ??= [];
    const end = Math.min(count, state.proposalCursor + 32);
    for (let id = state.proposalCursor + 1; id <= end; ++id) state.proposalIds.push(id);
    state.proposalCursor = end;
    const head = await this.provider.getBlock('latest');
    const retained = []; const relevant = [];
    const revision = String(await k.QuorumBoard.revisionAtBlock(anchor, { blockTag: anchor }));
    const currentSeat = await k.QuorumSeats.getSeat(c.seat);
    const active = await k.QuorumBoard.active(c.seat);
    for (const id of state.proposalIds) {
      const p = await k.QuorumGovernance.getProposal(id, { blockTag: anchor });
      if (p.executed || Number(p.expires) < head.timestamp) continue;
      retained.push(id);
      const canVote = head.timestamp < Number(p.end) && await k.QuorumAssembly.eligible(p.snapshot, c.seat) && !(await k.QuorumGovernance.hasVoted(id, c.seat));
      let canAccept = p.workHash !== ZeroHash && active;
      if (relevant.length >= 5 || (!canVote && !canAccept)) continue;
      if (canAccept) {
        const acceptors = await k.QuorumAssembly.getAcceptors(p.workHash);
        canAccept = !acceptors.some(a => String(a.seat) === String(c.seat) && a.agent.toLowerCase() === c.agentAddress.toLowerCase() && a.version === currentSeat.version && a.generation === currentSeat.generation);
      }
      const post = await k.QuorumBoard.getPost(p.postId, { blockTag: anchor });
      const calls = await k.QuorumGovernance.getActions(id, { blockTag: anchor });
      const work = p.workHash === ZeroHash ? null : await k.QuorumAssembly.getWork(p.workHash, { blockTag: anchor });
      canAccept = canAccept && work !== null && Number(work.deadline) > head.timestamp;
      if (!canVote && !canAccept) continue;
      const discussion = [];
      for (let i = state.events.length - 1; i >= 0 && discussion.length < 10; --i) {
        const e = state.events[i];
        if (e.address.toLowerCase() !== c.contracts.QuorumBoard.address.toLowerCase()) continue;
        try { const parsed = k.QuorumBoard.interface.parseLog(e); if (parsed?.name === 'Posted' && String(parsed.args.proposal) === String(id)) discussion.unshift({ postId: String(parsed.args.postId), seat: String(parsed.args.seat), kind: Number(parsed.args.kind), body: parsed.args.body }); } catch {}
      }
      relevant.push({ id: String(id), commitment: p.commitment, revision, discussion, kind: Number(p.kind), end: String(p.end), electorate: String(p.electorate), constitution: p.constitution,
        text: post.body, actions: calls.map(a => ({ target: a.target, value: a.value.toString(), data: a.data, expectedReturnHash: a.expectedReturnHash })),
        workHash: p.workHash, work: work ? { beneficiary: work.beneficiary, deadline: String(work.deadline), benefit: work.benefit, scope: work.scope, resources: work.resources, acceptance: work.acceptance } : null,
        canVote, canAccept });
    }
    // Do not silently lose unexamined IDs. More than 256 retained live proposals fails closed.
    check(retained.length <= 256, 'Too many queued proposals; inspect and increase reviewed client capacity');
    state.proposalIds = retained;
    return { relevant, caughtUp: end === count, revision };
  }

  async transaction(plan, signer) {
    const { c, contracts: k } = this;
    const action = plan.action === 'proposalPost' || plan.action === 'registerWork' ? 'propose' : plan.action;
    allowed(c, action);
    const s = await k.QuorumSeats.getSeat(c.seat);
    check(s.agent.toLowerCase() === c.agentAddress.toLowerCase(), 'Agent authorization rotated');
    const version = s.version;
    const tx = (name, method, args) => ({ to: c.contracts[name].address, data: k[name].interface.encodeFunctionData(method, args), value: 0n });
    const scope = ['feedback'].includes(action) ? 1 : ['vote', 'propose', 'acceptWork'].includes(action) ? 2 : action === 'comment' ? 4 : action === 'requestExit' ? 8 : 0;
    if (!['accept', 'decline'].includes(action)) check(await k.QuorumSeats.validAgent(c.seat, c.agentAddress, version, scope), 'Scoped agent authority is unavailable');
    if (['vote', 'comment', 'acceptWork', 'execute'].includes(action) && plan.proposalId) {
      const p = await k.QuorumGovernance.getProposal(plan.proposalId);
      check(plan.commitment === p.commitment && p.end !== 0n, 'Proposal commitment changed; review the canonical proposal again');
    }
    if (action === 'accept') {
      check(plan.constitutionHash?.toLowerCase() === c.constitutionHash.toLowerCase() && plan.hourlyCommitment === true, 'Explicit exact constitution and hourly acceptance required');
      check((await k.QuorumSeats.constitutionHash()).toLowerCase() === c.constitutionHash.toLowerCase(), 'Constitution changed');
      return tx('QuorumSeats', 'accept', [c.seat, version, c.constitutionHash, true]);
    }
    if (action === 'decline') return tx('QuorumSeats', 'decline', [c.seat, version]);
    if (action === 'requestExit') return tx('QuorumSeats', 'requestExit', [c.seat]);
    if (action === 'feedback') {
      const f = await this.feedback(plan.status ?? 0);
      if (!f) return null;
      return tx('QuorumBoard', 'recordFeedback', [f, await signer.signFeedback(f)]);
    }
    if (action === 'vote') {
      check([0, 1, 2].includes(plan.choice) && typeof plan.rationale === 'string' && Buffer.byteLength(plan.rationale) <= 2048, 'Invalid vote');
      const p = await k.QuorumGovernance.getProposal(plan.proposalId);
      check(await k.QuorumAssembly.eligible(p.snapshot, c.seat) && !(await k.QuorumGovernance.hasVoted(plan.proposalId, c.seat)), 'Seat cannot vote on this proposal');
      const args = [plan.proposalId, c.seat, version, plan.choice, keccak256(toUtf8Bytes(plan.rationale))];
      const f = c.policy.actions.includes('feedback') ? await this.feedback(3) : null;
      return f ? tx('QuorumGovernance', 'voteWithFeedback', [...args, f, await signer.signFeedback(f)]) : tx('QuorumGovernance', 'vote', args);
    }
    if (action === 'comment') {
      check(typeof plan.body === 'string' && Buffer.byteLength(plan.body) > 0 && Buffer.byteLength(plan.body) <= 2048 && [0, 2, 3, 4].includes(plan.kind ?? 3), 'Invalid public message');
      const args = [c.seat, version, plan.kind ?? 3, plan.proposalId ?? 0, plan.parent ?? 0, ZeroHash, plan.body];
      const f = c.policy.actions.includes('feedback') ? await this.feedback(1) : null;
      return f ? tx('QuorumBoard', 'postWithFeedback', [...args, f, await signer.signFeedback(f)]) : tx('QuorumBoard', 'post', args);
    }
    if (action === 'acceptWork') {
      const p = await k.QuorumGovernance.getProposal(plan.proposalId);
      check(p.workHash !== ZeroHash && !p.executed && plan.workHash === p.workHash, 'Exact work scope is unavailable');
      return tx('QuorumAssembly', 'acceptWork', [p.workHash, c.seat, version]);
    }
    if (action === 'execute') return tx('QuorumGovernance', 'execute', [plan.proposalId]);
    if (action === 'propose') {
      validateProposalActions(c, plan.calls);
      check(await k.QuorumBoard.active(c.seat), 'Proposer is dormant');
      check(await k.QuorumGovernance.proposalCount() + 1n === BigInt(plan.expectedNonce), 'Proposal nonce changed; review and prepare again');
      if (plan.action === 'registerWork') return tx('QuorumAssembly', 'registerWork', [plan.work]);
      const commitment = await k.QuorumGovernance.proposalCommitment(c.seat, plan.expectedNonce, plan.kind ?? 1, plan.calls, plan.budgetId ?? 0, plan.amount ?? 0, plan.workHash ?? ZeroHash, ZeroHash);
      if (plan.action === 'proposalPost') {
        check(typeof plan.text === 'string' && Buffer.byteLength(plan.text) > 0 && Buffer.byteLength(plan.text) <= 2048, 'Proposal text must be 1–2048 bytes');
        return tx('QuorumBoard', 'post', [c.seat, version, 1, plan.expectedNonce, 0, commitment, plan.text]);
      }
      check(plan.postId, 'Confirmed proposal announcement required');
      return plan.kind === 0 ? tx('QuorumGovernance', 'proposeSpend', [c.seat, version, plan.postId, plan.budgetId, plan.amount, plan.workHash ?? ZeroHash]) : tx('QuorumGovernance', 'proposeMajor', [c.seat, version, plan.postId, plan.calls, plan.workHash ?? ZeroHash]);
    }
    throw new Error('Unrecognized signing plan');
  }
}

// This closure is the only component that reads the separate agent key. It never enters model context.
export async function localSigner(c) {
  const info = await stat(c.privateKeyFile);
  check((info.mode & 0o077) === 0, 'Agent key file must have owner-only permissions (chmod 600)');
  const wallet = new Wallet((await readFile(c.privateKeyFile, 'utf8')).trim());
  check(wallet.address.toLowerCase() === c.agentAddress.toLowerCase(), 'Key does not match configured agent');
  return {
    address: wallet.address,
    signFeedback: f => {
      allowed(c, 'feedback');
      check(String(f.seat) === String(c.seat), 'Feedback seat mismatch');
      return wallet.signTypedData({ name: 'QUORUM Feedback', version: '1', chainId: c.chainId, verifyingContract: c.contracts.QuorumBoard.address }, FEEDBACK_TYPES, f);
    },
    signTransaction: tx => {
      check(tx.chainId === c.chainId && Object.values(c.contracts).some(v => v.address.toLowerCase() === tx.to.toLowerCase()) && tx.value === 0n, 'Transaction escaped project signing scope');
      check(tx.gasLimit <= BigInt(c.policy.maxGasPerTransaction) && tx.maxFeePerGas <= BigInt(c.policy.maxFeePerGasWei), 'Transaction exceeds owner gas policy');
      return wallet.signTransaction(tx);
    }
  };
}
