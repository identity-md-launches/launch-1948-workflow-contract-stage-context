// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumGovernance, QuorumBoard} from "./Fixtures.sol";

contract AdversarialGovernanceTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
    }

    function testPiggybackInvalidFeedbackRevertsVoteAndAllowsCorrectRetry() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (4))), 0);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(2);
        f.status = QuorumBoard.Status.Voted;
        f.anchorHash = keccak256("incorrect anchor");
        bytes memory sig = _signature(f, _key(2));
        uint64 lastCredit = board.lastCreditedHourPlusOne(2);
        vm.expectRevert("AnchorHash");
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 1, QuorumGovernance.Choice.Yes, 0, f, sig);
        assertFalse(gov.hasVoted(id, 2));
        assertEq(gov.getProposal(id).yes, 0);
        assertEq(board.lastCreditedHourPlusOne(2), lastCredit);
        f = _feedback(2);
        f.status = QuorumBoard.Status.Voted;
        sig = _signature(f, _key(2));
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 1, QuorumGovernance.Choice.Yes, 0, f, sig);
        assertTrue(gov.hasVoted(id, 2));
        assertEq(gov.getProposal(id).yes, 1);
        assertEq(board.lastCreditedHourPlusOne(2), f.hour + 1);
    }

    function testPiggybackSeatVersionAndStatusMustMatchVote() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (4))), 0);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(2);
        bytes memory sig = _signature(f, _key(2));
        vm.expectRevert(QuorumGovernance.VoteFeedbackMismatch.selector);
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 1, QuorumGovernance.Choice.Yes, 0, f, sig);
        f.status = QuorumBoard.Status.Voted;
        sig = _signature(f, _key(2));
        vm.expectRevert(QuorumGovernance.VoteFeedbackMismatch.selector);
        vm.prank(_agent(1));
        gov.voteWithFeedback(id, 1, 1, QuorumGovernance.Choice.Yes, 0, f, sig);
        vm.expectRevert(QuorumGovernance.VoteFeedbackMismatch.selector);
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 2, QuorumGovernance.Choice.Yes, 0, f, sig);
        assertEq(gov.getProposal(id).yes, 0);
        assertFalse(gov.hasVoted(id, 1));
        assertFalse(gov.hasVoted(id, 2));
    }

    function testAlreadyCreditedVotePiggybackIsAtomicAndStandaloneVoteStillWorks() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (4))), 0);
        _anchor();
        _receipt(2);
        QuorumBoard.Feedback memory f = _feedback(2);
        f.status = QuorumBoard.Status.Voted;
        bytes memory sig = _signature(f, _key(2));
        vm.expectRevert("AlreadyCredited");
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 1, QuorumGovernance.Choice.Abstain, 0, f, sig);
        assertFalse(gov.hasVoted(id, 2));
        assertEq(gov.getProposal(id).abstain, 0);
        _vote(id, 2, QuorumGovernance.Choice.Abstain);
        assertEq(gov.getProposal(id).abstain, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(board.completedHours(2), 24);
    }

    function testDuplicateVoteCannotCreditAnotherHour() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (4))), 0);
        _vote(id, 2, QuorumGovernance.Choice.Yes);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(2);
        f.status = QuorumBoard.Status.Voted;
        bytes memory sig = _signature(f, _key(2));
        uint64 beforeCredit = board.lastCreditedHourPlusOne(2);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        vm.prank(_agent(2));
        gov.voteWithFeedback(id, 2, 1, QuorumGovernance.Choice.No, 0, f, sig);
        assertEq(board.lastCreditedHourPlusOne(2), beforeCredit);
        assertEq(gov.getProposal(id).yes, 1);
        assertEq(gov.getProposal(id).no, 0);
    }

    function testVotingClosesAtExactEndAndFutureProposalCannotReuseConsumedPost() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (4)));
        uint256 id = _major(1, calls, 0);
        uint256 postId = gov.getProposal(id).postId;
        vm.warp(gov.getProposal(id).end - 1);
        _vote(id, 2, QuorumGovernance.Choice.Yes);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        _vote(id, 3, QuorumGovernance.Choice.Yes);
        _hours(10, 18);
        vm.expectRevert(QuorumGovernance.ProposalPostMismatch.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, 0);
        assertEq(gov.proposalCount(), 1);
        uint256 next = _major(1, calls, 0);
        assertEq(next, 2, "failed proposal consumed nonce or trapped proposer");
        assertEq(gov.getProposal(id).yes, 1);
    }

    function testProposalCommitmentBindsValueTargetReturnHashAndSeat() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (4)));
        uint256 postId = _post(1, QuorumGovernance.Kind.Major, calls, 0, 0, 0, 0);
        calls[0].value = 1;
        _mismatch(postId, calls, 1);
        calls[0].value = 0;
        calls[0].target = address(token);
        _mismatch(postId, calls, 1);
        calls[0].target = address(target);
        calls[0].expectedReturnHash = keccak256(abi.encode(true));
        _mismatch(postId, calls, 1);
        calls[0].expectedReturnHash = bytes32(0);
        _mismatch(postId, calls, 2);
        assertFalse(gov.usedPost(postId));
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, 0);
        assertTrue(gov.usedPost(postId));
    }

    function _mismatch(uint256 postId, QuorumGovernance.Action[] memory calls, uint256 seat) internal {
        vm.expectRevert(QuorumGovernance.ProposalPostMismatch.selector);
        vm.prank(_agent(seat));
        gov.proposeMajor(seat, 1, postId, calls, 0);
        assertEq(gov.proposalCount(), 0);
    }
}

