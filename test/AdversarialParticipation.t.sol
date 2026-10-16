// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumBoard, QuorumSeats} from "./Fixtures.sol";

contract AdversarialParticipationTest is Fixtures {
    function _attendanceState(uint256 seat) internal view returns (bytes32) {
        (uint64 hour, uint64 version, uint64 generation, uint32 mask) = board.attendance(seat);
        return keccak256(abi.encode(hour, version, generation, mask, board.lastCreditedHourPlusOne(seat)));
    }

    function _reject(QuorumBoard.Feedback memory f, string memory reason) internal {
        bytes memory sig = _signature(f, _key(f.seat));
        bytes32 beforeState = _attendanceState(f.seat);
        vm.expectRevert(bytes(reason));
        board.recordFeedback(f, sig);
        assertEq(_attendanceState(f.seat), beforeState, "invalid receipt changed attendance");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RollingAttendanceMatchesTimestampHistory(uint64 pattern, uint16 offsetSeed) public {
        uint256 offset = bound(offsetSeed, 0, 3599);
        vm.warp(vm.getBlockTimestamp() + offset);
        _enroll(1);
        uint256 activation = seats.getSeat(1).activationAt;
        uint256[48] memory creditedHours;
        uint256 receipts;
        // The oracle stores individual hours; it does not duplicate the production bitmap.
        for (uint256 step; step < 48; ++step) {
            uint256 hour = vm.getBlockTimestamp() / 1 hours;
            _anchor();
            uint256 beforeCount = board.completedHours(1);
            if ((uint256(pattern) & (uint256(1) << step)) != 0) {
                _receipt(1);
                creditedHours[receipts++] = hour;
                assertEq(board.completedHours(1), beforeCount, "unfinished hour counted");
            }
            vm.warp((hour + 1) * 1 hours);
            uint256 expected;
            for (uint256 j; j < receipts; ++j) {
                if (creditedHours[j] < hour + 1 && creditedHours[j] + 24 >= hour + 1) ++expected;
            }
            assertEq(board.completedHours(1), expected, "rolling history diverged");
            assertEq(board.active(1), vm.getBlockTimestamp() >= activation && expected >= 18);
            vm.warp(vm.getBlockTimestamp() + offset);
        }
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        assertEq(board.completedHours(1), 0, "old bitmap survived a full empty window");
        assertFalse(board.active(1));
    }

    function testActivationUsesElapsedSecondsWhileAttendanceUsesCompletedHours() public {
        vm.warp(vm.getBlockTimestamp() + 3599);
        _enroll(1);
        uint256 activation = seats.getSeat(1).activationAt;
        _hours(1, 18);
        vm.warp(activation - 1);
        assertEq(board.completedHours(1), 18);
        assertFalse(board.active(1));
        vm.warp(activation);
        assertTrue(board.active(1));
        vm.warp(activation + 1);
        assertEq(board.completedHours(1), 17, "oldest completed hour did not expire");
        assertFalse(board.active(1));
    }

    function testSixMissedHoursRemainActiveSeventhDormantAndRecoveryNeedsCompletion() public {
        _active(1);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        assertEq(board.completedHours(1), 18);
        assertTrue(board.active(1));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 17);
        assertFalse(board.active(1));
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _hours(1, 17);
        _anchor();
        _receipt(1);
        assertEq(board.completedHours(1), 17);
        assertFalse(board.active(1));
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours - 1);
        assertFalse(board.active(1));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(board.completedHours(1), 18);
        assertTrue(board.active(1));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ConfirmedAnchorInclusiveBounds(uint16 ageSeed) public {
        _enroll(1);
        vm.roll(vm.getBlockNumber() + 300);
        uint256 age = bound(ageSeed, 0, 257);
        QuorumBoard.Feedback memory f = _feedback(1);
        f.anchorBlock = uint64(vm.getBlockNumber() - age);
        f.anchorHash = keccak256(abi.encode("anchor age", age));
        if (age > 0 && age <= 256) vm.setBlockhash(f.anchorBlock, f.anchorHash);
        if (age < 12 || age > 128) {
            _reject(f, "AnchorAge");
        } else {
            board.recordFeedback(f, _signature(f, _key(1)));
            assertEq(board.lastCreditedHourPlusOne(1), f.hour + 1);
        }
    }

    function testRevisionLookupUsesLastPostInAnchorBlockAndAcceptsHistoricalContent() public {
        _enroll(1);
        vm.roll(vm.getBlockNumber() + 20);
        uint64 postBlock = uint64(vm.getBlockNumber());
        vm.startPrank(_agent(1));
        board.post(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "first same-block post");
        board.post(1, 1, QuorumBoard.PostKind.Reply, 0, 1, 0, "second same-block post");
        vm.stopPrank();
        assertEq(board.revisionAtBlock(postBlock - 1), 0);
        assertEq(board.revisionAtBlock(postBlock), 2);
        vm.roll(uint256(postBlock) + 12);
        vm.setBlockhash(postBlock, keccak256("confirmed post block"));
        vm.prank(_agent(1));
        board.post(1, 1, QuorumBoard.PostKind.Opinion, 0, 0, 0, "new, not yet confirmed");
        QuorumBoard.Feedback memory f = _feedback(1);
        assertEq(f.revision, 2);
        f.revision = 1;
        f.contentHash = board.getRevision(1).contentHash;
        _reject(f, "ContentRevision");
        f.revision = 3;
        f.contentHash = board.getRevision(3).contentHash;
        _reject(f, "ContentRevision");
        f = _feedback(1);
        f.contentHash = keccak256("fabricated content");
        _reject(f, "ContentRevision");
        _receipt(1);
        assertEq(board.latestRevision(), 3);
        assertEq(board.lastCreditedHourPlusOne(1), f.hour + 1);
    }

    function test_FailedPiggybackPostRollsBackReceiptAndRevisionThenCanRetry() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        bytes32 beforeState = _attendanceState(1);
        vm.expectRevert("MessageLength");
        vm.prank(_agent(1));
        board.postWithFeedback(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "", f, sig);
        assertEq(_attendanceState(1), beforeState);
        assertEq(board.postCount(), 0);
        assertEq(board.latestRevision(), 0);
        vm.expectRevert("PostUnauthorized");
        board.postWithFeedback(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "unauthorized caller", f, sig);
        assertEq(_attendanceState(1), beforeState);
        vm.prank(_agent(1));
        board.postWithFeedback(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "valid retry", f, sig);
        assertEq(board.postCount(), 1);
        assertEq(board.latestRevision(), 1);
        assertEq(board.lastCreditedHourPlusOne(1), f.hour + 1);
    }

    function testDirectReceiptThenPiggybackCannotCreateSecondCreditOrPartialPost() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        board.recordFeedback(f, sig);
        vm.expectRevert("AlreadyCredited");
        vm.prank(_agent(1));
        board.postWithFeedback(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "duplicate", f, sig);
        assertEq(board.postCount(), 0);
        vm.prank(_agent(1));
        board.post(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "standalone discussion still works");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 1);
    }

    function testPendingSignatureDiesOnRotationAndFreshSignatureCannotBorrowHistory() public {
        _active(1);
        _anchor();
        QuorumBoard.Feedback memory old = _feedback(1);
        bytes memory oldSig = _signature(old, _key(1));
        address next = _agent(99);
        vm.prank(_owner(1));
        seats.authorize(1, next, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.prank(next);
        seats.accept(1, 2, CONSTITUTION, true);
        vm.expectRevert("FeedbackUnauthorized");
        board.recordFeedback(old, oldSig);
        QuorumBoard.Feedback memory fresh = _feedback(1);
        board.recordFeedback(fresh, _signature(fresh, _key(99)));
        assertEq(board.completedHours(1), 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 1);
        assertFalse(board.active(1));
    }

    function testReceiptAtExactAuthorizationExpiryIsRejectedWithoutConsumingHour() public {
        _enroll(1);
        address agent = _agent(1);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 2 hours);
        vm.prank(_owner(1));
        seats.authorize(1, agent, 15, expiry, K);
        vm.prank(agent);
        seats.accept(1, 2, CONSTITUTION, true);
        _anchor();
        vm.warp(expiry);
        _reject(_feedback(1), "FeedbackUnauthorized");
    }
}
