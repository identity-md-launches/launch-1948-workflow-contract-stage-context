// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Safe} from "safe/Safe.sol";
import {SafeProxy} from "safe/proxies/SafeProxy.sol";
import {Enum} from "safe/libraries/Enum.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {QuorumSeats} from "../src/QuorumSeats.sol";
import {QuorumBoard} from "../src/QuorumBoard.sol";
import {QuorumAssembly} from "../src/QuorumAssembly.sol";
import {QuorumGovernance} from "../src/QuorumGovernance.sol";
import {QuorumSafePolicy} from "../src/QuorumSafePolicy.sol";
import {QuorumReleases} from "../src/QuorumReleases.sol";

contract SeatNFTMock {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd;
    }

    function mint(uint256 id, address owner) external {
        require(ownerOf[id] == address(0));
        ownerOf[id] = owner;
    }

    function approve(address spender, uint256 id) external {
        require(ownerOf[id] == msg.sender);
        getApproved[id] = spender;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || getApproved[id] == msg.sender));
        ownerOf[id] = to;
        delete getApproved[id];
    }
}

contract CallTarget {
    uint256 public value;
    bool public fails;

    function setFailure(bool failure) external {
        fails = failure;
    }

    function set(uint256 next) external payable returns (bool) {
        require(!fails, "TargetFailure");
        value = next;
        return true;
    }

    function returnFalse() external pure returns (bool) {
        return false;
    }

    receive() external payable {
        require(!fails, "TargetFailure");
    }
}

