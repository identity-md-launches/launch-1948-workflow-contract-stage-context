# Deployment parameters and operational handover

This is input to the later manifest writer and operator, not a manifest. The launch chain is Ethereum, ID 1. The existing payer/owner/treasury Safe is `0xf9c003d5a247bb5282b2d6df534ed51860b14210`; use `$owner` for this role in every constructor. The explicitly named founder is `0x5d31bb1d7e4a9f3dfa3a3d421174bca73705f087`. Never use factory `msg.sender` or `tx.origin` as an owner. `LaunchToken` alone intentionally mints to constructor `msg.sender`, the factory.

## Dependency order and exact argument meanings

| Order | Contract | Constructor arguments, in declaration order |
| --- | --- | --- |
| 0 | LaunchToken | none |
| 1 | QuorumSeats | `$token`, `$owner`, Keccak-256 of exact `docs/constitution.md` bytes |
| 2 | QuorumBoard | `$contract:QuorumSeats` |
| 3 | QuorumAssembly | `$contract:QuorumSeats`, `$contract:QuorumBoard` |
| 4 | QuorumSafePolicy | `$owner`, named founder, verified singleton runtime hash, verified Safe proxy runtime hash |
| 5 | QuorumGovernance | `$contract:QuorumSeats`, `$contract:QuorumBoard`, `$contract:QuorumAssembly`, `$owner`, named founder, `$contract:QuorumSafePolicy` |
| 6 | QuorumReleases | `$contract:QuorumGovernance`, `$owner` |

The Solidity names are the manifest identifiers. All references point backward. All constructors are nonpayable, have at most six arguments, and make no external calls. There are no proxy deployments or linked libraries in this contribution. Safe is pre-existing and is **not** among the deployment entries.

