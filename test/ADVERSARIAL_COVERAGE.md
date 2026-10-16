# Additional adversarial Foundry coverage

These tests extend the accepted suite without changing contracts, dependencies, or configuration.
They use the existing local fixture, the vendored Safe 1.5.0 implementation and proxy, and a local
ERC-721 ownership/approval fixture. No RPC, environment mutation, FFI, or network dependency is used.

| File | Properties and failure paths |
| --- | --- |
| `AdversarialParticipation.t.sol` | Independent timestamp-history oracle over 48 hours; completed-hour and activation-second boundaries; 18/24 dormancy/recovery; inclusive anchor-age bounds; same-block and historical content revisions; post/receipt rollback; replay, rotation and expiry. |
| `AdversarialSeatsAndSnapshots.t.sol` | Independent snapshots across exit, dormancy and late enrollment; withdrawal/redeposit generations; preservation of cast votes; vote-duration stake lock; scope enforcement; failed-deposit rollback; unauthorized lifecycle actions; original-owner refunds. |
| `AdversarialGovernance.t.sol` | Atomic vote/receipt failures and retries; closed/duplicate votes; post/nonce/action commitment integrity; major quorum across 1–128 seats; ordinary quorum across 1–31 seats; rounding, abstentions, ties and permissionless execution. |
| `AdversarialWork.t.sol` | Duplicate/capacity-limited acceptors; stale-slot reuse; unauthorized acceptance/revocation; identity, key, exit and consent changes; deadline boundaries; readable specification completeness; chain/registry binding; rejected execution and valid retry. |
| `AdversarialSafeAndHandover.t.sol` | Callback privilege isolation; all Safe configuration entry points; arbitrary Safe self-call selectors; owner-path refunds and approved hashes; module/guard callback checks; both guard slots and runtime identity; bootstrap drift, extra-module pagination, exact founder acceptance and whole-genesis thresholds. |
| `AdversarialCustodyInvariant.t.sol` | Random identity transfers, authorization/consent, revocation, deposits, exits, withdrawals, time, funding, donations and unauthorized transfers. Independent cumulative deposit/refund ledger; exact backing including donations; claim enumeration; token conservation; complete withdrawal after every sequence. |
| `AdversarialTreasuryInvariant.t.sol` | Random voting, time, execution, donations, recipient failures and module attacks across eight competing token/ETH spends. Independent vote/execution/spending ledger; cap enforcement; no replay; exact asset conservation; persistent Safe binding and stake isolation. |

Fuzz properties specify 1,000 runs in their source. Both additional invariant handlers specify
256 runs, depth 64, and failure on unexpected handler reverts. Directed handler tests demonstrate
successful lifecycle transitions and execution/retry, so the invariants are not supported solely
by rejected or skipped actions.

The required reproducible test invocation is:

```sh
FOUNDRY_FUZZ_SEED=0x15c225a1ee53bdf82aad206091ab5aa8a5666954fe7ae77d3e5fb80bd6c48779 forge test
```

Safe storage/runtime fault injection verifies fail-closed policy checks; separate calls test whether
an unauthorized caller can make those changes. Fault injection is not presented as an exploit.
The suite does not establish the existing mainnet Safe's current configuration, historical external
allowances, the canonical NFT/admission dataset, or a real-model founder rehearsal. Those require
the workflow's live verification and acceptance. Work tests exercise declared typed work; they do
not claim the contracts can classify arbitrary natural-language work from calldata.
