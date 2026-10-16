// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumAssembly, QuorumGovernance} from "./Fixtures.sol";

contract AdversarialWorkTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(17);
    }

    function _spec(bytes32 binding, uint64 deadline) internal pure returns (QuorumAssembly.Work memory) {
        return QuorumAssembly.Work(
            binding,
            _owner(4),
            deadline,
            "Publish a usable artifact",
            "Maintain the approved site",
            "Owner-authorized local compute",
            "Reproducible build and acceptance tests pass"
        );
    }

    function _register() internal returns (bytes32) {
        return
            assemblyBook.registerWork(
                _spec(keccak256("exact action"), uint64(vm.getBlockTimestamp() + 30 days))
            );
    }

    function _accept(bytes32 hash, uint256 seat) internal {
        uint64 version = seats.getSeat(seat).version;
        vm.prank(seats.getSeat(seat).agent);
        assemblyBook.acceptWork(hash, seat, version);
    }

    function testAcceptingTwiceDoesNotOccupyTwoSlotsAndStaleSlotIsReusable() public {
        bytes32 hash = _register();
        for (uint256 seat = 1; seat <= 16; ++seat) {
            _accept(hash, seat);
        }
        _accept(hash, 1);
        assertEq(assemblyBook.getAcceptors(hash).length, 16);
        vm.expectRevert("AcceptorLimit");
        vm.prank(_agent(17));
        assemblyBook.acceptWork(hash, 17, 1);
        vm.prank(_owner(8));
        assemblyBook.revokeAcceptance(hash, 8);
        _accept(hash, 17);
        QuorumAssembly.Acceptance[] memory acceptors = assemblyBook.getAcceptors(hash);
        assertEq(acceptors.length, 16);
        uint256 count17;
        for (uint256 i; i < acceptors.length; ++i) {
            if (acceptors[i].seat == 17) ++count17;
            assertNotEq(acceptors[i].seat, 8);
        }
        assertEq(count17, 1);
        assertTrue(assemblyBook.workAccepted(hash));
    }

    function testLastValidAcceptorControlsGateAndUnknownCallerCannotRevoke() public {
        bytes32 hash = _register();
        assertFalse(assemblyBook.workAccepted(hash));
        _accept(hash, 1);
        _accept(hash, 2);
        vm.expectRevert("AcceptanceUnauthorized");
        vm.prank(_agent(3));
        assemblyBook.revokeAcceptance(hash, 1);
        vm.prank(_agent(1));
        assemblyBook.revokeAcceptance(hash, 1);
        assertTrue(assemblyBook.workAccepted(hash));
        vm.prank(_owner(2));
        assemblyBook.revokeAcceptance(hash, 2);
        assertFalse(assemblyBook.workAccepted(hash));
        _accept(hash, 2);
        assertTrue(assemblyBook.workAccepted(hash));
        assertEq(assemblyBook.getAcceptors(hash).length, 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AcceptanceInvalidatedByIdentityAndAuthorizationChanges(uint8 mutationSeed) public {
        bytes32 hash = _register();
        _accept(hash, 2);
        uint256 mutation = bound(mutationSeed, 0, 5);
        if (mutation == 0) {
            vm.prank(_owner(2));
            seats.revoke(2);
        } else if (mutation == 1) {
            vm.prank(_owner(2));
            nft.transferFrom(_owner(2), _owner(3), 2);
        } else if (mutation == 2) {
            vm.prank(_owner(2));
            seats.requestExit(2);
        } else if (mutation == 3) {
            vm.prank(_agent(2));
            seats.decline(2, 1);
        } else if (mutation == 4) {
            address agent = _agent(2);
            vm.prank(_owner(2));
            seats.authorize(2, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
            vm.prank(agent);
            seats.accept(2, 2, CONSTITUTION, true);
        } else {
            vm.prank(_owner(2));
            nft.approve(address(0), 2);
        }
        assertFalse(assemblyBook.workAccepted(hash), "stale acceptance survived authority loss");
        _accept(hash, 3);
        assertTrue(assemblyBook.workAccepted(hash), "independent member could not take responsibility");
    }

    function testUnknownWorkDormantAndUnacceptedAgentsCannotAccept() public {
        vm.expectRevert("WorkUnavailable");
        vm.prank(_agent(1));
        assemblyBook.acceptWork(keccak256("unregistered"), 1, 1);
        bytes32 hash = _register();
        vm.expectRevert("AcceptorInactive");
        assemblyBook.acceptWork(hash, 1, 1);
        vm.prank(_agent(1));
        seats.decline(1, 1);
        vm.expectRevert("AcceptorInactive");
        vm.prank(_agent(1));
        assemblyBook.acceptWork(hash, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        vm.expectRevert("AcceptorInactive");
        vm.prank(_agent(2));
        assemblyBook.acceptWork(hash, 2, 1);
        assertFalse(assemblyBook.workAccepted(hash));
    }

    function testWorkDeadlineIsStrictAtAcceptanceAndExecutionValidation() public {
        uint64 deadline = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes32 binding = keccak256("deadline-bound action");
        QuorumAssembly.Work memory work = _spec(binding, deadline);
        bytes32 hash = assemblyBook.registerWork(work);
        assertTrue(assemblyBook.validateWork(hash, binding, deadline - 1));
        assertFalse(assemblyBook.validateWork(hash, binding, deadline));
        assertFalse(assemblyBook.validateWork(hash, keccak256("other action"), deadline - 1));
        vm.warp(deadline - 1);
        _accept(hash, 1);
        assertTrue(assemblyBook.workAccepted(hash));
        vm.warp(deadline);
        assertFalse(assemblyBook.workAccepted(hash));
        vm.expectRevert("WorkUnavailable");
        vm.prank(_agent(2));
        assemblyBook.acceptWork(hash, 2, 1);
    }

    function testIncompleteAndDuplicateSpecificationsRejected() public {
        QuorumAssembly.Work memory work = _spec(keccak256("action"), uint64(vm.getBlockTimestamp() + 30 days));
        bytes32 hash = assemblyBook.registerWork(work);
        vm.expectRevert("WorkAlreadyRegistered");
        assemblyBook.registerWork(work);
        work.scope = "";
        vm.expectRevert("WorkIncomplete");
        assemblyBook.registerWork(work);
        work.scope = string(new bytes(2049));
        vm.expectRevert("WorkTooLong");
        assemblyBook.registerWork(work);
        work.scope = "fixed scope";
        work.deadline = uint64(vm.getBlockTimestamp());
        vm.expectRevert("WorkInvalid");
        assemblyBook.registerWork(work);
        assertEq(assemblyBook.getWork(hash).scope, "Maintain the approved site");
        assertFalse(assemblyBook.workAccepted(hash));
    }

    function testWorkHashBindsEveryReadableFieldChainAndRegistry() public {
        QuorumAssembly.Work memory work = _spec(keccak256("action"), uint64(vm.getBlockTimestamp() + 30 days));
        bytes32 original = assemblyBook.registerWork(work);
        work.acceptance = "Different success criteria";
        bytes32 changed = assemblyBook.registerWork(work);
        assertNotEq(original, changed);
        _accept(original, 1);
        assertFalse(assemblyBook.workAccepted(changed));
        vm.chainId(2);
        bytes32 crossChain = assemblyBook.registerWork(work);
        assertNotEq(changed, crossChain);
        assertFalse(assemblyBook.workAccepted(crossChain));
        vm.chainId(1);
        QuorumAssembly other = new QuorumAssembly(address(seats), address(board));
        bytes32 crossRegistry = other.registerWork(work);
        assertNotEq(changed, crossRegistry);
        assertFalse(other.workAccepted(crossRegistry));
    }
}

contract AdversarialWorkExecutionTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
        _handover();
        _hours(10, 18);
    }

    function _proposal(uint64 deadline) internal returns (uint256 id, bytes32 hash) {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (23)));
        bytes32 binding =
            gov.actionBinding(1, gov.proposalCount() + 1, QuorumGovernance.Kind.Major, calls, 0, 0, 0);
        hash = assemblyBook.registerWork(
            QuorumAssembly.Work(
                binding,
                _owner(4),
                deadline,
                "Usable result",
                "Exact implementation",
                "Existing compute",
                "Tests pass"
            )
        );
        id = _major(1, calls, hash);
    }

    function testRevokedAcceptanceBlocksApprovedExecutionAndFreshAcceptanceAllowsRetry() public {
        (uint256 id, bytes32 hash) = _proposal(uint64(vm.getBlockTimestamp() + 30 days));
        vm.prank(_agent(2));
        assemblyBook.acceptWork(hash, 2, 1);
        _yes(id, 7);
        vm.prank(_owner(2));
        assemblyBook.revokeAcceptance(hash, 2);
        vm.warp(gov.getProposal(id).executableAt);
        vm.expectRevert(QuorumGovernance.WorkAcceptanceRequired.selector);
        gov.execute(id);
        assertFalse(gov.getProposal(id).executed);
        assertEq(gov.executingProposal(), 0);
        assertEq(target.value(), 0);
        _hours(10, 18);
        vm.prank(_agent(3));
        assemblyBook.acceptWork(hash, 3, 1);
        gov.execute(id);
        assertEq(target.value(), 23);
        assertTrue(gov.getProposal(id).executed);
    }

    function testExpiredWorkBlocksEvenUnexpiredApprovedProposal() public {
        uint64 deadline = uint64(vm.getBlockTimestamp() + 6 days);
        (uint256 id, bytes32 hash) = _proposal(deadline);
        vm.prank(_agent(2));
        assemblyBook.acceptWork(hash, 2, 1);
        _yes(id, 7);
        assertLt(deadline, gov.getProposal(id).expires);
        vm.warp(deadline);
        vm.expectRevert(QuorumGovernance.WorkAcceptanceRequired.selector);
        gov.execute(id);
        assertEq(target.value(), 0);
        assertFalse(gov.getProposal(id).executed);
    }

    function testWorkMustOutliveEarliestPossibleExecution() public {
        uint64 deadline = uint64(vm.getBlockTimestamp() + 5 days);
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (23)));
        bytes32 binding =
            gov.actionBinding(1, gov.proposalCount() + 1, QuorumGovernance.Kind.Major, calls, 0, 0, 0);
        bytes32 hash = assemblyBook.registerWork(
            QuorumAssembly.Work(binding, _owner(4), deadline, "Benefit", "Scope", "Resources", "Criteria")
        );
        uint256 postId = _post(1, QuorumGovernance.Kind.Major, calls, 0, 0, hash, 0);
        uint256 beforeCount = gov.proposalCount();
        vm.expectRevert(QuorumGovernance.WorkBindingInvalid.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, hash);
        assertEq(gov.proposalCount(), beforeCount);
        assertFalse(gov.usedPost(postId));
    }
}
