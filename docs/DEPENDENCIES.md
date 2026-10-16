# Vendored dependency provenance

No package manager, submodule or network access is needed to build/test this checkout once Solidity 0.8.26 and Node 22+ are present.

| Dependency | Pin and source | Delivered files / use | License |
| --- | --- | --- | --- |
| forge-std | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `vendor/forge-std/src`, test assertions and cheatcode interfaces only | MIT and Apache-2.0, both included |
| Safe Smart Account | [safe-fndn/safe-smart-account v1.5.0](https://github.com/safe-fndn/safe-smart-account/tree/v1.5.0) | `vendor/safe/contracts`, actual Safe/proxy used by integration tests; not project deployment entries | LGPL-3.0, included |
| ethers | [ethers-io/ethers.js v6.15.0](https://github.com/ethers-io/ethers.js/tree/v6.15.0) | `connector/ethers.min.js`, ESM build from the versioned npm distribution, with `ETHERS-LICENSE.md` | MIT |

Safe's transaction and module guard ABIs were checked against its pinned source, including its guard storage slots, return-data module path and fallback behavior. [Safe guard documentation](https://docs.safe.global/advanced/smart-account-guards/smart-account-guard-tutorial) explains that the ordinary transaction guard does not cover the module path; this implementation implements both interfaces. Production Safe identities were additionally read from Ethereum, as recorded in `docs/evidence/safe-mainnet.json`.

Application sources have no OpenZeppelin dependency. The fixed-supply ERC-20 is small and tested; optional-return token calls, ECDSA low-s checking and a storage reentrancy lock are internal code with no external library linking. Safe integration tests compile the pinned third-party source using this project's 0.8.26 compiler, rather than claiming their test runtime is the production 0.7.6-built singleton. Production policy hashes come from the observed deployed code.

The supplied eth-security and eth-addresses documents were checklist/reference inputs. Their source text is not redistributed in this deliverable and their address tables were not copied as deployment parameters. No machine configuration, environment credentials, node_modules tree or compiler binary is included.
