// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, Safe, Enum, QuorumGovernance, QuorumSafePolicy} from "./Fixtures.sol";

contract PermissiveGuardForTest {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
    function checkTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata,
        address
    ) external pure {}
    function checkAfterExecution(bytes32, bool) external pure {}

    function checkModuleTransaction(address, uint256, bytes calldata, uint8, address)
        external
        pure
        returns (bytes32)
    {
        return keccak256("permissive fixture guard");
    }
    function checkAfterModuleExecution(bytes32, bool) external pure {}
}

/// @dev Runs as an actual external target during an approved Safe CALL; it has no prank privileges.
contract CallbackBypassProbe {
    Safe public immutable safe;
    QuorumGovernance public immutable gov;
    uint256 public successes;
    uint256 public attempts;

    constructor(Safe safe_, QuorumGovernance gov_) {
        safe = safe_;
        gov = gov_;
    }

    function _try(address target, bytes memory payload) internal {
        ++attempts;
        (bool success,) = target.call(payload);
        if (success) ++successes;
    }

    function probe(uint256 executingId) external {
        _try(address(gov), abi.encodeCall(gov.execute, (executingId)));
        _try(address(safe), abi.encodeCall(safe.enableModule, (address(this))));
        _try(address(safe), abi.encodeCall(safe.setGuard, (address(0))));
        _try(address(safe), abi.encodeCall(safe.setModuleGuard, (address(0))));
        _try(address(safe), abi.encodeCall(safe.setFallbackHandler, (address(this))));
        _try(
            address(safe),
            abi.encodeCall(safe.execTransactionFromModule, (address(this), 0, bytes(""), Enum.Operation.Call))
        );
        _try(
            address(safe),
            abi.encodeCall(
                safe.execTransactionFromModuleReturnData,
                (address(this), 0, bytes(""), Enum.Operation.DelegateCall)
            )
        );
        _try(
            address(gov),
            abi.encodeCall(gov.checkModuleTransaction, (address(this), 0, bytes(""), uint8(0), address(gov)))
        );
        _try(address(gov), abi.encodeCall(gov.checkAfterModuleExecution, (bytes32(0), true)));
        _try(
            address(gov),
            abi.encodeCall(
                gov.approveBudget,
                (address(0), address(this), 1, keccak256("bypass"), uint64(block.timestamp + 1 days))
            )
        );
    }
}

