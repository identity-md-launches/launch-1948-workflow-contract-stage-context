// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, QuorumGovernance, QuorumBoard, QuorumAssembly, QuorumSeats} from "./Fixtures.sol";

contract GovernanceTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _active(10);
    }

    function testFrozenElectorateSurvivesDormancyAndExitButNotRevocationOrTransfer() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (7))), 0);
        assertEq(gov.getProposal(id).electorate, 10);
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        assertFalse(board.active(1));
        _vote(id, 1, QuorumGovernance.Choice.Yes);
        assertEq(gov.getProposal(id).yes, 1);
        vm.prank(_owner(2));
        seats.revoke(2);
        vm.expectRevert(QuorumGovernance.VoteUnauthorized.selector);
        vm.prank(_agent(2));
        gov.vote(id, 2, 1, QuorumGovernance.Choice.Yes, 0);
        vm.prank(_owner(3));
        nft.transferFrom(_owner(3), _owner(4), 3);
        vm.expectRevert(QuorumGovernance.VoteUnauthorized.selector);
        vm.prank(_agent(3));
        gov.vote(id, 3, 1, QuorumGovernance.Choice.Yes, 0);
        assertEq(gov.getProposal(id).electorate, 10);
        assertEq(gov.quorum(id), 5);
    }

    function testNoExtraStakeWeightDoubleVoteOrDuplicateLiveProposal() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (7))), 0);
        _vote(id, 1, QuorumGovernance.Choice.Yes);
        assertEq(gov.getProposal(id).yes, 1);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        _vote(id, 1, QuorumGovernance.Choice.No);
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (8)));
        uint256 postId = _post(1, QuorumGovernance.Kind.Major, calls, 0, 0, 0, 0);
        vm.expectRevert(QuorumGovernance.LiveProposalExists.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, 0);
        vm.warp(gov.getProposal(id).end);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        _vote(id, 2, QuorumGovernance.Choice.Yes);
    }

    function testNewSeatNoExemptionAndExitExcludesNewSnapshots() public {
        _enroll(11);
        vm.prank(_owner(2));
        seats.requestExit(2);
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (7))), 0);
        assertEq(gov.getProposal(id).electorate, 9);
        assertFalse(assemblyBook.eligible(gov.getProposal(id).snapshot, 11));
        assertFalse(assemblyBook.eligible(gov.getProposal(id).snapshot, 2));
        vm.expectRevert(QuorumGovernance.NotInElectorate.selector);
        _vote(id, 11, QuorumGovernance.Choice.Yes);
    }

    function testMajorThresholdAbstentionsAndFloor() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _yes(id, 2);
        _vote(id, 3, QuorumGovernance.Choice.No);
        _vote(id, 4, QuorumGovernance.Choice.Abstain);
        assertFalse(gov.passed(id)); // 4 is below the immutable floor of 5.
        _vote(id, 5, QuorumGovernance.Choice.Abstain);
        assertTrue(gov.passed(id)); // Exactly 2/3 yes among substantive votes.
        _vote(id, 6, QuorumGovernance.Choice.No);
        assertFalse(gov.passed(id));
    }

    function testGenesisRequiresTwoThirdsOfWholeFrozenElectorateAndFounderAcceptance() public {
        uint256 id = _handoverProposal();
        _yes(id, 6);
        assertFalse(gov.passed(id));
        _vote(id, 7, QuorumGovernance.Choice.Yes);
        assertTrue(gov.passed(id));
        vm.warp(gov.getProposal(id).executableAt - 1);
        vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        gov.execute(id);
        assertTrue(gov.handedOver());
        assertEq(safe.getOwners()[0], address(gov));
        vm.expectRevert(QuorumGovernance.NotExecutable.selector);
        gov.execute(id);
    }

    function testChangedConstitutionInvalidatesFounderBundleWithoutChangingFrozenVoteRules() public {
        uint256 id = _handoverProposal();
        _yes(id, 7);
        _ownerCall(address(seats), abi.encodeCall(seats.setConstitution, (keccak256("new constitution"))));
        assertEq(gov.getProposal(id).constitution, CONSTITUTION);
        assertEq(gov.quorum(id), 5);
        vm.warp(gov.getProposal(id).executableAt);
        vm.expectRevert(QuorumGovernance.HandoverChanged.selector);
        gov.execute(id);
        assertFalse(gov.handedOver());
        assertFalse(gov.getProposal(id).executed);
    }

    function testPiggybackVoteCreditsCurrentHourWithExactStatus() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _anchor();
        QuorumBoard.Feedback memory f = _feedback(1);
        f.status = QuorumBoard.Status.Voted;
        bytes memory sig = _signature(f, _key(1));
        vm.prank(_agent(1));
        gov.voteWithFeedback(id, 1, 1, QuorumGovernance.Choice.Yes, keccak256("why yes"), f, sig);
        assertEq(gov.getProposal(id).yes, 1);
        assertEq(board.lastCreditedHourPlusOne(1), f.hour + 1);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        _vote(id, 1, QuorumGovernance.Choice.Yes);
    }

    function testRotationCanVoteFrozenSeatOnlyOnce() public {
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        address next = _agent(21);
        vm.prank(_owner(1));
        seats.authorize(1, next, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.prank(next);
        seats.accept(1, 2, CONSTITUTION, true);
        assertFalse(board.active(1));
        vm.prank(next);
        gov.vote(id, 1, 2, QuorumGovernance.Choice.Yes, 0);
        vm.expectRevert(QuorumGovernance.VoteClosedOrDuplicate.selector);
        vm.prank(next);
        gov.vote(id, 1, 2, QuorumGovernance.Choice.No, 0);
    }

    function testProposalHashBindsExactCallsChainNonceAndConstitution() public {
        QuorumGovernance.Action[] memory calls = _call(address(target), abi.encodeCall(target.set, (1)));
        uint256 postId = _post(1, QuorumGovernance.Kind.Major, calls, 0, 0, 0, 0);
        calls[0].data = abi.encodeCall(target.set, (2));
        vm.expectRevert(QuorumGovernance.ProposalPostMismatch.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, 0);
        assertEq(gov.proposalCount(), 0);
        calls[0].data = abi.encodeCall(target.set, (1));
        vm.chainId(2);
        vm.expectRevert(QuorumGovernance.ProposalPostMismatch.selector);
        vm.prank(_agent(1));
        gov.proposeMajor(1, 1, postId, calls, 0);
        vm.chainId(1);
        vm.prank(_agent(1));
        uint256 id = gov.proposeMajor(1, 1, postId, calls, 0);
        assertEq(gov.getActions(id)[0].data, calls[0].data);
    }

    function testNoAutomaticHandoverWithTimeOrImdCompletion() public {
        vm.warp(vm.getBlockTimestamp() + 1000 days);
        assertFalse(gov.handedOver());
        assertEq(safe.getOwners()[0], founder);
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K);
    }
}

