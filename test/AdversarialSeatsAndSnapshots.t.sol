// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumSeats, QuorumBoard, QuorumGovernance} from "./Fixtures.sol";

contract AdversarialSeatsAndSnapshotsTest is Fixtures {
    function _rotate(uint256 seat, uint256 nextKey, uint8 scopes) internal returns (uint64 version) {
        address next = vm.addr(nextKey);
        vm.prank(seats.getSeat(seat).depositor);
        seats.authorize(seat, next, scopes, uint64(vm.getBlockTimestamp() + 30 days), K);
        version = seats.getSeat(seat).version;
        vm.prank(next);
        seats.accept(seat, version, CONSTITUTION, true);
    }

    function testTwoSnapshotsStayIndependentAcrossExitDormancyAndLateEntry() public {
        _active(10);
        (uint256 first, uint32 firstCount,) = assemblyBook.snapshot();
        assertEq(firstCount, 10);
        vm.prank(_owner(2));
        seats.requestExit(2);
        _enroll(11);
        _hours(11, 24);
        // Seat 3 stops responding; continue everybody else for seven completed hours.
        for (uint256 h; h < 7; ++h) {
            _anchor();
            for (uint256 seat = 1; seat <= 11; ++seat) {
                if (seat != 3) _receipt(seat);
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        (uint256 second, uint32 secondCount,) = assemblyBook.snapshot();
        assertEq(secondCount, 9);
        assertTrue(assemblyBook.eligible(first, 2), "exit changed an existing electorate");
        assertTrue(assemblyBook.eligible(first, 3), "dormancy changed an existing electorate");
        assertFalse(assemblyBook.eligible(first, 11), "late entrant inserted into old electorate");
        assertFalse(assemblyBook.eligible(second, 2));
        assertFalse(assemblyBook.eligible(second, 3));
        assertTrue(assemblyBook.eligible(second, 11));
        (address creator,, uint32 count,) = assemblyBook.snapshots(first);
        assertEq(creator, address(this));
        assertEq(count, 10);
        assertEq(assemblyBook.snapshotCount(), 2);
    }

    function testWithdrawAndRedepositCannotRecycleFrozenElectorateOrAttendance() public {
        _active(1);
        (uint256 oldSnapshot,,) = assemblyBook.snapshot();
        uint64 oldGeneration = seats.getSeat(1).generation;
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(seats.getSeat(1).exitAt);
        seats.withdraw(1);
        assertFalse(assemblyBook.eligible(oldSnapshot, 1));
        address agent = _agent(1);
        vm.startPrank(_owner(1));
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        token.approve(address(seats), K);
        vm.stopPrank();
        uint64 version = seats.getSeat(1).version;
        vm.prank(agent);
        seats.accept(1, version, CONSTITUTION, true);
        vm.prank(_owner(1));
        seats.deposit(1);
        assertEq(seats.getSeat(1).generation, oldGeneration + 1);
        assertFalse(assemblyBook.eligible(oldSnapshot, 1));
        assertEq(board.completedHours(1), 0);
        assertFalse(board.active(1));
        _hours(1, 24);
        (uint256 fresh, uint32 count,) = assemblyBook.snapshot();
        assertEq(count, 1);
        assertTrue(assemblyBook.eligible(fresh, 1));
        assertFalse(assemblyBook.eligible(oldSnapshot, 1), "fresh stake revived an old snapshot");
    }

    function testRevokeAndTransferDoNotEraseVotesAlreadyCast() public {
        _active(10);
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _yes(id, 5);
        vm.prank(_owner(2));
        seats.revoke(2);
        vm.prank(_owner(3));
        nft.transferFrom(_owner(3), _owner(4), 3);
        vm.prank(_owner(4));
        seats.requestExit(4);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        assertEq(gov.getProposal(id).yes, 5);
        assertTrue(gov.passed(id));
        assertEq(gov.getProposal(id).electorate, 10);
        assertTrue(gov.hasVoted(id, 2));
        assertTrue(gov.hasVoted(id, 3));
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        _vote(id, 2, QuorumGovernance.Choice.No);
    }

    function testExitDelayCoversWholeVoteAndNeverShortensOnRepeatedRequests() public {
        _active(10);
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _vote(id, 1, QuorumGovernance.Choice.No);
        vm.prank(_owner(1));
        seats.requestExit(1);
        uint64 exitAt = seats.getSeat(1).exitAt;
        assertGe(exitAt, gov.getProposal(id).end);
        vm.expectRevert("ExitInvalid");
        vm.prank(_owner(1));
        seats.requestExit(1);
        assertEq(seats.getSeat(1).exitAt, exitAt);
        vm.warp(gov.getProposal(id).end - 1);
        vm.expectRevert("ExitPending");
        seats.withdraw(1);
        vm.warp(exitAt);
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K, "voting or dissent reduced refund");
        assertEq(gov.getProposal(id).no, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AuthorizationScopesCannotExpandAcrossEntryPoints(uint8 rawScopes) public {
        _enroll(1);
        uint8 scopes = uint8(bound(rawScopes, 1, 15));
        uint256 key = _key(99);
        uint64 version = _rotate(1, key, scopes);
        address agent = vm.addr(key);
        for (uint8 bit = 1; bit <= 8; bit *= 2) {
            assertEq(seats.validAgent(1, agent, version, bit), (scopes & bit) != 0);
        }
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, key);
        if ((scopes & 1) == 0) vm.expectRevert("FeedbackUnauthorized");
        board.recordFeedback(f, sig);
        if ((scopes & 4) == 0) vm.expectRevert("PostUnauthorized");
        vm.prank(agent);
        board.post(1, version, QuorumBoard.PostKind.Discussion, 0, 0, 0, "scoped discussion");
        if ((scopes & 8) == 0) vm.expectRevert("ExitUnauthorized");
        vm.prank(agent);
        seats.requestExit(1);
    }

    function test_FailedTokenDepositRestoresEnumerationGenerationAndAccounting() public {
        _enroll(1);
        nft.mint(2, _owner(2));
        token.transfer(_owner(2), K);
        address agent = _agent(2);
        vm.startPrank(_owner(2));
        nft.approve(address(seats), 2);
        seats.authorize(2, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        token.approve(address(seats), K - 1);
        vm.stopPrank();
        vm.prank(agent);
        seats.accept(2, 1, CONSTITUTION, true);
        vm.expectRevert("TokenCallFailed");
        vm.prank(_owner(2));
        seats.deposit(2);
        assertEq(seats.totalDeposited(), K);
        assertEq(seats.depositedCount(), 1);
        assertEq(seats.depositedSeatAt(0), 1);
        assertFalse(seats.isDeposited(2));
        assertEq(seats.getSeat(2).generation, 0);
        assertEq(seats.getSeat(2).activationAt, 0);
        assertEq(token.balanceOf(_owner(2)), K);
        vm.prank(_owner(2));
        token.approve(address(seats), K);
        vm.prank(agent);
        seats.deposit(2);
        assertEq(seats.getSeat(2).generation, 1);
        assertEq(seats.totalDeposited(), 2 * K);
    }

    function testForeignOwnerCannotRevokeRotateDeclineOrRequestExit() public {
        _enroll(1);
        address attacker = _owner(2);
        address attackerAgent = _agent(2);
        vm.startPrank(attacker);
        vm.expectRevert("OnlySeatOwner");
        seats.revoke(1);
        vm.expectRevert("OwnerOrApproval");
        seats.authorize(1, attackerAgent, 15, uint64(vm.getBlockTimestamp() + 1 days), K);
        vm.expectRevert("UnauthorizedAgent");
        seats.decline(1, 1);
        vm.expectRevert("ExitUnauthorized");
        seats.requestExit(1);
        vm.stopPrank();
        assertTrue(seats.validAgent(1, _agent(1), 1, 15));
        assertEq(seats.getSeat(1).exitAt, 0);
    }

    function testAgentDeclineBlocksFeedbackDiscussionAndNewSnapshotsButRefundSurvives() public {
        _active(1);
        vm.prank(_agent(1));
        seats.decline(1, 1);
        assertFalse(board.active(1));
        (, uint32 count,) = assemblyBook.snapshot();
        assertEq(count, 0);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        vm.expectRevert("FeedbackUnauthorized");
        board.recordFeedback(f, sig);
        vm.expectRevert("PostUnauthorized");
        vm.prank(_agent(1));
        board.post(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "declined");
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(seats.getSeat(1).exitAt);
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K);
    }

    function testReleasedAgentKeyCanBeReusedWithoutRevivingOldSeat() public {
        _enrollN(2);
        address key = _agent(1);
        vm.prank(_owner(1));
        seats.revoke(1);
        vm.prank(_owner(2));
        seats.authorize(2, key, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.prank(key);
        seats.accept(2, 2, CONSTITUTION, true);
        assertTrue(seats.validAgent(2, key, 2, 15));
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(seats.getSeat(1).exitAt);
        seats.withdraw(1);
        assertTrue(seats.validAgent(2, key, 2, 15), "old withdrawal deleted another seat's key");
        assertFalse(seats.validAgent(1, key, 1, 15));
        assertEq(seats.totalDeposited(), K);
    }
}