contract AdversarialSafeTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
        _handover();
        _hours(10, 18);
    }

    function testApprovedCallbackCannotInheritSafeOrGovernanceAuthority() public {
        CallbackBypassProbe probe = new CallbackBypassProbe(safe, gov);
        uint256 expectedId = gov.proposalCount() + 1;
        uint256 id = _major(1, _call(address(probe), abi.encodeCall(probe.probe, (expectedId))), 0);
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
        gov.execute(id);
        assertEq(probe.attempts(), 10);
        assertEq(probe.successes(), 0, "callback escaped its approved call");
        assertTrue(gov.getProposal(id).executed);
        assertEq(gov.executingProposal(), 0);
        assertEq(gov.budgetCount(), 0);
        gov.assertBound();
    }

    function testEverySafeConfigurationEntryPointRejectsFormerFounder() public {
        bytes[] memory payloads = new bytes[](9);
        payloads[0] = abi.encodeCall(safe.enableModule, (address(target)));
        payloads[1] = abi.encodeCall(safe.disableModule, (address(1), address(gov)));
        payloads[2] = abi.encodeCall(safe.setGuard, (address(0)));
        payloads[3] = abi.encodeCall(safe.setModuleGuard, (address(0)));
        payloads[4] = abi.encodeCall(safe.setFallbackHandler, (address(target)));
        payloads[5] = abi.encodeCall(safe.addOwnerWithThreshold, (founder, 1));
        payloads[6] = abi.encodeCall(safe.removeOwner, (address(1), address(gov), 1));
        payloads[7] = abi.encodeCall(safe.swapOwner, (address(1), address(gov), founder));
        payloads[8] = abi.encodeCall(safe.changeThreshold, (1));
        for (uint256 i; i < payloads.length; ++i) {
            vm.prank(founder);
            (bool ok, bytes memory reason) = address(safe).call(payloads[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSignature("Error(string)", "GS031"));
        }
        vm.expectRevert("GS030");
        vm.prank(founder);
        safe.approveHash(keccak256("unapproved Safe transaction"));
        address[] memory owners = new address[](1);
        owners[0] = founder;
        vm.expectRevert("GS200");
        safe.setup(owners, 1, address(0), bytes(""), address(0), address(0), 0, payable(address(0)));
        gov.assertBound();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SafeSelfCallsRejectedForAnySelectorAndValue(
        bytes4 selector,
        uint96 value,
        bytes32 payload
    ) public {
        QuorumGovernance.Action[] memory calls = _call(address(safe), abi.encodePacked(selector, payload));
        calls[0].value = value;
        vm.expectRevert(QuorumGovernance.ActionInvalid.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, 0, calls, 0);
        assertEq(gov.proposalCount(), 1);
        gov.assertBound();
    }

    function testOwnerPathCannotUseRefundsEvenWithPreapprovedGovernanceSignature() public {
        bytes32 txHash = safe.getTransactionHash(
            address(target),
            0,
            abi.encodeCall(target.set, (99)),
            Enum.Operation.Call,
            100000,
            20000,
            1,
            address(token),
            payable(founder),
            safe.nonce()
        );
        // Stronger than the public attacker's capabilities: even the current owner's approved hash
        // and an unprivileged submitting caller cannot get past the transaction guard.
        vm.prank(address(gov));
        safe.approveHash(txHash);
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(address(gov)))), bytes32(0), uint8(1));
        uint256 nonce = safe.nonce();
        token.transfer(address(safe), 1 ether);
        uint256 beforeBalance = token.balanceOf(address(safe));
        vm.expectRevert(QuorumGovernance.OwnerPathDisabled.selector);
        vm.prank(founder);
        safe.execTransaction(
            address(target),
            0,
            abi.encodeCall(target.set, (99)),
            Enum.Operation.Call,
            100000,
            20000,
            1,
            address(token),
            payable(founder),
            sig
        );
        assertEq(token.balanceOf(address(safe)), beforeBalance);
        assertEq(token.balanceOf(founder), 0);
        assertEq(safe.nonce(), nonce);
        assertEq(target.value(), 0);
    }

    function testGuardCallbacksRequireSafeAndCannotBeForgedOutOfOrder() public {
        vm.expectRevert(QuorumGovernance.OnlySafe.selector);
        gov.checkTransaction(
            address(target), 0, bytes(""), 0, 0, 0, 0, address(0), payable(address(0)), bytes(""), founder
        );
        vm.expectRevert(QuorumGovernance.OnlySafe.selector);
        gov.checkAfterExecution(bytes32(0), true);
        vm.expectRevert(QuorumGovernance.OnlyGovernanceModule.selector);
        vm.prank(address(safe));
        gov.checkModuleTransaction(address(target), 0, bytes(""), 0, founder);
        vm.expectRevert(QuorumGovernance.ModulePathDisabled.selector);
        vm.prank(address(safe));
        gov.checkModuleTransaction(address(target), 0, bytes(""), 0, address(gov));
        vm.expectRevert(QuorumGovernance.ModuleCallbackInvalid.selector);
        vm.prank(address(safe));
        gov.checkAfterModuleExecution(bytes32(0), true);
        gov.assertBound();
    }

    function testPolicyDetectsEitherGuardRemovedAndRejectsExecutionWithoutPartialEffects() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (9))), 0);
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
        bytes32[2] memory slots = [safePolicy.GUARD_SLOT(), safePolicy.MODULE_GUARD_SLOT()];
        for (uint256 i; i < slots.length; ++i) {
            // Fault injection tests the policy check; direct removal is tested separately above.
            bytes32 original = vm.load(address(safe), slots[i]);
            vm.store(address(safe), slots[i], bytes32(0));
            vm.expectRevert(QuorumSafePolicy.GovernanceGuardChanged.selector);
            gov.execute(id);
            assertFalse(gov.getProposal(id).executed);
            assertEq(gov.executingProposal(), 0);
            assertEq(target.value(), 0);
            vm.store(address(safe), slots[i], original);
        }
        gov.execute(id);
        assertEq(target.value(), 9);
        gov.assertBound();
    }

    function testChangedSingletonAndProxyRuntimeFailClosed() public {
        bytes memory singletonCode = address(singleton).code;
        // Keep the ABI usable so this reaches the identity hash check itself.
        vm.etch(address(singleton), bytes.concat(singletonCode, hex"00"));
        vm.expectRevert(QuorumSafePolicy.SafeCodeChanged.selector);
        gov.assertBound();
        vm.etch(address(singleton), singletonCode);
        bytes memory proxyCode = address(safe).code;
        vm.etch(address(safe), hex"00");
        vm.expectRevert(QuorumSafePolicy.SafeCodeChanged.selector);
        gov.assertBound();
        vm.etch(address(safe), proxyCode);
        gov.assertBound();
    }
}