abstract contract Fixtures is Test {
    uint256 internal K;
    LaunchToken internal token;
    SeatNFTMock internal nft;
    QuorumSeats internal seats;
    QuorumBoard internal board;
    QuorumAssembly internal assemblyBook;
    QuorumGovernance internal gov;
    QuorumReleases internal releases;
    Safe internal safe;
    Safe internal singleton;
    QuorumSafePolicy internal safePolicy;
    CallTarget internal target;
    address internal founder = 0x5D31bB1d7e4a9F3dfA3a3D421174Bca73705f087;
    bytes32 internal constant CONSTITUTION = keccak256("test constitution exact bytes");

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(100 days);
        vm.roll(1000);
        singleton = new Safe();
        safe = Safe(payable(address(new SafeProxy(address(singleton)))));
        address[] memory owners = new address[](1);
        owners[0] = founder;
        safe.setup(owners, 1, address(0), bytes(""), address(0), address(0), 0, payable(address(0)));
        token = new LaunchToken();
        nft = new SeatNFTMock();
        seats = new QuorumSeats(address(token), address(safe), CONSTITUTION);
        board = new QuorumBoard(address(seats));
        assemblyBook = new QuorumAssembly(address(seats), address(board));
        safePolicy =
            new QuorumSafePolicy(address(safe), founder, address(singleton).codehash, address(safe).codehash);
        gov = new QuorumGovernance(
            address(seats), address(board), address(assemblyBook), address(safe), founder, address(safePolicy)
        );
        releases = new QuorumReleases(address(gov), address(safe));
        target = new CallTarget();
        _ownerCall(
            address(seats),
            abi.encodeCall(
                seats.configureAdmission,
                (address(nft), 100, keccak256("test admission snapshot"), "ipfs://test-fixture-admission")
            )
        );
        K = seats.stakeAmount();
    }

    function _owner(uint256 id) internal pure returns (address) {
        return address(uint160(0x10000 + (id % 5)));
    }

    function _key(uint256 id) internal pure returns (uint256) {
        return 0x100000 + id;
    }

    function _agent(uint256 id) internal pure returns (address) {
        return vm.addr(_key(id));
    }

    function _ownerCall(address to, bytes memory data) internal {
        bytes memory signature = abi.encodePacked(bytes32(uint256(uint160(founder))), bytes32(0), uint8(1));
        vm.prank(founder);
        bool ok = safe.execTransaction(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signature
        );
        assertTrue(ok);
    }

    function _enroll(uint256 id) internal {
        address owner = _owner(id);
        address agent = _agent(id);
        nft.mint(id, owner);
        token.transfer(owner, K);
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

    function _enrollN(uint256 n) internal {
        for (uint256 i = 1; i <= n; ++i) {
            _enroll(i);
        }
    }

    function _anchor() internal {
        vm.roll(vm.getBlockNumber() + 20);
        vm.setBlockhash(
            vm.getBlockNumber() - 12, keccak256(abi.encode("confirmed", vm.getBlockNumber() - 12))
        );
    }

    function _feedback(uint256 id) internal view returns (QuorumBoard.Feedback memory f) {
        QuorumSeats.Seat memory s = seats.getSeat(id);
        uint64 anchor = uint64(vm.getBlockNumber() - 12);
        uint64 revision = board.revisionAtBlock(anchor);
        f = QuorumBoard.Feedback(
            id,
            s.version,
            s.generation,
            uint64(vm.getBlockTimestamp() / 1 hours),
            anchor,
            blockhash(anchor),
            revision,
            board.getRevision(revision).contentHash,
            QuorumBoard.Status.Read
        );
    }

    function _signature(QuorumBoard.Feedback memory f, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, board.feedbackDigest(f));
        return abi.encodePacked(r, s, v);
    }

    function _receipt(uint256 id) internal {
        QuorumBoard.Feedback memory f = _feedback(id);
        board.recordFeedback(f, _signature(f, _key(id)));
    }

    function _hours(uint256 n, uint256 hours_) internal {
        for (uint256 h; h < hours_; ++h) {
            _anchor();
            for (uint256 i = 1; i <= n; ++i) {
                _receipt(i);
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
    }

    function _active(uint256 n) internal {
        _enrollN(n);
        _hours(n, 24);
    }

    function _call(address to, bytes memory data)
        internal
        pure
        returns (QuorumGovernance.Action[] memory list)
    {
        list = new QuorumGovernance.Action[](1);
        list[0] = QuorumGovernance.Action(to, 0, data, bytes32(0));
    }

    function _post(
        uint256 seat,
        QuorumGovernance.Kind kind,
        QuorumGovernance.Action[] memory calls,
        uint256 budget,
        uint256 amount,
        bytes32 workHash,
        bytes32 bundle
    ) internal returns (uint256) {
        bytes32 commitment = gov.proposalCommitment(
            seat, gov.proposalCount() + 1, kind, calls, budget, amount, workHash, bundle
        );
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        uint256 nonce = gov.proposalCount() + 1;
        vm.prank(s.agent);
        return board.post(
            seat,
            s.version,
            QuorumBoard.PostKind.Proposal,
            nonce,
            0,
            commitment,
            "Readable test proposal: deliver a verifiable artifact within the stated scope and budget."
        );
    }

    function _major(uint256 seat, QuorumGovernance.Action[] memory calls, bytes32 workHash)
        internal
        returns (uint256 id)
    {
        uint256 postId = _post(seat, QuorumGovernance.Kind.Major, calls, 0, 0, workHash, bytes32(0));
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        vm.prank(s.agent);
        id = gov.proposeMajor(seat, s.version, postId, calls, workHash);
    }

    function _vote(uint256 id, uint256 seat, QuorumGovernance.Choice choice) internal {
        vm.prank(_agent(seat));
        gov.vote(id, seat, 1, choice, keccak256("test rationale"));
    }

    function _yes(uint256 id, uint256 n) internal {
        for (uint256 i = 1; i <= n; ++i) {
            _vote(id, i, QuorumGovernance.Choice.Yes);
        }
    }

    function _handoverProposal() internal returns (uint256 id) {
        _ownerCall(address(safe), abi.encodeCall(safe.enableModule, (address(gov))));
        bytes32 bundle = gov.handoverCommitment();
        vm.prank(founder);
        gov.founderAccept(bundle);
        QuorumGovernance.Action[] memory empty = new QuorumGovernance.Action[](0);
        uint256 postId = _post(1, QuorumGovernance.Kind.Handover, empty, 0, 0, bytes32(0), bundle);
        vm.prank(_agent(1));
        id = gov.proposeHandover(1, 1, postId);
    }

    function _handover() internal {
        uint256 id = _handoverProposal();
        _yes(id, 7);
        vm.warp(gov.getProposal(id).executableAt);
        gov.execute(id);
        assertTrue(gov.handedOver());
        gov.assertBound();
    }
}