contract AdversarialQuorumTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(128);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MajorQuorumAndSupermajorityUseWholeFrozenElectorate(
        uint8 electorateSeed,
        uint8 yesSeed,
        uint8 noSeed,
        uint8 abstainSeed
    ) public {
        uint256 n = bound(electorateSeed, 1, 128);
        for (uint256 seat = n + 1; seat <= 128; ++seat) {
            vm.prank(_owner(seat));
            seats.requestExit(seat);
        }
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        uint256 yes = bound(yesSeed, 0, n);
        uint256 no = bound(noSeed, 0, n - yes);
        uint256 abstain = bound(abstainSeed, 0, n - yes - no);
        for (uint256 seat = 1; seat <= yes; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.Yes);
        }
        for (uint256 seat = yes + 1; seat <= yes + no; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.No);
        }
        for (uint256 seat = yes + no + 1; seat <= yes + no + abstain; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.Abstain);
        }
        // A count-based oracle, including ceil at every multiple-of-three boundary.
        uint256 q = n / 3 + (n % 3 == 0 ? 0 : 1);
        if (q < 5) q = 5;
        assertEq(gov.quorum(id), q);
        assertEq(gov.passed(id), yes + no + abstain >= q && yes != 0 && yes >= 2 * no);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        assertEq(gov.getProposal(id).electorate, n);
        assertEq(gov.quorum(id), q, "dormancy lowered quorum");
    }
}

contract AdversarialOrdinaryQuorumTest is Fixtures {
    uint256 internal budget;

    function setUp() public override {
        super.setUp();
        _active(31);
        uint256 handover = _handoverProposal();
        _yes(handover, 21);
        vm.warp(gov.getProposal(handover).executableAt);
        gov.execute(handover);
        _hours(31, 18);
        uint256 id = _major(
            1,
            _call(
                address(gov),
                abi.encodeCall(
                    gov.approveBudget,
                    (
                        address(token),
                        _owner(4),
                        1000,
                        keccak256("approved storage budget"),
                        uint64(vm.getBlockTimestamp() + 90 days)
                    )
                )
            ),
            0
        );
        _yes(id, 21);
        vm.warp(gov.getProposal(id).executableAt);
        gov.execute(id);
        budget = gov.budgetCount();
        token.transfer(address(safe), 1000);
        _hours(31, 18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OrdinaryQuorumAndStrictMajority(
        uint8 electorateSeed,
        uint8 yesSeed,
        uint8 noSeed,
        uint8 abstainSeed
    ) public {
        uint256 n = bound(electorateSeed, 1, 31);
        for (uint256 seat = n + 1; seat <= 31; ++seat) {
            vm.prank(_owner(seat));
            seats.requestExit(seat);
        }
        QuorumGovernance.Action[] memory calls = gov.spendingAction(budget, 10);
        uint256 postId = _post(1, QuorumGovernance.Kind.Ordinary, calls, budget, 10, 0, 0);
        vm.prank(_agent(1));
        uint256 id = gov.proposeSpend(1, 1, postId, budget, 10, 0);
        uint256 yes = bound(yesSeed, 0, n);
        uint256 no = bound(noSeed, 0, n - yes);
        uint256 abstain = bound(abstainSeed, 0, n - yes - no);
        for (uint256 seat = 1; seat <= yes; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.Yes);
        }
        for (uint256 seat = yes + 1; seat <= yes + no; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.No);
        }
        for (uint256 seat = yes + no + 1; seat <= yes + no + abstain; ++seat) {
            _vote(id, seat, QuorumGovernance.Choice.Abstain);
        }
        uint256 q = n / 5 + (n % 5 == 0 ? 0 : 1);
        if (q < 5) q = 5;
        bool expected = yes + no + abstain >= q && yes > no;
        assertEq(gov.quorum(id), q);
        assertEq(gov.passed(id), expected);
        QuorumGovernance.Proposal memory p = gov.getProposal(id);
        assertEq(p.end - p.start, 48 hours);
        assertEq(p.executableAt - p.end, 24 hours);
        vm.warp(p.executableAt);
        uint256 beforeBalance = token.balanceOf(_owner(4));
        if (!expected) vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
        assertEq(token.balanceOf(_owner(4)), beforeBalance + (expected ? 10 : 0));
        assertEq(gov.getProposal(id).executed, expected);
    }
}
