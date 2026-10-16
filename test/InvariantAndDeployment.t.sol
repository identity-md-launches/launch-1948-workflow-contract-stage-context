// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixtures,
    LaunchToken,
    QuorumSeats,
    QuorumBoard,
    QuorumAssembly,
    QuorumSafePolicy,
    QuorumGovernance,
    QuorumReleases,
    SeatNFTMock
} from "./Fixtures.sol";
import {Test} from "forge-std/Test.sol";

contract CustodyHandler is Test {
    LaunchToken public token;
    QuorumSeats public seats;
    QuorumBoard public board;
    SeatNFTMock public nft;
    bytes32 public constitution;

    constructor(
        LaunchToken token_,
        QuorumSeats seats_,
        QuorumBoard board_,
        SeatNFTMock nft_,
        bytes32 constitution_
    ) {
        token = token_;
        seats = seats_;
        board = board_;
        nft = nft_;
        constitution = constitution_;
    }

    function exit(uint256 seed) external {
        uint256 id = seed % 4 + 1;
        QuorumSeats.Seat memory s = seats.getSeat(id);
        if (!seats.isDeposited(id) || s.exitAt != 0) return;
        vm.prank(s.depositor);
        seats.requestExit(id);
    }

    function withdraw(uint256 seed) external {
        uint256 id = seed % 4 + 1;
        QuorumSeats.Seat memory s = seats.getSeat(id);
        if (seats.isDeposited(id) && s.exitAt != 0 && vm.getBlockTimestamp() >= s.exitAt) seats.withdraw(id);
    }

    function revoke(uint256 seed) external {
        uint256 id = seed % 4 + 1;
        vm.prank(seats.getSeat(id).depositor);
        seats.revoke(id);
    }

    function rejoin(uint256 seed) external {
        uint256 id = seed % 4 + 1;
        if (seats.isDeposited(id)) return;
        address owner = nft.ownerOf(id);
        address agent = vm.addr(0x100000 + id);
        uint256 stake = seats.stakeAmount();
        vm.startPrank(owner);
        nft.approve(address(seats), id);
        seats.authorize(id, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), stake);
        token.approve(address(seats), stake);
        vm.stopPrank();
        uint64 version = seats.getSeat(id).version;
        vm.prank(agent);
        seats.accept(id, version, constitution, true);
        vm.prank(owner);
        seats.deposit(id);
    }

    function timePasses(uint32 delta) external {
        vm.warp(vm.getBlockTimestamp() + uint256(delta % uint32(3 days)));
    }

    function donation(uint96 amount) external {
        uint256 available = token.balanceOf(address(this));
        if (available == 0) return;
        token.transfer(address(seats), uint256(amount) % (available + 1));
    }
}

