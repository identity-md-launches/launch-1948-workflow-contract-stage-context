// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuorumSeats} from "./QuorumSeats.sol";
import {Signatures} from "./Interfaces.sol";

/// @notice Onchain readable discussion and authenticated, hour-bound participation receipts.
contract QuorumBoard {
    uint256 public constant MAX_MESSAGE_BYTES = 2048;
    uint256 public constant MAX_PAGE = 50;
    uint256 public constant MIN_CONFIRMATIONS = 12;
    uint256 public constant MAX_ANCHOR_AGE = 128;
    uint256 public constant ACTIVE_HOURS = 18;
    uint256 public constant WINDOW_HOURS = 24;
    bytes32 public constant FEEDBACK_TYPEHASH = keccak256(
        "Feedback(uint256 seat,uint64 authorizationVersion,uint64 generation,uint64 hour,uint64 anchorBlock,bytes32 anchorHash,uint64 revision,bytes32 contentHash,uint8 status)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    QuorumSeats public immutable seats;

    enum Status {
        NoNewMatters,
        Read,
        PreparingResponse,
        Voted
    }
    enum PostKind {
        Discussion,
        Proposal,
        Reply,
        Opinion,
        VoteRationale
    }

    struct Feedback {
        uint256 seat;
        uint64 authorizationVersion;
        uint64 generation;
        uint64 hour;
        uint64 anchorBlock;
        bytes32 anchorHash;
        uint64 revision;
        bytes32 contentHash;
        Status status;
    }

    struct Attendance {
        uint64 hour;
        uint64 version;
        uint64 generation;
        uint32 mask;
    }

    struct Post {
        uint256 seat;
        uint64 version;
        uint64 timestamp;
        PostKind kind;
        uint256 proposal;
        uint256 parent;
        bytes32 commitment;
        string body;
    }

    struct Revision {
        uint64 blockNumber;
        bytes32 contentHash;
    }

    mapping(uint256 => Attendance) public attendance;
    // hour+1 reserves zero for an unseen seat, and survives rotations and re-deposits.
    mapping(uint256 => uint64) public lastCreditedHourPlusOne;
    Post[] private posts;
    Revision[] private revisions;
    event FeedbackRecorded(
        uint256 indexed seat,
        uint64 indexed hour,
        uint64 authorizationVersion,
        uint64 generation,
        uint64 anchorBlock,
        bytes32 anchorHash,
        uint64 revision,
        bytes32 contentHash,
        Status status
    );
    event Posted(
        uint256 indexed postId,
        uint256 indexed seat,
        uint256 indexed proposal,
        PostKind kind,
        uint256 parent,
        bytes32 commitment,
        string body
    );
    event ContentRevised(uint64 indexed revision, bytes32 indexed contentHash, uint64 blockNumber);

    constructor(address seats_) {
        require(seats_ != address(0), "SeatsInvalid");
        seats = QuorumSeats(seats_);
        revisions.push(Revision(uint64(block.number), keccak256("QUORUM board v1")));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("QUORUM Feedback"), keccak256("1"), block.chainid, address(this)
            )
        );
    }

    function feedbackDigest(Feedback calldata f) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator(), keccak256(abi.encode(FEEDBACK_TYPEHASH, f)))
        );
    }

    /// @notice A receipt must be mined in its signed chain hour. Anyone may forward it;
    /// the connector normally sends and pays for its own transaction.
    function recordFeedback(Feedback calldata f, bytes calldata signature) public {
        address signer = Signatures.recover(feedbackDigest(f), signature);
        require(
            seats.validAgent(f.seat, signer, f.authorizationVersion, seats.FEEDBACK()), "FeedbackUnauthorized"
        );
        QuorumSeats.Seat memory s = seats.getSeat(f.seat);
        require(seats.isDeposited(f.seat) && s.generation == f.generation, "FeedbackNotStaked");
        require(f.hour == block.timestamp / 1 hours, "FeedbackWrongHour");
        require(lastCreditedHourPlusOne[f.seat] != f.hour + 1, "AlreadyCredited");
        require(
            f.anchorBlock < block.number && block.number - f.anchorBlock >= MIN_CONFIRMATIONS
                && block.number - f.anchorBlock <= MAX_ANCHOR_AGE,
            "AnchorAge"
        );
        require(f.anchorHash != bytes32(0) && blockhash(f.anchorBlock) == f.anchorHash, "AnchorHash");
        require(
            f.revision == revisionAtBlock(f.anchorBlock)
                && revisions[f.revision].contentHash == f.contentHash,
            "ContentRevision"
        );
        Attendance storage a = attendance[f.seat];
        uint32 mask;
        if (
            a.version == f.authorizationVersion && a.generation == f.generation && f.hour >= a.hour
                && f.hour - a.hour < 25
        ) {
            mask = uint32((uint256(a.mask) << (f.hour - a.hour)) & 0x1ffffff);
        }
        a.hour = f.hour;
        a.version = f.authorizationVersion;
        a.generation = f.generation;
        a.mask = mask | 1;
        lastCreditedHourPlusOne[f.seat] = f.hour + 1;
        emit FeedbackRecorded(
            f.seat,
            f.hour,
            f.authorizationVersion,
            f.generation,
            f.anchorBlock,
            f.anchorHash,
            f.revision,
            f.contentHash,
            f.status
        );
    }

    /// @notice Counts ONLY the previous 24 completed chain hours, with constant work.
    function completedHours(uint256 seat) public view returns (uint256 count) {
        Attendance memory a = attendance[seat];
        QuorumSeats.Seat memory s = seats.getSeat(seat);
        uint256 hour = block.timestamp / 1 hours;
        if (a.version != s.version || a.generation != s.generation || hour < a.hour || hour - a.hour > 24) {
            return 0;
        }
        uint256 mask = ((uint256(a.mask) << (hour - a.hour)) >> 1) & 0xffffff;
        // Brian Kernighan's count has at most 24 iterations.
        while (mask != 0) {
            mask &= mask - 1;
            ++count;
        }
    }

    function active(uint256 seat) public view returns (bool) {
        return seats.qualified(seat) && completedHours(seat) >= ACTIVE_HOURS;
    }

    function post(
        uint256 seat,
        uint64 version,
        PostKind kind,
        uint256 proposal,
        uint256 parent,
        bytes32 commitment,
        string calldata body
    ) public returns (uint256 id) {
        require(
            seats.validAgent(seat, msg.sender, version, seats.DISCUSSION()) && seats.isDeposited(seat),
            "PostUnauthorized"
        );
        require(bytes(body).length != 0 && bytes(body).length <= MAX_MESSAGE_BYTES, "MessageLength");
        require(parent <= posts.length && (kind != PostKind.Reply || parent != 0), "ParentInvalid");
        require(kind != PostKind.Proposal || commitment != bytes32(0), "ProposalCommitment");
        posts.push(Post(seat, version, uint64(block.timestamp), kind, proposal, parent, commitment, body));
        id = posts.length;
        bytes32 nextHash = keccak256(
            abi.encode(
                revisions[revisions.length - 1].contentHash,
                id,
                seat,
                version,
                kind,
                proposal,
                parent,
                commitment,
                keccak256(bytes(body))
            )
        );
        revisions.push(Revision(uint64(block.number), nextHash));
        emit Posted(id, seat, proposal, kind, parent, commitment, body);
        emit ContentRevised(uint64(revisions.length - 1), nextHash, uint64(block.number));
    }

    function postWithFeedback(
        uint256 seat,
        uint64 version,
        PostKind kind,
        uint256 proposal,
        uint256 parent,
        bytes32 commitment,
        string calldata body,
        Feedback calldata feedback,
        bytes calldata signature
    ) external returns (uint256) {
        require(feedback.seat == seat && feedback.authorizationVersion == version, "FeedbackSeatMismatch");
        recordFeedback(feedback, signature);
        return post(seat, version, kind, proposal, parent, commitment, body);
    }

    function postCount() external view returns (uint256) {
        return posts.length;
    }

    function getPost(uint256 id) external view returns (Post memory) {
        require(id != 0, "PostInvalid");
        return posts[id - 1];
    }

    function getPosts(uint256 offset, uint256 limit) external view returns (Post[] memory result) {
        require(limit <= MAX_PAGE && offset <= posts.length, "PageBounds");
        uint256 length = posts.length - offset;
        if (length > limit) length = limit;
        result = new Post[](length);
        for (uint256 i; i < length; ++i) {
            result[i] = posts[offset + i];
        }
    }

    function latestRevision() external view returns (uint64) {
        return uint64(revisions.length - 1);
    }

    function getRevision(uint256 revision) external view returns (Revision memory) {
        return revisions[revision];
    }

    function revisionAtBlock(uint256 blockNumber) public view returns (uint64) {
        require(blockNumber >= revisions[0].blockNumber, "BeforeDeployment");
        uint256 lo;
        uint256 hi = revisions.length;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (revisions[mid].blockNumber <= blockNumber) lo = mid;
            else hi = mid;
        }
        return uint64(lo);
    }
}
