#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { JsonRpcProvider, Interface, ZeroHash } from './ethers.min.js';
import { validateConfig, validateProposalActions, check, allowed } from './config.mjs';
import { contractsFor, Chain, localSigner } from './chain.mjs';
import { loadState, saveState, lockState, json, newState } from './store.mjs';
import { modelRequest } from './model.mjs';
import { Engine } from './engine.mjs';

const [command, configPath, input] = process.argv.slice(2);
const commands = ['verify', 'owner-calls', 'once', 'run', 'accept', 'decline', 'exit', 'execute', 'propose', 'spend', 'resync', 'discard'];
if (!commands.includes(command) || !configPath) {
  console.error('Usage: node connector/cli.mjs <verify|owner-calls|once|run|accept|decline|exit|execute ID|propose FILE|spend FILE|resync|discard> CONFIG [ID|FILE]');
  process.exitCode = 1;
} else {
  let unlock; let provider;
  try {
    const base = dirname(resolve(configPath));
    const c = validateConfig(JSON.parse(await readFile(configPath, 'utf8')));
    for (const name of ['stateFile', 'privateKeyFile', 'constitutionFile']) c[name] = resolve(base, c[name]);
    if (c.model?.apiKeyFile) c.model.apiKeyFile = resolve(base, c.model.apiKeyFile);
    provider = new JsonRpcProvider(c.rpcUrl, undefined, { cacheTimeout: -1, batchMaxCount: 1 });
    const contracts = await contractsFor(c, provider);
    const chain = new Chain(c, provider, contracts);
    const setup = await chain.validate(!['verify', 'owner-calls', 'resync', 'discard'].includes(command));
    if (command === 'verify') {
      console.log(json({ verified: true, chainId: c.chainId, agent: c.agentAddress, seat: c.seat, handedOver: setup.handedOver,
        stakeAmount: await contracts.QuorumSeats.stakeAmount(), active: await contracts.QuorumBoard.active(c.seat) }));
    } else if (command === 'owner-calls') {
      const nftAddress = await contracts.QuorumSeats.nft();
      const nftABI = new Interface(['function approve(address,uint256)', 'function ownerOf(uint256) view returns(address)']);
      const stake = await contracts.QuorumSeats.stakeAmount();
      const head = await provider.getBlock('latest');
      const expires = head.timestamp + 30 * 86400;
      const permits = a => c.policy.actions.includes(a);
      const scopes = (permits('feedback') ? 1 : 0) | (['vote','propose','acceptWork'].some(permits) ? 2 : 0) | (['vote','comment','propose'].some(permits) ? 4 : 0) | (permits('requestExit') ? 8 : 0);
      check(scopes > 0, 'Owner signing policy grants no membership scopes');
      console.log(json({ warning: 'Owner must review and submit these calls separately. Exact NFT approval is a transfer fuse; this registry cannot transfer NFTs. Never use setApprovalForAll. Revoke old authority before reapproving a reacquired NFT.',
        calls: [
          { to: nftAddress, data: nftABI.encodeFunctionData('approve', [c.contracts.QuorumSeats.address, c.seat]), value: '0' },
          { to: c.contracts.QuorumSeats.address, data: contracts.QuorumSeats.interface.encodeFunctionData('authorize', [c.seat, c.agentAddress, scopes, expires, (scopes & 8) ? stake : 0]), value: '0' },
          { to: c.contracts.LaunchToken.address, data: contracts.LaunchToken.interface.encodeFunctionData('approve', [c.contracts.QuorumSeats.address, stake]), value: '0' }
        ], afterAgentAcceptance: { to: c.contracts.QuorumSeats.address, data: contracts.QuorumSeats.interface.encodeFunctionData('deposit', [c.seat]), value: '0' } }));
    } else {
      unlock = await lockState(c.stateFile);
      const state = await loadState(c.stateFile, c);
      if (command === 'discard') {
        check(!state.pending, 'A signed pending transaction must be reconciled; discarding local data cannot cancel it');
        state.queue = []; state.lastReadHour = null; await saveState(c.stateFile, state); console.log('Discarded unsigned intents; no onchain authorization changed.');
      } else if (command === 'resync') {
        check(!state.pending && !state.queue.length, 'Preserve and resolve pending transactions before resync');
        await saveState(`${c.stateFile}.backup`, state);
        const reset = newState(c);
        reset.notes = state.notes; reset.gasDay = state.gasDay; reset.gasReserved = state.gasReserved;
        await saveState(c.stateFile, reset);
        console.log('Cursor reset to deployment block; next runs will catch up in bounded batches.');
      } else {
        const signer = await localSigner(c);
        const engine = new Engine({ config: c, chain, signer, state, save: s => saveState(c.stateFile, s), model: modelRequest });
        if (!['once', 'run'].includes(command)) {
          check(!state.pending && state.queue.length === 0, 'Resolve current queue before adding another intent');
          let plan;
          if (command === 'accept') {
            allowed(c, 'accept');
            const decision = await modelRequest(c.model, { task: 'Independently decide whether to accept this exact constitution and an hourly onchain response commitment. You may decline. Return JSON with only action (accept or decline), constitutionHash, hourlyCommitment (boolean), rationale.', constitutionHash: c.constitutionHash, constitution: setup.constitution });
            check(Object.keys(decision).every(k => ['action', 'constitutionHash', 'hourlyCommitment', 'rationale'].includes(k)), 'Unexpected acceptance field');
            check(['accept', 'decline'].includes(decision.action) && decision.constitutionHash === c.constitutionHash && typeof decision.rationale === 'string', 'Model did not explicitly accept or decline the reviewed constitution');
            if (decision.action === 'accept') check(decision.hourlyCommitment === true, 'No hourly commitment accepted');
            else check(decision.hourlyCommitment === false, 'Decline cannot accept the commitment');
            plan = { action: decision.action, constitutionHash: c.constitutionHash, hourlyCommitment: decision.hourlyCommitment };
            state.notes.push({ action: decision.action, rationale: decision.rationale.slice(0, 2048), constitutionHash: c.constitutionHash });
          } else if (command === 'decline') plan = { action: 'decline' };
          else if (command === 'exit') plan = { action: 'requestExit' };
          else if (command === 'execute') {
            check(/^\d+$/.test(input ?? ''), 'Proposal ID required');
            const p = await contracts.QuorumGovernance.getProposal(input);
            plan = { action: 'execute', proposalId: input, commitment: p.commitment };
          } else if (command === 'propose' || command === 'spend') {
            check(input, 'Reviewed proposal JSON file required');
            const spec = JSON.parse(await readFile(resolve(base, input), 'utf8'));
            const kind = command === 'spend' ? 0 : 1;
            if (kind === 0) {
              check(/^\d+$/.test(String(spec.budgetId)) && /^\d+$/.test(String(spec.amount)) && BigInt(spec.amount) > 0n, 'Budget ID and positive amount required');
              spec.calls = (await contracts.QuorumGovernance.spendingAction(spec.budgetId, spec.amount)).map(a => ({target:a.target, value:String(a.value), data:a.data, expectedReturnHash:a.expectedReturnHash}));
            }
            validateProposalActions(c, spec.calls);
            const expectedNonce = String(await contracts.QuorumGovernance.proposalCount() + 1n);
            let workHash = ZeroHash, work;
            if (spec.work) {
              const actionBinding = await contracts.QuorumGovernance.actionBinding(c.seat, expectedNonce, kind, spec.calls, spec.budgetId ?? 0, spec.amount ?? 0, ZeroHash);
              work = { ...spec.work, actionBinding };
              workHash = await contracts.QuorumAssembly.registerWork.staticCall(work);
            }
            const common = { expectedNonce, kind, budgetId: spec.budgetId ?? '0', amount: spec.amount ?? '0', calls: spec.calls, workHash, text: spec.text };
            const post = { ...common, action: 'proposalPost', next: { ...common, action: 'propose' } };
            plan = work ? { ...common, action: 'registerWork', work, next: post } : post;
          }
          state.queue.push(plan); await saveState(c.stateFile, state);
        }
        if (command === 'run') {
          let stopped = false; let failures = 0;
          const stop = () => { stopped = true; };
          process.on('SIGINT', stop); process.on('SIGTERM', stop);
          while (!stopped) {
            try { console.log(await engine.tick()); failures = 0; }
            catch (error) { console.error(`Connector paused this cycle: ${safeMessage(error)}`); if (++failures >= 10) throw new Error('Ten failed cycles; inspect configuration, pending receipts and RPC before restarting'); }
            if (!stopped) await delay(c.pollSeconds * 1000);
          }
        } else console.log(await engine.tick());
      }
    }
  } catch (error) {
    console.error(safeMessage(error)); process.exitCode = 1;
  } finally { if (unlock) await unlock(); if (provider) provider.destroy(); }
}

// Do not print RPC payloads, authorization headers, key material or raw ethers error objects.
function safeMessage(error) {
  if (error?.code) return `Operation failed (${String(error.code).replace(/[^A-Z0-9_]/gi, '').slice(0, 60)}); no confirmed success is assumed`;
  return String(error?.message || 'Operation failed').replace(/0x[0-9a-fA-F]{64,}/g, '[redacted bytes]').slice(0, 300);
}