contract CustodyInvariantTest is Fixtures {
    CustodyHandler internal handler;

    function setUp() public override {
        super.setUp();
        _enrollN(4);
        handler = new CustodyHandler(token, seats, board, nft, CONSTITUTION);
        token.transfer(address(handler), 100 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.exit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.rejoin.selector;
        selectors[4] = handler.timePasses.selector;
        selectors[5] = handler.donation.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantRefundableStakesAreAlwaysFullyBackedAndDistinct() public view {
        uint256 deposited;
        for (uint256 id = 1; id <= 4; ++id) {
            if (seats.isDeposited(id)) ++deposited;
        }
        assertEq(seats.depositedCount(), deposited);
        assertEq(seats.totalDeposited(), deposited * K);
        assertGe(token.balanceOf(address(seats)), seats.totalDeposited());
        for (uint256 i; i < deposited; ++i) {
            for (uint256 j; j < i; ++j) {
                assertNotEq(seats.depositedSeatAt(i), seats.depositedSeatAt(j));
            }
        }
    }

    function invariantTokenConservationAndNoTreasuryAccessToStakes() public view {
        uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(handler))
            + token.balanceOf(address(seats));
        for (uint256 id = 1; id <= 4; ++id) {
            total += token.balanceOf(_owner(id));
        }
        assertEq(total, token.totalSupply());
        assertEq(token.balanceOf(address(safe)), 0);
        assertEq(token.balanceOf(address(gov)), 0);
    }
}

contract DeploymentAndBoundTest is Fixtures {
    function testApplicationRuntimesSizeUnlinkedAndNoEscapeOpcodes() public view {
        address[7] memory contracts_ = [
            address(token),
            address(seats),
            address(board),
            address(assemblyBook),
            address(safePolicy),
            address(gov),
            address(releases)
        ];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory code = contracts_[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "Forbidden application opcode");
            }
        }
    }

    function testConstructorsNeedNoDeployedDependenciesOrInitializerCalls() public {
        // Deliberately nonexistent dependencies on the probe chain; none is a launch parameter.
        address blank = address(uint160(0x100000000000));
        QuorumSeats a = new QuorumSeats(blank, address(safe), CONSTITUTION);
        QuorumBoard b = new QuorumBoard(blank);
        QuorumAssembly c = new QuorumAssembly(blank, blank);
        QuorumSafePolicy d = new QuorumSafePolicy(
            address(safe), founder, keccak256("fixture code"), keccak256("fixture proxy")
        );
        QuorumGovernance e = new QuorumGovernance(blank, blank, blank, address(safe), founder, blank);
        QuorumReleases f = new QuorumReleases(blank, address(safe));
        assertEq(a.owner(), address(safe));
        assertEq(address(b.seats()), blank);
        assertEq(address(c.seats()), blank);
        assertEq(d.founder(), founder);
        assertEq(address(e.safe()), address(safe));
        assertEq(f.owner(), address(safe));
    }
}

contract MaximumCapacityTest is Fixtures {
    function setUp() public override {
        super.setUp();
        _enrollN(128);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _hours(128, 18);
    }

    function testMaximumProposalPayloadStaysBelowTransactionGasLimit() public {
        QuorumGovernance.Action[] memory calls = new QuorumGovernance.Action[](8);
        bytes memory padding = new bytes(476);
        for (uint256 i; i < padding.length; ++i) {
            padding[i] = 0x01;
        }
        for (uint256 i; i < calls.length; ++i) {
            calls[i] = QuorumGovernance.Action(
                address(target),
                0,
                bytes.concat(abi.encodeCall(target.set, (i + 1)), padding),
                keccak256(abi.encode(true))
            );
        }
        uint256 beforeGas = gasleft();
        uint256 id = _major(1, calls, 0);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("128-seat 4096-byte proposal gas (fixture NFT)", used);
        assertLt(used, 14_000_000);
        assertEq(gov.getProposal(id).electorate, 128);
        assertEq(gov.quorum(id), 43);
    }

    function testMaximumSeatSnapshotHasBoundedMainnetGasAndCapacityRecycles() public {
        uint256 beforeGas = gasleft();
        (uint256 id, uint32 count, uint32 diversity) = assemblyBook.snapshot();
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("128-seat snapshot gas (fixture NFT)", used);
        assertLt(used, 14_000_000);
        assertEq(count, 128);
        assertEq(diversity, 5);
        assertTrue(assemblyBook.eligible(id, 128));
        nft.mint(129, _owner(129));
        token.transfer(_owner(129), K);
        address agent = _agent(129);
        vm.startPrank(_owner(129));
        nft.approve(address(seats), 129);
        seats.authorize(129, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        token.approve(address(seats), K);
        vm.stopPrank();
        vm.prank(agent);
        seats.accept(129, 1, CONSTITUTION, true);
        vm.expectRevert("SeatAlreadyStakedOrCapacity");
        vm.prank(_owner(129));
        seats.deposit(129);
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        seats.withdraw(1);
        vm.prank(_owner(129));
        seats.deposit(129);
        assertEq(seats.depositedCount(), 128);
        assertFalse(board.active(129));
    }
}