contract GenesisMinimumTest is Fixtures {
    function testTooFewSeatsCannotHandover() public {
        _active(9);
        _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (address(gov))));
        bytes32 hash = gov.handoverCommitment();
        vm.prank(founder);
        gov.founderAccept(hash);
        QuorumGovernance.Action[] memory empty = new QuorumGovernance.Action[](0);
        uint256 postId = _post(1, QuorumGovernance.Kind.Handover, empty, 0, 0, 0, hash);
        vm.expectRevert(QuorumGovernance.GenesisTooSmall.selector);
        vm.prank(_agent(1));
        gov.proposeHandover(1, 1, postId);
    }

    function testTenSeatsFourOwnersCannotHandover() public {
        // Group every NFT under four actual owners, using normal authorization and deposits.
        for (uint256 id = 1; id <= 10; ++id) {
            address owner = _owner(id % 4);
            nft.mint(id, owner);
            token.transfer(owner, K);
            address agent = _agent(id);
            vm.startPrank(owner);
            nft.approve(address(seats), id);
            seats.authorize(id, agent, 15, uint64(vm.getBlockTimestamp() + 300 days), K);
            token.approve(address(seats), K);
            vm.stopPrank();
            vm.prank(agent);
            seats.accept(id, 1, CONSTITUTION, true);
            vm.prank(owner);
            seats.deposit(id);
        }
        _hours(10, 24);
        _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (address(gov))));
        bytes32 hash = gov.handoverCommitment();
        vm.prank(founder);
        gov.founderAccept(hash);
        QuorumGovernance.Action[] memory empty = new QuorumGovernance.Action[](0);
        uint256 postId = _post(1, QuorumGovernance.Kind.Handover, empty, 0, 0, 0, hash);
        vm.expectRevert(QuorumGovernance.GenesisTooSmall.selector);
        vm.prank(_agent(1));
        gov.proposeHandover(1, 1, postId);
    }

    function testFourSeatQuorumNeverDropsBelowFive() public {
        _active(4);
        uint256 id = _major(1, _call(address(target), abi.encodeCall(target.set, (1))), 0);
        _yes(id, 4);
        assertEq(gov.quorum(id), 5);
        assertFalse(gov.passed(id));
    }
}
