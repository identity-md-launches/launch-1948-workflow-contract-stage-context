// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumBoard, QuorumSeats} from "./Fixtures.sol";

contract ParticipationTest is Fixtures {
    function testMalleableAndTruncatedSignaturesRejected() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key(1), board.feedbackDigest(f));
        bytes32 highS =
            bytes32(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 - uint256(s));
        bytes memory signature = abi.encodePacked(r, highS, uint8(v == 27 ? 28 : 27));
        vm.expectRevert("SignatureMalleable");
        board.recordFeedback(f, signature);
        vm.expectRevert("SignatureLength");
        board.recordFeedback(f, bytes("short"));
    }

    function testExactly18Of24CompletedHoursAndActivation() public {
        _enroll(1);
        _hours(1, 17);
        assertEq(board.completedHours(1), 17);
        _anchor();
        _receipt(1);
        assertEq(board.completedHours(1), 17); // The current hour never counts.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 18);
        assertFalse(board.active(1)); // Even 18 receipts do not bypass 24h activation.
        vm.warp(101 days);
        assertTrue(board.active(1));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 17);
        assertFalse(board.active(1));
    }

    function testSleepDormancyRecoveryNeedsRealReceipts() public {
        _active(1);
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        assertEq(board.completedHours(1), 17);
        assertFalse(board.active(1));
        vm.warp(vm.getBlockTimestamp() + 100 days);
        assertEq(board.completedHours(1), 0);
        _hours(1, 18);
        assertTrue(board.active(1));
    }

    function testReplayBackfillFutureHourAndWrongSignatureRejected() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        board.recordFeedback(f, sig);
        vm.expectRevert("AlreadyCredited");
        board.recordFeedback(f, sig);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert("FeedbackWrongHour");
        board.recordFeedback(f, sig);
        f.hour += 2;
        sig = _signature(f, _key(1));
        vm.expectRevert("FeedbackWrongHour");
        board.recordFeedback(f, sig);
        f.hour -= 1;
        sig = _signature(f, _key(2));
        vm.expectRevert("FeedbackUnauthorized");
        board.recordFeedback(f, sig);
    }

    function testReceiptMustLandBeforeHourBoundary() public {
        _enroll(1);
        _anchor();
        vm.warp(vm.getBlockTimestamp() + 3599);
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert("FeedbackWrongHour");
        board.recordFeedback(f, sig);
        _receipt(1);
        assertEq(board.completedHours(1), 0);
        vm.warp(vm.getBlockTimestamp() + 3600);
        assertEq(board.completedHours(1), 1);
    }

    function testRecentConfirmedBlockAndExactHistoricalContentRevision() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        f.anchorBlock = uint64(vm.getBlockNumber() - 11);
        bytes memory sig = _signature(f, _key(1));
        vm.expectRevert("AnchorAge");
        board.recordFeedback(f, sig);
        f = _feedback(1);
        f.anchorHash = keccak256("wrong fork");
        sig = _signature(f, _key(1));
        vm.expectRevert("AnchorHash");
        board.recordFeedback(f, sig);
        vm.prank(_agent(1));
        board.post(1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "New relevant matter");
        _anchor();
        f = _feedback(1);
        assertEq(f.revision, 1);
        f.revision = 0;
        f.contentHash = board.getRevision(0).contentHash;
        sig = _signature(f, _key(1));
        vm.expectRevert("ContentRevision");
        board.recordFeedback(f, sig);
        _receipt(1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 129);
        f.hour++;
        sig = _signature(f, _key(1));
        vm.expectRevert("AnchorAge");
        board.recordFeedback(f, sig);
    }

    function testChainProjectVersionAndGenerationBound() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        vm.chainId(2);
        vm.expectRevert("FeedbackUnauthorized");
        board.recordFeedback(f, sig);
        vm.chainId(1);
        QuorumBoard other = new QuorumBoard(address(seats));
        vm.expectRevert("FeedbackUnauthorized");
        other.recordFeedback(f, sig);
        f.generation++;
        sig = _signature(f, _key(1));
        vm.expectRevert("FeedbackNotStaked");
        board.recordFeedback(f, sig);
        address old = _agent(1);
        address next = _agent(2);
        vm.prank(_owner(1));
        seats.authorize(1, next, 15, uint64(vm.getBlockTimestamp() + 10 days), K);
        assertFalse(seats.validAgent(1, old, 1, 1));
    }

    function testPiggybackPostCountsOnceAndStoresReadablePagedContent() public {
        _enroll(1);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        vm.prank(_agent(1));
        uint256 id = board.postWithFeedback(
            1, 1, QuorumBoard.PostKind.Discussion, 0, 0, 0, "Readable public rationale", f, sig
        );
        assertEq(board.getPost(id).body, "Readable public rationale");
        assertEq(board.getPosts(0, 50).length, 1);
        vm.expectRevert("PageBounds");
        board.getPosts(0, 51);
        vm.expectRevert("AlreadyCredited");
        board.recordFeedback(f, sig);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(1), 1);
    }

    function testRotationClearsFutureAttendanceButCannotDoubleCreditHour() public {
        _active(1);
        _anchor();
        _receipt(1);
        address agent = _agent(1);
        vm.prank(_owner(1));
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.prank(agent);
        seats.accept(1, 2, CONSTITUTION, true);
        assertEq(board.completedHours(1), 0);
        QuorumBoard.Feedback memory f = _feedback(1);
        bytes memory sig = _signature(f, _key(1));
        vm.expectRevert("AlreadyCredited");
        board.recordFeedback(f, sig);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _hours(1, 18);
        assertTrue(board.active(1));
    }

    function testFuzzAttendanceMatchesReference24HourWindow(uint32 pattern) public {
        _enroll(1);
        uint256 expected;
        for (uint256 i; i < 25; ++i) {
            _anchor();
            if ((pattern & (uint256(1) << i)) != 0) {
                _receipt(1);
                if (i > 0) ++expected;
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        assertEq(board.completedHours(1), expected);
        assertEq(board.active(1), expected >= 18);
    }
}
