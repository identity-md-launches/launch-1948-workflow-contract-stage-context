// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumGovernance, QuorumAssembly, QuorumSafePolicy, Enum} from "./Fixtures.sol";

contract ExtraDebitToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount + 1;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReenterTarget {
    QuorumGovernance public gov;
    uint256 public other;
    bool public entered;

    constructor(QuorumGovernance gov_) {
        gov = gov_;
    }

    function setOther(uint256 id) external {
        other = id;
    }

    function attack() external returns (bool) {
        (entered,) = address(gov).call(abi.encodeCall(gov.execute, (other)));
        return true;
    }
}

contract TreasuryAndReleasesTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
        _handover();
        _hours(10, 18);
    }

    function _approve(uint256 id) internal {
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
    }

    function testPermissionlessExecutionFailureRollbackRetryAndNoDoubleExecution() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (42)));
        calls[0].expectedReturnHash = keccak256(abi.encode(true));
        uint256 id = _major(1, calls, 0);
        _approve(id);
        target.setFailure(true);
        vm.expectRevert(QuorumGovernance.SafeExecutionFailed.selector);
        gov.execute(id);
        assertFalse(gov.getProposal(id).executed);
        assertEq(gov.executingProposal(), 0);
        target.setFailure(false);
        vm.prank(_owner(3));
        gov.execute(id);
        assertEq(target.value(), 42);
        vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
    }

    function testExecutionBoundToDeploymentChain() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (42))), 0);
        _approve(id);
        vm.chainId(2);
        vm.expectRevert(QuorumGovernance.WrongChain.selector);
        gov.execute(id);
        vm.chainId(1);
        gov.execute(id);
        assertEq(target.value(), 42);
    }

    function testExternalTargetCannotReenterAnotherReadyExecution() public {
        ReenterTarget attacker = new ReenterTarget(gov);
        uint256 first = _major(1, _call(address(attacker), abi.encodeCall(attacker.attack, ())), 0);
        uint256 second = _major(2, _call(address(target), abi.encodeCall(target.set, (9))), 0);
        attacker.setOther(second);
        _yes(first, 7);
        _yes(second, 7);
        vm.warp(gov.getProposal(first).executableAt);
        gov.execute(first);
        assertFalse(attacker.entered());
        assertFalse(gov.getProposal(second).executed);
        gov.execute(second);
        assertEq(target.value(), 9);
    }

    function testBatchAtomicityAndReturnValueCheck() public {
        QuorumGovernance.Action[] memory calls = new QuorumGovernance.Action[](2);
        calls[0] = QuorumGovernance.Action(address(target), 0, abi.encodeCall(target.set, (10)), 0);
        calls[1] = QuorumGovernance.Action(
            address(target), 0, abi.encodeCall(target.returnFalse, ()), keccak256(abi.encode(true))
        );
        uint256 id = _major(1, calls, 0);
        _approve(id);
        vm.expectRevert(QuorumGovernance.UnexpectedReturn.selector);
        gov.execute(id);
        assertEq(target.value(), 0);
        assertFalse(gov.getProposal(id).executed);
    }

    function testWorkMustBeExplicitlyAcceptedWithExactActionBindingAndCanBeRevoked() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (23)));
        bytes32 binding =
            gov.actionBinding(1, gov.proposalCount() + 1, QuorumGovernance.Kind.Major, calls, 0, 0, 0);
        QuorumAssembly.Work memory work = QuorumAssembly.Work(
            binding,
            _owner(1),
            uint64(vm.getBlockTimestamp() + 30 days),
            "Publicly usable result",
            "Implement the accepted feature",
            "Voluntary existing owner-authorized compute",
            "Tests pass and exact source is published"
        );
        bytes32 hash = assemblyBook.registerWork(work);
        uint256 id = _major(1, calls, hash);
        _approve(id);
        vm.expectRevert(QuorumGovernance.WorkAcceptanceRequired.selector);
        gov.execute(id);
        _hours(10, 18);
        vm.prank(_agent(2));
        assemblyBook.acceptWork(hash, 2, 1);
        assertTrue(assemblyBook.workAccepted(hash));
        vm.prank(_owner(2));
        assemblyBook.revokeAcceptance(hash, 2);
        assertFalse(assemblyBook.workAccepted(hash));
        vm.prank(_agent(3));
        assemblyBook.acceptWork(hash, 3, 1);
        gov.execute(id);
        assertEq(target.value(), 23);
    }

    function testWorkForDifferentNonceCannotAuthorizeProposal() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (23)));
        QuorumAssembly.Work memory work = QuorumAssembly.Work(
            keccak256("wrong proposal"),
            _owner(1),
            uint64(vm.getBlockTimestamp() + 30 days),
            "Benefit",
            "Scope",
            "Resources",
            "Acceptance"
        );
        bytes32 hash = assemblyBook.registerWork(work);
        uint256 postId = _post(1, QuorumGovernance.Kind.Major, calls, 0, 0, hash, 0);
        vm.expectRevert(QuorumGovernance.WorkBindingInvalid.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, hash);
    }

    function _budget(address asset, uint256 amount, uint64 expiry) internal returns (uint256) {
        uint256 id = _major(
            1,
            _call(
                address(gov),
                abi.encodeCall(gov.approveBudget, (asset, _owner(4), amount, keccak256("storage"), expiry))
            ),
            0
        );
        _approve(id);
        gov.execute(id);
        _hours(10, 18);
        return gov.budgetCount();
    }

    function _spend(uint256 seat, uint256 budgetId, uint256 amount) internal returns (uint256) {
        QuorumGovernance.Action[] memory calls = gov.spendingAction(budgetId, amount);
        uint256 postId = _post(seat, QuorumGovernance.Kind.Ordinary, calls, budgetId, amount, 0, 0);
        vm.prank(_agent(seat));
        return gov.proposeSpend(seat, 1, postId, budgetId, amount, 0);
    }

    function testOrdinaryBudgetCapsRecipientPurposeDelayAndInsufficientTreasury() public {
        vm.expectRevert(QuorumGovernance.OnlyMajorExecution.selector);
        gov.approveBudget(
            address(0), _owner(4), 1 ether, keccak256("storage"), uint64(vm.getBlockTimestamp() + 30 days)
        );
        uint256 budgetId = _budget(address(0), 2 ether, uint64(vm.getBlockTimestamp() + 30 days));
        uint256 id = _spend(1, budgetId, 1 ether);
        QuorumGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.end - p.start, 48 hours);
        assertEq(p.executableAt - p.end, 24 hours);
        _yes(id, 3);
        _vote(id, 4, QuorumGovernance.Choice.No);
        _vote(id, 5, QuorumGovernance.Choice.Abstain);
        assertTrue(gov.passed(id));
        vm.warp(p.executableAt);
        vm.expectRevert(QuorumGovernance.SafeExecutionFailed.selector);
        gov.execute(id);
        (,,, uint256 spent,,) = gov.budgets(budgetId);
        assertEq(spent, 0);
        vm.deal(address(safe), 2 ether);
        uint256 beforeBalance = _owner(4).balance;
        gov.execute(id);
        assertEq(_owner(4).balance - beforeBalance, 1 ether);
        (,,, spent,,) = gov.budgets(budgetId);
        assertEq(spent, 1 ether);
        assertEq(token.balanceOf(address(seats)), seats.totalDeposited());
    }

    function testCompetingSpendsCannotExceedMajorBudgetAndExpiryIsEnforced() public {
        uint256 budgetId = _budget(address(token), 100, uint64(vm.getBlockTimestamp() + 30 days));
        token.transfer(address(safe), 100);
        uint256 first = _spend(1, budgetId, 80);
        uint256 second = _spend(2, budgetId, 80);
        _yes(first, 5);
        _yes(second, 5);
        vm.warp(gov.getProposal(first).executableAt);
        gov.execute(first);
        vm.expectRevert(QuorumGovernance.BudgetUnavailable.selector);
        gov.execute(second);
        assertEq(token.balanceOf(_owner(4)), 80);
        (,,, uint256 spent,,) = gov.budgets(budgetId);
        assertEq(spent, 80);
        assertFalse(gov.getProposal(second).executed);
    }

    function testFeeOrExtraDebitTokenCannotEscapeApprovedAmount() public {
        ExtraDebitToken extra = new ExtraDebitToken();
        uint256 budgetId = _budget(address(extra), 10, uint64(vm.getBlockTimestamp() + 30 days));
        extra.mint(address(safe), 100);
        uint256 id = _spend(1, budgetId, 10);
        _yes(id, 5);
        vm.warp(gov.getProposal(id).executableAt);
        vm.expectRevert(QuorumGovernance.InexactBudgetTransfer.selector);
        gov.execute(id);
        assertEq(extra.balanceOf(address(safe)), 100);
        assertEq(extra.balanceOf(_owner(4)), 0);
        (,,, uint256 spent,,) = gov.budgets(budgetId);
        assertEq(spent, 0);
    }

    function testBudgetExpiryCanPreventAnOtherwiseApprovedSpend() public {
        uint256 budgetId = _budget(address(0), 1 ether, uint64(vm.getBlockTimestamp() + 8 days));
        uint256 id = _spend(1, budgetId, 1 ether);
        _yes(id, 5);
        vm.warp(gov.getProposal(id).executableAt);
        vm.deal(address(safe), 1 ether);
        vm.expectRevert(QuorumGovernance.BudgetUnavailable.selector);
        gov.execute(id);
        assertEq(address(safe).balance, 1 ether);
    }

    function testOfficialReleaseRequiresMajorExecutionAndObservationIsNotApproval() public {
        bytes32 source = keccak256("source");
        bytes32 build = keccak256("build");
        bytes32 site = keccak256("site");
        bytes32 connector = keccak256("connector");
        vm.expectRevert("OnlyMajorExecution");
        releases.approveRelease(source, build, site, connector, 0, "ipfs://fixture-manifest");
        uint256 id = _major(
            1,
            _call(
                address(releases),
                abi.encodeCall(
                    releases.approveRelease,
                    (source, build, site, connector, bytes32(0), "ipfs://fixture-manifest")
                )
            ),
            0
        );
        _approve(id);
        gov.execute(id);
        bytes32 release = releases.currentRelease();
        assertEq(releases.getRelease(release).siteHash, site);
        assertEq(releases.getRelease(release).proposal, id);
        vm.prank(_owner(5));
        releases.observePublication(
            release, keccak256("unapproved publication"), "ipfs://untrusted-observation"
        );
        assertEq(releases.currentRelease(), release);
        assertEq(releases.getRelease(release).siteHash, site);
    }

    function testExpiredProposalCannotExecuteAndDoesNotTrapProposerForever() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _yes(id, 7);
        vm.warp(gov.getProposal(id).expires + 1);
        vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
        _hours(10, 18);
        uint256 next = _major(1, _call(address(target), abi.encodeCall(target.set, (2))), 0);
        assertGt(next, id);
    }

    function testAllSafeSelfMutationCallsRejectedEvenByMajorProposal() public {
        bytes[] memory payloads = new bytes[](8);
        payloads[0] = abi.encodeWithSignature("setGuard(address)", address(0));
        payloads[1] = abi.encodeWithSignature("setModuleGuard(address)", address(0));
        payloads[2] = abi.encodeWithSignature("enableModule(address)", address(target));
        payloads[3] = abi.encodeWithSignature("disableModule(address,address)", address(1), address(gov));
        payloads[4] = abi.encodeWithSignature("setFallbackHandler(address)", address(target));
        payloads[5] = abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", founder, 1);
        payloads[6] =
            abi.encodeWithSignature("swapOwner(address,address,address)", address(1), address(gov), founder);
        payloads[7] = abi.encodeWithSignature("changeThreshold(uint256)", 1);
        for (uint256 i; i < payloads.length; ++i) {
            QuorumGovernance.Action[] memory calls = _call(address(safe), payloads[i]);
            vm.expectRevert(QuorumGovernance.ActionInvalid.selector);
            vm.prank(_agent(1));
            gov.proposeMajor(1, 1, 0, calls, 0);
        }
        gov.assertBound();
    }

    function testOwnerPathCannotBypassEvenWithGovernanceOwnerPrevalidatedSignature() public {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(address(gov)))), bytes32(0), uint8(1));
        vm.expectRevert(QuorumGovernance.OwnerPathDisabled.selector);
        vm.prank(address(gov));
        safe.execTransaction(
            address(target),
            0,
            abi.encodeCall(target.set, (77)),
            Enum.Operation.Call,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            sig
        );
        vm.expectRevert(QuorumGovernance.OwnerPathDisabled.selector);
        vm.prank(address(gov));
        safe.execTransaction(
            address(target),
            0,
            abi.encodeCall(target.set, (77)),
            Enum.Operation.DelegateCall,
            0,
            0,
            1,
            address(0),
            payable(founder),
            sig
        );
        assertEq(target.value(), 0);
    }

    function testModulePathsDelegatecallAndUnsolicitedGuardCallbacksRejected() public {
        vm.expectRevert("GS104");
        vm.prank(founder);
        safe.execTransactionFromModule(address(target), 0, bytes(""), Enum.Operation.Call);
        vm.expectRevert(QuorumGovernance.ModulePathDisabled.selector);
        vm.prank(address(gov));
        safe.execTransactionFromModule(address(target), 0, bytes(""), Enum.Operation.Call);
        vm.expectRevert(QuorumGovernance.ModulePathDisabled.selector);
        vm.prank(address(gov));
        safe.execTransactionFromModuleReturnData(address(target), 0, bytes(""), Enum.Operation.DelegateCall);
        vm.expectRevert(QuorumGovernance.OnlyGovernanceModule.selector);
        gov.checkModuleTransaction(address(target), 0, bytes(""), 0, address(gov));
        vm.expectRevert(QuorumGovernance.ModuleCallbackInvalid.selector);
        gov.checkAfterModuleExecution(0, true);
        vm.expectRevert("GS031");
        vm.prank(founder);
        safe.setGuard(address(0));
        vm.expectRevert("GS031");
        vm.prank(founder);
        safe.setModuleGuard(address(0));
        gov.assertBound();
    }

    function testFounderNoLongerOwnerAndSafeSimulationCannotPersistDelegatecall() public {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(founder))), bytes32(0), uint8(1));
        vm.expectRevert("GS026");
        vm.prank(founder);
        safe.execTransaction(
            address(target),
            0,
            abi.encodeCall(target.set, (99)),
            Enum.Operation.Call,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            sig
        );
        vm.expectRevert();
        safe.simulateAndRevert(address(target), abi.encodeCall(target.set, (99)));
        gov.assertBound();
        assertEq(target.value(), 0);
        bytes32 hash = gov.handoverCommitment();
        vm.expectRevert(QuorumGovernance.OnlyBootstrapFounder.selector);
        vm.prank(founder);
        gov.founderAccept(hash);
    }
}

contract SafeBootstrapChecksTest is Fixtures {
    function testUnexpectedModuleGuardHandlerOwnerAndVersionBlockAcceptance() public {
        _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (address(target))));
        bytes32 hash = gov.handoverCommitment();
        vm.expectRevert(QuorumSafePolicy.UnexpectedModule.selector);
        vm.prank(founder);
        gov.founderAccept(hash);
        _ownerCall(address(safe), abi.encodeCall(safe.disableModule, (address(1), address(target))));
        _ownerCall(address(safe), abi.encodeCall(safe.setFallbackHandler, (address(target))));
        vm.expectRevert(QuorumSafePolicy.FallbackForbidden.selector);
        vm.prank(founder);
        gov.founderAccept(hash);
        _ownerCall(address(safe), abi.encodeCall(safe.setFallbackHandler, (address(0))));
        _ownerCall(address(safe), abi.encodeCall(safe.addOwnerWithThreshold, (_owner(1), 1)));
        vm.expectRevert(QuorumSafePolicy.BootstrapOwners.selector);
        vm.prank(founder);
        gov.founderAccept(hash);
    }
}