contract AdversarialHandoverTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
    }

    function _readyHandover() internal returns (uint256 id) {
        id = _handoverProposal();
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
    }

    function testOnlyFounderCanAcceptExactBundleAndAcceptanceDoesNotTransferControl() public {
        bytes32 bundle = gov.handoverCommitment();
        vm.expectRevert(QuorumGovernance.OnlyBootstrapFounder.selector);
        gov.founderAccept(bundle);
        vm.expectRevert(QuorumGovernance.BundleMismatch.selector);
        vm.prank(founder);
        gov.founderAccept(keccak256("different bundle"));
        vm.prank(founder);
        gov.founderAccept(bundle);
        assertEq(gov.founderAcceptance(), bundle);
        assertFalse(gov.handedOver());
        assertEq(safe.getOwners()[0], founder);
        vm.expectRevert(QuorumGovernance.BootstrapOnly.selector);
        gov.assertBound();
    }

    function testModuleRemovedAfterGenesisVoteBlocksHandoverAndRestorationAllowsRetry() public {
        uint256 id = _readyHandover();
        _ownerCall(address(safe), abi.encodeCall(safe.disableModule, (address(1), address(gov))));
        vm.expectRevert(QuorumSafePolicy.EnableGovernanceModule.selector);
        gov.execute(id);
        assertFalse(gov.handedOver());
        assertFalse(gov.getProposal(id).executed);
        assertEq(safe.getOwners()[0], founder);
        _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (address(gov))));
        vm.prank(_owner(4));
        gov.execute(id);
        gov.assertBound();
    }

    function testAdditionalModulesCannotHideBeyondPagination() public {
        uint256 id = _readyHandover();
        for (uint256 i = 1; i <= 3; ++i) {
            _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (_agent(i))));
        }
        vm.expectRevert(QuorumSafePolicy.UnexpectedModule.selector);
        gov.execute(id);
        assertFalse(gov.handedOver());
        assertFalse(gov.getProposal(id).executed);
    }

    function testFallbackInstalledAfterFounderAcceptanceBlocksHandover() public {
        uint256 id = _readyHandover();
        _ownerCall(address(safe), abi.encodeCall(safe.setFallbackHandler, (address(target))));
        vm.expectRevert(QuorumSafePolicy.FallbackForbidden.selector);
        gov.execute(id);
        assertFalse(gov.handedOver());
        _ownerCall(address(safe), abi.encodeCall(safe.setFallbackHandler, (address(0))));
        gov.execute(id);
        gov.assertBound();
    }

    function testForeignTransactionGuardAndModuleGuardBlockFounderAcceptance() public {
        PermissiveGuardForTest guard = new PermissiveGuardForTest();
        bytes32 bundle = gov.handoverCommitment();
        _ownerCall(address(safe), abi.encodeCall(safe.setGuard, (address(guard))));
        vm.expectRevert(QuorumSafePolicy.UnexpectedGuard.selector);
        vm.prank(founder);
        gov.founderAccept(bundle);
        _ownerCall(address(safe), abi.encodeCall(safe.setGuard, (address(0))));
        _ownerCall(address(safe), abi.encodeCall(safe.setModuleGuard, (address(guard))));
        vm.expectRevert(QuorumSafePolicy.UnexpectedGuard.selector);
        vm.prank(founder);
        gov.founderAccept(bundle);
        assertEq(gov.founderAcceptance(), bytes32(0));
    }

    function testChangedOwnerSetAfterApprovalBlocksHandoverWithoutChangingFrozenVote() public {
        uint256 id = _readyHandover();
        _ownerCall(address(safe), abi.encodeCall(safe.addOwnerWithThreshold, (_owner(1), 1)));
        vm.expectRevert(QuorumSafePolicy.BootstrapOwners.selector);
        gov.execute(id);
        assertEq(gov.getProposal(id).yes, 7);
        assertEq(gov.getProposal(id).electorate, 10);
        assertFalse(gov.getProposal(id).executed);
        assertFalse(gov.handedOver());
    }

    function testGenesisAbstentionsAndDormancyCannotReduceWholeElectorateApprovalThreshold() public {
        uint256 id = _handoverProposal();
        _yes(id, 6);
        for (uint256 seat = 7; seat <= 10; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.Abstain);
        }
        assertFalse(gov.passed(id));
        vm.warp(gov.getProposal(id).executableAt);
        assertFalse(board.active(1));
        assertEq(gov.getProposal(id).electorate, 10);
        vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
        assertFalse(gov.handedOver());
    }

    function testApprovedNonHandoverActionCannotSpendDuringBootstrap() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (123))), 0);
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
        vm.expectRevert(QuorumGovernance.BootstrapOnly.selector);
        gov.execute(id);
        assertFalse(gov.getProposal(id).executed);
        assertEq(target.value(), 0);
        assertEq(safe.getOwners()[0], founder);
    }
}
