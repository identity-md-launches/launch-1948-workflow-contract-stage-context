// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixtures, Safe, Enum, LaunchToken, QuorumGovernance} from "./Fixtures.sol";

contract RejectableBudgetRecipient {
    bool public rejects;

    function setRejects(bool value) external {
        rejects = value;
    }

    receive() external payable {
        require(!rejects, "RecipientRejects");
    }
}

contract AdversarialTreasuryHandler is Test {
    QuorumGovernance public immutable gov;
    Safe public immutable safe;
    LaunchToken public immutable token;
    RejectableBudgetRecipient public immutable recipient;
    uint256[8] public ids;
    uint256[8] public amounts;
    uint256[8] public readyAt;
    uint256[8] public voteEnd;
    uint256[8] public expiresAt;
    bool[8] public done;
    uint256[8] public yes;
    uint256[8] public no;
    uint256[8] public abstain;
    mapping(uint256 => mapping(uint256 => bool)) public voted;
    uint256 public tokenPaid;
    uint256 public nativePaid;
    uint256 public tokenDonations;
    uint256 public nativeDonations;
    uint256 public executions;

    constructor(
        QuorumGovernance gov_,
        Safe safe_,
        LaunchToken token_,
        RejectableBudgetRecipient recipient_,
        uint256[8] memory ids_
    ) {
        gov = gov_;
        safe = safe_;
        token = token_;
        recipient = recipient_;
        ids = ids_;
        for (uint256 i; i < 8; ++i) {
            QuorumGovernance.Proposal memory p = gov_.getProposal(ids_[i]);
            amounts[i] = p.amount;
            readyAt[i] = p.executableAt;
            voteEnd[i] = p.end;
            expiresAt[i] = p.expires;
        }
    }

    function _cast(uint256 index, uint256 seat, uint8 choice) internal {
        if (voted[index][seat] || vm.getBlockTimestamp() >= voteEnd[index]) return;
        vm.prank(vm.addr(0x100000 + seat));
        gov.vote(ids[index], seat, 1, QuorumGovernance.Choice(choice), keccak256("invariant rationale"));
        voted[index][seat] = true;
        if (choice == uint8(QuorumGovernance.Choice.Yes)) ++yes[index];
        else if (choice == uint8(QuorumGovernance.Choice.No)) ++no[index];
        else ++abstain[index];
    }

    function castVote(uint256 proposalSeed, uint256 seatSeed, uint8 choiceSeed) external {
        _cast(proposalSeed % 8, seatSeed % 10 + 1, choiceSeed % 3);
    }

    function finishVoting(uint256 proposalSeed) external {
        for (uint256 seat = 1; seat <= 10; ++seat) {
            _cast(proposalSeed % 8, seat, 1);
        }
    }

    function advance(uint32 delta) external {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 0, 2 days));
    }

    function setRecipientFailure(bool value) external {
        recipient.setRejects(value);
    }

    function donateTokens(uint16 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, token.balanceOf(address(this)));
        token.transfer(address(safe), amount);
        tokenDonations += amount;
    }

    function donateNative(uint96 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, address(this).balance);
        (bool ok,) = address(safe).call{value: amount}(bytes(""));
        assertTrue(ok);
        nativeDonations += amount;
    }

    function execute(uint256 proposalSeed) external {
        uint256 index = proposalSeed % 8;
        bool tokenBudget = index < 4;
        uint256 amount = amounts[index];
        uint256 now_ = vm.getBlockTimestamp();
        bytes4 expectedError;
        if (
            done[index] || yes[index] + no[index] + abstain[index] < 5 || yes[index] <= no[index]
                || now_ < readyAt[index] || now_ > expiresAt[index]
        ) {
            expectedError = QuorumGovernance.NotExecutable.selector;
        } else if ((tokenBudget ? tokenPaid + amount > 1000 : nativePaid + amount > 10 ether)) {
            expectedError = QuorumGovernance.BudgetUnavailable.selector;
        } else if (!tokenBudget && recipient.rejects()) {
            expectedError = QuorumGovernance.SafeExecutionFailed.selector;
        }
        uint256 tokenBefore = token.balanceOf(address(safe));
        uint256 nativeBefore = address(safe).balance;
        (bool ok, bytes memory result) = address(gov).call(abi.encodeCall(gov.execute, (ids[index])));
        if (expectedError != bytes4(0)) {
            assertFalse(ok, "unapproved, replayed or over-budget proposal executed");
            assertEq(result, abi.encodeWithSelector(expectedError), "unexpected execution failure");
            assertEq(token.balanceOf(address(safe)), tokenBefore, "failure moved tokens");
            assertEq(address(safe).balance, nativeBefore, "failure moved ETH");
        } else {
            assertTrue(ok, "approved in-budget proposal could not execute");
            done[index] = true;
            ++executions;
            if (tokenBudget) tokenPaid += amount;
            else nativePaid += amount;
        }
    }

    function tryUnauthorizedModule(bool delegate) external {
        uint256 tokenBefore = token.balanceOf(address(safe));
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(
            address(token),
            0,
            abi.encodeCall(token.transfer, (address(this), 1)),
            delegate ? Enum.Operation.DelegateCall : Enum.Operation.Call
        );
        assertEq(token.balanceOf(address(safe)), tokenBefore);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AdversarialTreasuryInvariantTest is Fixtures {
    AdversarialTreasuryHandler internal handler;
    RejectableBudgetRecipient internal recipient;
    uint256 internal tokenBudget;
    uint256 internal nativeBudget;

    function setUp() public override {
        super.setUp();
        _active(10);
        _handover();
        _hours(10, 18);
        recipient = new RejectableBudgetRecipient();
        QuorumGovernance.Action[] memory calls = new QuorumGovernance.Action[](2);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 90 days);
        calls[0] = QuorumGovernance.Action(
            address(gov),
            0,
            abi.encodeCall(
                gov.approveBudget,
                (address(token), address(recipient), 1000, keccak256("approved token support"), expiry)
            ),
            0
        );
        calls[1] = QuorumGovernance.Action(
            address(gov),
            0,
            abi.encodeCall(
                gov.approveBudget,
                (address(0), address(recipient), 10 ether, keccak256("approved native support"), expiry)
            ),
            0
        );
        uint256 approval = _major(1, calls, 0);
        _yes(approval, 7);
        vm.warp(gov.getProposal(approval).executableAt);
        gov.execute(approval);
        tokenBudget = 1;
        nativeBudget = 2;
        _hours(10, 18);
        uint256[4] memory units = [uint256(3), 4, 6, 8];
        uint256[8] memory ids;
        for (uint256 i; i < 8; ++i) {
            uint256 budget = i < 4 ? tokenBudget : nativeBudget;
            uint256 amount = units[i % 4] * (i < 4 ? 100 : 1 ether);
            calls = gov.spendingAction(budget, amount);
            uint256 postId = _post(i + 1, QuorumGovernance.Kind.Ordinary, calls, budget, amount, 0, 0);
            vm.prank(_agent(i + 1));
            ids[i] = gov.proposeSpend(i + 1, 1, postId, budget, amount, 0);
        }
        token.transfer(address(safe), 1000);
        vm.deal(address(safe), 10 ether);
        handler = new AdversarialTreasuryHandler(gov, safe, token, recipient, ids);
        token.transfer(address(handler), 1000);
        vm.deal(address(handler), 5 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.castVote.selector;
        selectors[1] = handler.finishVoting.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.setRecipientFailure.selector;
        selectors[4] = handler.donateTokens.selector;
        selectors[5] = handler.donateNative.selector;
        selectors[6] = handler.execute.selector;
        selectors[7] = handler.tryUnauthorizedModule.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_SpendingMatchesExecutedActionsAndNeverExceedsEitherCap() public view {
        (,, uint256 tokenCap, uint256 tokenSpent,,) = gov.budgets(tokenBudget);
        (,, uint256 nativeCap, uint256 nativeSpent,,) = gov.budgets(nativeBudget);
        assertEq(tokenSpent, handler.tokenPaid());
        assertEq(nativeSpent, handler.nativePaid());
        assertLe(tokenSpent, tokenCap);
        assertLe(nativeSpent, nativeCap);
        assertEq(token.balanceOf(address(recipient)), tokenSpent);
        assertEq(address(recipient).balance, nativeSpent);
        assertEq(token.balanceOf(address(safe)) + tokenSpent, 1000 + handler.tokenDonations());
        assertEq(address(safe).balance + nativeSpent, 10 ether + handler.nativeDonations());
    }

    function invariant_VotesAndExecutionCannotBeReplayedOrLoseTheirFrozenElectorate() public view {
        uint256 executions;
        for (uint256 i; i < 8; ++i) {
            uint256 id = handler.ids(i);
            QuorumGovernance.Proposal memory p = gov.getProposal(id);
            assertEq(p.executed, handler.done(i));
            if (p.executed) ++executions;
            assertEq(p.electorate, 10);
            assertEq(gov.quorum(id), 5);
            assertEq(p.yes, handler.yes(i));
            assertEq(p.no, handler.no(i));
            assertEq(p.abstain, handler.abstain(i));
            assertLe(uint256(p.yes) + p.no + p.abstain, 10);
        }
        assertEq(executions, handler.executions());
        assertEq(gov.executingProposal(), 0);
    }

    function invariant_SafeAuthorityRemainsBoundAndStakesStayIsolated() public view {
        gov.assertBound();
        assertTrue(gov.handedOver());
        assertEq(seats.totalDeposited(), 10 * K);
        assertEq(token.balanceOf(address(seats)), 10 * K);
        assertEq(token.balanceOf(address(gov)), 0);
        assertEq(token.allowance(address(seats), address(safe)), 0);
    }

    function testHandlerCanReachSuccessfulAndFailedExecutionsThenRetry() public {
        handler.finishVoting(0);
        handler.finishVoting(4);
        handler.execute(0); // Too early, with no partial effects.
        handler.advance(uint32(2 days));
        handler.advance(uint32(1 days));
        handler.execute(0);
        handler.setRecipientFailure(true);
        handler.execute(4);
        assertEq(handler.executions(), 1);
        handler.setRecipientFailure(false);
        handler.execute(4);
        handler.execute(4); // Replay must fail.
        assertEq(handler.executions(), 2);
        invariant_SpendingMatchesExecutedActionsAndNeverExceedsEitherCap();
        invariant_VotesAndExecutionCannotBeReplayedOrLoseTheirFrozenElectorate();
        invariant_SafeAuthorityRemainsBoundAndStakesStayIsolated();
    }
}