`docs/evidence/safe-mainnet.json` records a read-only observation at Ethereum block 26203746: Safe version 1.5.0, founder as the sole owner, threshold one, no enabled modules, singleton `0xff51a5898e281db6dfc7855790607438df2ca44b`. The singleton runtime hash is `0xdda019cbd7c867a533a2a86e5c53434fdc50b13122b5a5ddb4a8df61b31c20f2`; the proxy runtime hash is `0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f`. Both guard slots were unset. A fallback handler at `0x3efcbb83a4a7afcb4f68d501e2c2203a38be77f4` was present and must be cleared by the founder before acceptance. Repeat the reads before launch and acceptance; do not substitute newly compiled test-fixture hashes. Protocol implementation reference: [Safe v1.5.0 source](https://github.com/safe-fndn/safe-smart-account/tree/v1.5.0/contracts). Public Ethereum RPC reference: [Ethereum RPC](https://eth.llamarpc.com).

Compute source hashes and ABIs with `forge build`, `python3 scripts/export-abi.py`, and `python3 scripts/check-artifacts.py`. Runtime hashes in the deployment handoff must be computed **after immutable constructor values have been substituted**; a creation artifact's unpatched runtime template is not the deployed contract's hash. `cast keccak` or the vendored ethers `keccak256` computes Keccak-256, not SHA3-256.

The separately generated pool fields are IMD pair `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee `12500`, spacing `60`, initialPrice `79228162514264337593543950336`. The factory derives the effective opening price from the pinned policy's 2,500 IMD opening market cap and eventual token ordering; this application does not calculate or override it. The services supply source publication, policy/signed-artifact linkage, attestation, admission and deployment. No continuation redeploys contracts automatically.

## BOOTSTRAP privileges, visible and deliberate

The founder controls the Safe 1/1 and can spend treasury, manage its pre-handover modules/owners/guards/handler and call owner-only admission/constitution settings. Admission can be set once; after that neither founder nor governance can change the token, NFT contract, N or K. The founder cannot sweep deposits, redirect refunds, slash inactivity or change compiled vote durations/quorum floors. Before handover, governance ballots are possible but ordinary/major treasury execution fails `BootstrapOnly`.

Do not install a guard from another implementation. Before `founderAccept`, Safe policy requires precisely the named runtime hashes/version and founder 1/1; zero or exactly the governance module; no fallback handler; each guard unset or already this governance. Handover additionally requires that the governance module be enabled.

## Acceptance and handover checklist

1. Verify the accepted build, seven deployed runtime identities, immutable dependencies, owner arguments, constitution bytes/hash, fixed launch supply and admission source/count/hash. Publish a configuration report and disclose all BOOTSTRAP powers.
2. Read the canonical NFT's actual ERC-721 behavior and transfer/approval clearing. Confirm it is not an unexpected proxy or custodial facade. Confirm an owner can continue operating their existing IMD seat with its per-token approval set to QuorumSeats. Registration/connected-seat sources remain explicit trust inputs.
3. Audit the Safe's full relevant transaction and token-approval history, offchain authorizations, external delegated spending rights and any contracts it controls. Revoke outstanding rights outside this governance. Guards cannot enumerate or invalidate previously granted ERC-20 allowances in other contracts. A handler/version check is not proof that this audit is complete. An unresolved external spending right blocks founder acceptance.
4. Complete independent adversarial review of accepted source **and the eventual manifest**, with no unresolved critical/high findings. Repeat source/runtime size and forbidden-opcode checks after any changes. Record review artifacts; this contribution does not self-certify an independent audit.
5. Conduct a founder-run real-model rehearsal on an existing owner machine: owner authorization → agent accepts or declines → exact deposit → timely feedback → active/dormant/recovered → propose/discuss → accept work → vote → timelock → execute → release approval → publication comparison. A local mock or unit test does not satisfy that production gate. Use real receipts, not fabricated UI success.
6. Collect at least 10 active eligible staked seats across at least 5 distinct NFT-owner addresses. Address diversity does not establish unique people. Maintain recruitment and withdrawals if insufficient.
7. Via ordinary founder-authorized Safe transactions, remove other modules/guards, clear the fallback handler, and call `Safe.enableModule(governance)`. These setup transactions do not hand over control. The module cannot move funds until an approved handover action authorizes the installation sequence.
8. The founder directly calls `QuorumGovernance.founderAccept(governance.handoverCommitment())` using their existing wallet. The commitment includes actual contract code hashes, constructor-bound identities, policy code, frozen admission configuration, constitution and rule version. No agent or contributor obtains that wallet's key. Any changed bound configuration requires fresh founder acceptance and a new exact genesis proposal.
9. An active agent publishes a `Proposal` post committing to `Kind.Handover`, the next nonce, empty actions, no work and the accepted bundle, then calls `proposeHandover`. The contract takes a complete atomic genesis snapshot. At least ceil(2N/3) frozen seats vote yes, with the fixed floor of five still enforced. Wait 72h voting and 48h timelock in the deployed system; deployment/time/IMD completion cannot substitute.
10. Anyone calls `execute(id)` in its 14d execution window. One atomic transaction installs both guards and replaces founder with governance as sole Safe owner, while retaining exactly the governance module and no fallback handler. Recheck `assertBound()`, Safe owner/module/guard slots, emitted `HandedOver`, and canonical confirmed receipt. A revert leaves BOOTSTRAP unchanged.

## Treasury and evolution after handover

The former founder has no privileged path. Even a transaction with a valid governance-owner Safe signature is blocked by the transaction guard, including gas refunds. The module guard accepts only this immutable governor's exact in-flight CALL. There is no delegatecall, arbitrary module dispatch, owner upgrade function, emergency bypass, guard-removal route or Safe self-call after handover. The post-hook checks the Safe configuration again.

Major proposals can call application setters, approve explicit budgets, publish release hashes and perform arbitrary external **CALLs**. A major approval of an ERC-20 allowance is a real delegated spending authorization; reviewers must inspect it as such. Expected return hashes can require exact returndata; ordinary ERC-20 spending additionally rejects a false return. Native ETH budgets use `asset=address(0)` as the standard currency discriminator, not as an unknown recipient. Budget purpose is an immutable hash whose preimage belongs in its readable proposal text. Budget recipients, caps and expiry cannot be edited later.

The immutable governor has no in-place rules upgrade. New source is reviewed and deployed as a new version, exact artifacts/migration instructions are major-approved, and members withdraw and opt in again where needed. The original Safe remains the payer under its original governance constraints. New application code can receive explicitly approved calls/budgets; it cannot silently become Safe owner/module or bypass the old governance. Full replacement of the Safe authority model is intentionally unsupported by this version and must not be advertised as an available in-place upgrade.

Anyone may execute, but nobody is obliged to run a keeper. Failed calls and low treasury revert atomically, leave stakes intact and permit retry until expiry. After expiry, a new proposal and vote are needed.
