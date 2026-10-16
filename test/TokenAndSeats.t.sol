// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixtures, LaunchToken, QuorumSeats, QuorumBoard, SeatNFTMock} from "./Fixtures.sol";

contract TokenAndSeatsTest is Fixtures {
    function testNewNFTOwnerCanReleaseOldStakeWithoutTakingItsRefund() public {
        _enroll(1);
        vm.prank(_owner(1));
        nft.transferFrom(_owner(1), _owner(2), 1);
        vm.prank(_owner(2));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K);
        assertEq(token.balanceOf(_owner(2)), 0);
        token.transfer(_owner(2), K);
        address agent = _agent(2);
        vm.startPrank(_owner(2));
        nft.approve(address(seats), 1);
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        token.approve(address(seats), K);
        vm.stopPrank();
        uint64 version = seats.getSeat(1).version;
        vm.prank(agent);
        seats.accept(1, version, CONSTITUTION, true);
        vm.prank(_owner(2));
        seats.deposit(1);
        assertEq(seats.getSeat(1).generation, 2);
        assertEq(seats.getSeat(1).depositor, _owner(2));
    }

    function testTokenSupplyPlainTransferAndAllowance() public {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "QUORUM");
        assertEq(token.symbol(), "QRM");
        token.transfer(_owner(1), 100);
        vm.prank(_owner(1));
        token.approve(_owner(2), 30);
        vm.prank(_owner(2));
        token.transferFrom(_owner(1), _owner(3), 30);
        assertEq(token.balanceOf(_owner(1)), 70);
        assertEq(token.balanceOf(_owner(3)), 30);
        vm.expectRevert("Allowance");
        vm.prank(_owner(2));
        token.transferFrom(_owner(1), _owner(3), 1);
        vm.expectRevert("TransferInvalid");
        token.transfer(address(0), 1);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function testAdmissionUnsetThenFrozenAndKExact() public {
        QuorumSeats fresh = new QuorumSeats(address(token), address(safe), CONSTITUTION);
        vm.expectRevert("AdmissionNotConfigured");
        fresh.deposit(1);
        vm.expectRevert("OnlyOwner");
        fresh.configureAdmission(address(nft), 3, keccak256("source"), "ipfs://fixture");
        vm.prank(address(safe));
        fresh.configureAdmission(address(nft), 3, keccak256("source"), "ipfs://fixture");
        assertEq(fresh.stakeAmount(), (token.totalSupply() * 750 / 10000) / 3);
        vm.expectRevert("AdmissionFrozen");
        vm.prank(address(safe));
        fresh.configureAdmission(address(nft), 5, keccak256("changed"), "ipfs://changed");
        vm.expectRevert("InvalidConfiguration");
        new QuorumSeats(address(token), address(0), CONSTITUTION);
    }

    function testOwnerOptInAndAgentSeparateAcceptanceRequired() public {
        nft.mint(1, _owner(1));
        address agent = _agent(1);
        vm.expectRevert("OwnerOrApproval");
        vm.prank(_owner(1));
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 1 days), K);
        vm.startPrank(_owner(1));
        nft.approve(address(seats), 1);
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.expectRevert("AgentNotAccepted");
        seats.deposit(1);
        vm.expectRevert("UnauthorizedAgent");
        seats.accept(1, 1, CONSTITUTION, true);
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert("AcceptanceInvalid");
        seats.accept(1, 1, keccak256("other"), true);
        vm.expectRevert("AcceptanceInvalid");
        seats.accept(1, 1, CONSTITUTION, false);
        seats.decline(1, 1);
        assertFalse(seats.validAgent(1, agent, 1, 1));
        seats.accept(1, 1, CONSTITUTION, true);
        assertTrue(seats.validAgent(1, agent, 1, 1));
        vm.stopPrank();
    }

    function testNoDoubleDepositSharedStakeOrSharedKey() public {
        _enroll(1);
        assertEq(seats.totalDeposited(), K);
        vm.expectRevert("SeatAlreadyStakedOrCapacity");
        vm.prank(_owner(1));
        seats.deposit(1);
        nft.mint(2, _owner(2));
        vm.prank(_owner(2));
        nft.approve(address(seats), 2);
        address agent = _agent(1);
        vm.expectRevert("KeyAlreadyUsed");
        vm.prank(_owner(2));
        seats.authorize(2, agent, 15, uint64(vm.getBlockTimestamp() + 1 days), K);
        assertEq(token.balanceOf(address(seats)), K);
    }

    function testRotationRevocationExpiryAndBoundedStakePermission() public {
        _enroll(1);
        address old = _agent(1);
        address next = _agent(99);
        vm.prank(_owner(1));
        seats.authorize(1, next, 1, uint64(vm.getBlockTimestamp() + 1 days), 0);
        assertFalse(seats.validAgent(1, old, 1, 1));
        vm.prank(next);
        seats.accept(1, 2, CONSTITUTION, true);
        assertFalse(seats.validAgent(1, next, 2, 2));
        vm.expectRevert("ExitUnauthorized");
        vm.prank(next);
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertFalse(seats.validAgent(1, next, 2, 1));
        vm.prank(_owner(1));
        seats.revoke(1);
        assertEq(seats.getSeat(1).agent, address(0));
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K);
    }

    function testTransferInvalidatesEvenRoundTripAndStakeStaysWithDepositor() public {
        _enroll(1);
        address agent = _agent(1);
        vm.prank(_owner(1));
        nft.transferFrom(_owner(1), _owner(2), 1);
        assertFalse(seats.validAgent(1, agent, 1, 1));
        vm.prank(_owner(2));
        nft.approve(address(seats), 1);
        address next = _agent(2);
        vm.expectRevert("StakeOutstanding");
        vm.prank(_owner(2));
        seats.authorize(1, next, 15, uint64(vm.getBlockTimestamp() + 10 days), K);
        vm.prank(_owner(2));
        nft.transferFrom(_owner(2), _owner(1), 1);
        assertFalse(seats.validAgent(1, agent, 1, 1)); // ERC-721 cleared exact approval.
        vm.prank(_owner(1));
        seats.requestExit(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(_owner(3));
        seats.withdraw(1);
        assertEq(token.balanceOf(_owner(1)), K);
        assertEq(token.balanceOf(_owner(3)), 0);
    }

    function testExitSevenDaysCannotBeCancelledOrConfiscated() public {
        _enrollN(2);
        uint256 stake = K;
        vm.prank(_owner(1));
        seats.requestExit(1);
        uint256 available = seats.getSeat(1).exitAt;
        vm.warp(available - 1);
        vm.expectRevert("ExitPending");
        seats.withdraw(1);
        vm.prank(address(safe));
        (bool ok,) =
            address(seats).call(abi.encodeWithSignature("sweep(address,uint256)", address(safe), stake));
        assertFalse(ok);
        vm.warp(available);
        seats.withdraw(1);
        assertEq(seats.totalDeposited(), stake);
        assertEq(seats.depositedSeatAt(0), 2);
        assertEq(token.balanceOf(address(seats)), stake);
        vm.expectRevert("ExitPending");
        seats.withdraw(1);
    }

    function testAgentCanDepositOnlyExplicitBoundAndExactAllowance() public {
        nft.mint(1, _owner(1));
        token.transfer(_owner(1), K);
        address agent = _agent(1);
        vm.startPrank(_owner(1));
        nft.approve(address(seats), 1);
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K - 1);
        token.approve(address(seats), K);
        vm.stopPrank();
        vm.prank(agent);
        seats.accept(1, 1, CONSTITUTION, true);
        vm.expectRevert("DepositUnauthorized");
        vm.prank(agent);
        seats.deposit(1);
        vm.prank(_owner(1));
        seats.authorize(1, agent, 15, uint64(vm.getBlockTimestamp() + 30 days), K);
        vm.prank(agent);
        seats.accept(1, 2, CONSTITUTION, true);
        vm.prank(agent);
        seats.deposit(1);
        assertEq(token.allowance(_owner(1), address(seats)), 0);
        assertEq(token.balanceOf(address(safe)), 0);
    }

    function testFuzzKUsesAtomicIntegerFloor(uint64 count) public {
        count = uint64(bound(count, 1, 1_000_000));
        QuorumSeats fresh = new QuorumSeats(address(token), address(safe), CONSTITUTION);
        vm.prank(address(safe));
        fresh.configureAdmission(address(nft), count, keccak256("fuzz admission"), "ipfs://fixture");
        assertEq(fresh.stakeAmount(), 75_000_000 ether / count);
        assertLe(fresh.stakeAmount() * count, 75_000_000 ether);
        assertLt(75_000_000 ether - fresh.stakeAmount() * count, count);
    }
}
