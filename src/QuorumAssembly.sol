// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuorumSeats} from "./QuorumSeats.sol";
import {QuorumBoard} from "./QuorumBoard.sol";

/// @notice Bounded atomic electorates and explicit acceptance of exact, readable work specifications.
contract QuorumAssembly {
    uint256 public constant MAX_ACCEPTORS = 16;
    QuorumSeats public immutable seats;
    QuorumBoard public immutable board;
    uint256 public snapshotCount;

    struct Elector {
        address owner;
        uint64 generation;
    }

    struct Snapshot {
        address creator;
        uint64 timestamp;
        uint32 count;
        uint32 owners;
    }

    struct Work {
        bytes32 actionBinding;
        address beneficiary;
        uint64 deadline;
        string benefit;
        string scope;
        string resources;
        string acceptance;
    }

    struct Acceptance {
        uint256 seat;
        uint64 version;
        uint64 generation;
        address agent;
    }
    mapping(uint256 => Snapshot) public snapshots;
    mapping(uint256 => mapping(uint256 => Elector)) public electorate;
    mapping(bytes32 => Work) private works;
    mapping(bytes32 => Acceptance[]) private acceptors;
    event ElectorateFrozen(
        uint256 indexed snapshot, address indexed creator, uint256[] seatIds, uint32 owners
    );
    event WorkRegistered(
        bytes32 indexed workHash,
        bytes32 indexed actionBinding,
        address indexed beneficiary,
        uint64 deadline,
        string benefit,
        string scope,
        string resources,
        string acceptance
    );
    event WorkAccepted(bytes32 indexed workHash, uint256 indexed seat, uint64 version);
    event AcceptanceRevoked(bytes32 indexed workHash, uint256 indexed seat);

    constructor(address seats_, address board_) {
        require(seats_ != address(0) && board_ != address(0), "ConfigurationInvalid");
        seats = QuorumSeats(seats_);
        board = QuorumBoard(board_);
    }

    /// @notice Callers cannot supply a subset; the whole current eligible electorate is frozen.
    /// Governance calls this in the very transaction that opens voting.
    function snapshot() external returns (uint256 id, uint32 count, uint32 diversity) {
        require(address(board.seats()) == address(seats), "ConfigurationMismatch");
        uint256 length = seats.depositedCount();
        require(length <= seats.MAX_SEATS(), "SeatBound");
        uint256[] memory ids = new uint256[](length);
        address[5] memory owners;
        id = ++snapshotCount;
        for (uint256 i; i < length; ++i) {
            uint256 seat = seats.depositedSeatAt(i);
            if (!board.active(seat)) continue;
            QuorumSeats.Seat memory s = seats.getSeat(seat);
            electorate[id][seat] = Elector(s.depositor, s.generation);
            ids[count++] = seat;
            if (diversity < 5) {
                bool known;
                for (uint256 j; j < diversity; ++j) {
                    if (owners[j] == s.depositor) known = true;
                }
                if (!known) owners[diversity++] = s.depositor;
            }
        }
        assembly ("memory-safe") { mstore(ids, count) }
        snapshots[id] = Snapshot(msg.sender, uint64(block.timestamp), count, diversity);
        emit ElectorateFrozen(id, msg.sender, ids, diversity);
    }

    function eligible(uint256 snapshotId, uint256 seat) external view returns (bool) {
        Elector memory e = electorate[snapshotId][seat];
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        return e.owner != address(0) && s.depositor == e.owner && s.generation == e.generation
            && seats.isDeposited(seat);
    }

    /// @notice Registering content grants no spending or execution authority.
    function registerWork(Work calldata w) external returns (bytes32 hash) {
        require(
            w.actionBinding != bytes32(0) && w.beneficiary != address(0) && w.deadline > block.timestamp,
            "WorkInvalid"
        );
        require(
            bytes(w.benefit).length > 0 && bytes(w.scope).length > 0 && bytes(w.resources).length > 0
                && bytes(w.acceptance).length > 0,
            "WorkIncomplete"
        );
        require(
            bytes(w.benefit).length <= 1024 && bytes(w.scope).length <= 2048
                && bytes(w.resources).length <= 1024 && bytes(w.acceptance).length <= 2048,
            "WorkTooLong"
        );
        hash = keccak256(abi.encode(block.chainid, address(this), w));
        require(works[hash].beneficiary == address(0), "WorkAlreadyRegistered");
        works[hash] = w;
        emit WorkRegistered(
            hash, w.actionBinding, w.beneficiary, w.deadline, w.benefit, w.scope, w.resources, w.acceptance
        );
    }

    function getWork(bytes32 hash) external view returns (Work memory) {
        return works[hash];
    }

    function getAcceptors(bytes32 hash) external view returns (Acceptance[] memory) {
        return acceptors[hash];
    }

    function validateWork(bytes32 hash, bytes32 binding, uint256 executionTime) external view returns (bool) {
        Work storage w = works[hash];
        return w.beneficiary != address(0) && w.actionBinding == binding && w.deadline > executionTime;
    }

    function acceptWork(bytes32 hash, uint256 seat, uint64 version) external {
        Work storage w = works[hash];
        require(w.beneficiary != address(0) && block.timestamp < w.deadline, "WorkUnavailable");
        require(
            board.active(seat) && seats.validAgent(seat, msg.sender, version, seats.GOVERNANCE()),
            "AcceptorInactive"
        );
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        Acceptance[] storage list = acceptors[hash];
        uint256 vacant = type(uint256).max;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].seat == seat) {
                vacant = i;
                break;
            }
            if (!_validAcceptance(list[i])) vacant = i;
        }
        Acceptance memory a = Acceptance(seat, version, s.generation, msg.sender);
        if (vacant != type(uint256).max) {
            list[vacant] = a;
        } else {
            require(list.length < MAX_ACCEPTORS, "AcceptorLimit");
            list.push(a);
        }
        emit WorkAccepted(hash, seat, version);
    }

    function revokeAcceptance(bytes32 hash, uint256 seat) external {
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        require(msg.sender == s.depositor || msg.sender == s.agent, "AcceptanceUnauthorized");
        Acceptance[] storage list = acceptors[hash];
        for (uint256 i; i < list.length; ++i) {
            if (list[i].seat == seat) {
                list[i].agent = address(0);
                emit AcceptanceRevoked(hash, seat);
            }
        }
    }

    function workAccepted(bytes32 hash) external view returns (bool) {
        if (hash == bytes32(0)) return true;
        if (block.timestamp >= works[hash].deadline) return false;
        Acceptance[] storage list = acceptors[hash];
        for (uint256 i; i < list.length; ++i) {
            if (_validAcceptance(list[i])) return true;
        }
        return false;
    }

    function _validAcceptance(Acceptance memory a) internal view returns (bool) {
        QuorumSeats.Seat memory s = seats.getSeat(a.seat);
        return seats.isDeposited(a.seat) && s.exitAt == 0 && s.generation == a.generation
            && seats.validAgent(a.seat, a.agent, a.version, seats.GOVERNANCE());
    }
}
