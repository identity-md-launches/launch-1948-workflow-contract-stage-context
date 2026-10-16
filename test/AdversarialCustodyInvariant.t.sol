// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixtures, LaunchToken, QuorumSeats, SeatNFTMock} from "./Fixtures.sol";

/// @dev Independent accounting records successful transfers, not values read back from totalDeposited.
contract AdversarialCustodyHandler is Test {
    LaunchToken public immutable token;
    QuorumSeats public immutable seats;
    SeatNFTMock public immutable nft;
    bytes32 public immutable constitution;
    uint256 public immutable stake;
    address[5] public actors;
    mapping(uint256 => address) public refundOwner;
    mapping(address => uint256) public depositedBy;
    mapping(address => uint256) public refundedTo;
    uint256 public outstanding;
    uint256 public donated;
    uint256 public successfulDeposits;
    uint256 public successfulRefunds;

    constructor(LaunchToken token_, QuorumSeats seats_, SeatNFTMock nft_, bytes32 constitution_) {
        token = token_;
        seats = seats_;
        nft = nft_;
        constitution = constitution_;
        stake = seats_.stakeAmount();
        for (uint256 i; i < 5; ++i) {
            actors[i] = address(uint160(0x10000 + i));
        }
        for (uint256 id = 1; id <= 5; ++id) {
            address owner = actors[id % 5];
            refundOwner[id] = owner;
            depositedBy[owner] += stake;
            outstanding += stake;
            ++successfulDeposits;
        }
    }

    function transferIdentity(uint256 seed, uint256 recipientSeed) external {
        uint256 id = seed % 5 + 1;
        address previous = nft.ownerOf(id);
        address next = actors[recipientSeed % 5];
        vm.prank(previous);
        nft.transferFrom(previous, next, id);
        QuorumSeats.Seat memory s = seats.getSeat(id);
        assertFalse(seats.validAgent(id, s.agent, s.version, 0), "transfer left an authorized key");
    }

    function authorizeAndAccept(uint256 seed, uint8 scopesSeed, bool accept) external {
        uint256 id = seed % 5 + 1;
        address owner = nft.ownerOf(id);
        if (refundOwner[id] != address(0) && owner != refundOwner[id]) return;
        address agent = vm.addr(0x200000 + id * 2 + (seed / 5) % 2);
        uint8 scopes = uint8(bound(scopesSeed, 1, 15));
        vm.startPrank(owner);
        nft.approve(address(seats), id);
        seats.authorize(id, agent, scopes, uint64(vm.getBlockTimestamp() + 30 days), stake);
        vm.stopPrank();
        uint64 version = seats.getSeat(id).version;
        vm.prank(agent);
        if (accept) seats.accept(id, version, constitution, true);
        else seats.decline(id, version);
    }

    function revoke(uint256 seed, bool useDepositor) external {
        uint256 id = seed % 5 + 1;
        address caller = useDepositor ? seats.getSeat(id).depositor : nft.ownerOf(id);
        vm.prank(caller);
        seats.revoke(id);
    }

    function deposit(uint256 seed, bool asAgent) external {
        uint256 id = seed % 5 + 1;
        if (refundOwner[id] != address(0)) return;
        QuorumSeats.Seat memory s = seats.getSeat(id);
        if (!seats.validAgent(id, s.agent, s.version, 0)) return;
        if (token.balanceOf(s.depositor) < stake) return;
        if (asAgent && (s.scopes & 8) == 0) return;
        vm.prank(s.depositor);
        token.approve(address(seats), stake);
        uint256 beforeBalance = token.balanceOf(s.depositor);
        vm.prank(asAgent ? s.agent : s.depositor);
        seats.deposit(id);
        assertEq(beforeBalance - token.balanceOf(s.depositor), stake);
        refundOwner[id] = s.depositor;
        depositedBy[s.depositor] += stake;
        outstanding += stake;
        ++successfulDeposits;
    }

    function exit(uint256 seed, bool currentOwner) external {
        uint256 id = seed % 5 + 1;
        if (refundOwner[id] == address(0) || seats.getSeat(id).exitAt != 0) return;
        vm.prank(currentOwner ? nft.ownerOf(id) : refundOwner[id]);
        seats.requestExit(id);
    }

    function withdraw(uint256 seed) external {
        uint256 id = seed % 5 + 1;
        address recipient = refundOwner[id];
        uint64 exitAt = seats.getSeat(id).exitAt;
        if (recipient == address(0) || exitAt == 0 || vm.getBlockTimestamp() < exitAt) return;
        uint256 beforeBalance = token.balanceOf(recipient);
        // An unrelated caller completes withdrawal; only the recorded depositor may receive tokens.
        seats.withdraw(id);
        assertEq(token.balanceOf(recipient) - beforeBalance, stake, "refund went to wrong owner");
        refundedTo[recipient] += stake;
        delete refundOwner[id];
        outstanding -= stake;
        ++successfulRefunds;
        vm.expectRevert("ExitPending");
        seats.withdraw(id);
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 10 days));
    }

    function fundOwner(uint256 ownerSeed) external {
        if (token.balanceOf(address(this)) >= stake) token.transfer(actors[ownerSeed % 5], stake);
    }

    function donate(uint96 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, token.balanceOf(address(this)));
        token.transfer(address(seats), amount);
        donated += amount;
    }

    function trySteal(uint256 seed) external {
        uint256 balance = token.balanceOf(address(seats));
        vm.expectRevert("Allowance");
        token.transferFrom(address(seats), address(this), seed % (stake + 1) + 1);
        assertEq(token.balanceOf(address(seats)), balance);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AdversarialCustodyInvariantTest is Fixtures {
    AdversarialCustodyHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enrollN(5);
        handler = new AdversarialCustodyHandler(token, seats, nft, CONSTITUTION);
        token.transfer(address(handler), token.balanceOf(address(this)));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.transferIdentity.selector;
        selectors[1] = handler.authorizeAndAccept.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.deposit.selector;
        selectors[4] = handler.exit.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.fundOwner.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.trySteal.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_RefundsAndCustodyMatchIndependentTransferLedger() public view {
        assertEq(seats.totalDeposited(), handler.outstanding());
        assertEq(token.balanceOf(address(seats)), handler.outstanding() + handler.donated());
        uint256 deposits;
        uint256 refunds;
        for (uint256 i; i < 5; ++i) {
            address owner = handler.actors(i);
            uint256 sent = handler.depositedBy(owner);
            uint256 received = handler.refundedTo(owner);
            assertLe(received, sent, "owner withdrew more than deposited");
            deposits += sent;
            refunds += received;
        }
        assertEq(deposits - refunds, handler.outstanding());
        assertEq(deposits, handler.successfulDeposits() * K);
        assertEq(refunds, handler.successfulRefunds() * K);
    }

    function invariant_EnumerationExactlyMatchesOutstandingClaims() public view {
        uint256 count;
        for (uint256 id = 1; id <= 5; ++id) {
            address recipient = handler.refundOwner(id);
            assertEq(seats.isDeposited(id), recipient != address(0));
            if (recipient != address(0)) {
                ++count;
                assertEq(seats.getSeat(id).depositor, recipient);
            }
        }
        assertEq(seats.depositedCount(), count);
        for (uint256 i; i < count; ++i) {
            uint256 id = seats.depositedSeatAt(i);
            assertTrue(handler.refundOwner(id) != address(0));
            for (uint256 j; j < i; ++j) {
                assertNotEq(id, seats.depositedSeatAt(j));
            }
        }
    }

    function invariant_SupplyConservedAndTreasuryCannotReachRefunds() public view {
        uint256 sum = token.balanceOf(address(handler)) + token.balanceOf(address(seats));
        for (uint256 i; i < 5; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(safe)), 0);
        assertEq(token.allowance(address(seats), address(safe)), 0);
        assertEq(token.allowance(address(seats), address(gov)), 0);
    }

    function testHandlerReachesTransferRefundAndNewOwnerRedeposit() public {
        handler.transferIdentity(0, 2); // Seat 1 moves from actor 1 to actor 2.
        handler.exit(0, true);
        handler.advance(uint32(7 days));
        handler.withdraw(0);
        assertEq(handler.refundedTo(_owner(1)), K);
        assertEq(handler.refundedTo(_owner(2)), 0);
        handler.fundOwner(2);
        handler.authorizeAndAccept(0, 15, true);
        handler.deposit(0, true);
        handler.donate(100);
        assertEq(handler.successfulDeposits(), 6);
        assertEq(handler.successfulRefunds(), 1);
        assertEq(handler.refundOwner(1), _owner(2));
        invariant_RefundsAndCustodyMatchIndependentTransferLedger();
        invariant_EnumerationExactlyMatchesOutstandingClaims();
        invariant_SupplyConservedAndTreasuryCannotReachRefunds();
        afterInvariant();
    }

    function afterInvariant() public {
        // Every generated final state must permit a complete, un-slashed exit without an agent.
        for (uint256 id = 1; id <= 5; ++id) {
            handler.exit(id - 1, false);
        }
        handler.advance(uint32(7 days));
        for (uint256 id = 1; id <= 5; ++id) {
            handler.withdraw(id - 1);
        }
        assertEq(handler.outstanding(), 0);
        assertEq(seats.totalDeposited(), 0);
        assertEq(seats.depositedCount(), 0);
        assertEq(token.balanceOf(address(seats)), handler.donated());
    }
}
