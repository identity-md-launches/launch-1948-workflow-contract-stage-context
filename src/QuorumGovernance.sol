// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuorumSafePolicy} from "./QuorumSafePolicy.sol";
import {ISafe, IERC20, ReentrancyLock} from "./Interfaces.sol";
import {QuorumSeats} from "./QuorumSeats.sol";
import {QuorumBoard} from "./QuorumBoard.sol";
import {QuorumAssembly} from "./QuorumAssembly.sol";

/// @notice Immutable one-seat-one-vote governance, timelock, Safe module and BOTH Safe 1.5 guards.
contract QuorumGovernance is ReentrancyLock {
    error WrongChain();
    error InexactBudgetTransfer();
    error ActionCount();
    error ActionInvalid();
    error AddressInvalid();
    error BootstrapOnly();
    error BudgetAssetInvalid();
    error BudgetInvalid();
    error BudgetUnavailable();
    error BundleMismatch();
    error ConfigurationMismatch();
    error FounderAcceptanceRequired();
    error GenesisTooSmall();
    error HandoverChanged();
    error LiveProposalExists();
    error ModuleCallbackInvalid();
    error ModulePathDisabled();
    error NotExecutable();
    error NotInElectorate();
    error OnlyBootstrapFounder();
    error OnlyGovernanceModule();
    error OnlyMajorExecution();
    error OnlySafe();
    error OwnerPathDisabled();
    error ProposalPostMismatch();
    error ProposerInactive();
    error SafeExecutionFailed();
    error SafeHashInvalid();
    error SafeMutationForbidden();
    error SpendReturnedFalse();
    error TargetNotContract();
    error UnauthorizedCall();
    error UnexpectedReturn();
    error VoteClosedOrDuplicate();
    error VoteFeedbackMismatch();
    error VoteUnauthorized();
    error WorkAcceptanceRequired();
    error WorkBindingInvalid();

    uint256 public constant MAX_ACTIONS = 8;
    uint256 public constant MAX_CALLDATA = 4096;
    uint256 public constant EXECUTION_GRACE = 14 days;
    uint256 public constant ORDINARY_VOTE = 48 hours;
    uint256 public constant MAJOR_VOTE = 72 hours;
    uint256 public constant ORDINARY_DELAY = 24 hours;
    uint256 public constant MAJOR_DELAY = 48 hours;
    bytes32 public constant RULES_HASH = keccak256(
        "QUORUM/v1:128-seats;18/24;ordinary48h,q20%min5,yes>no,delay24h;major72h,qceilN/3min5,yes>=2/3cast,delay48h;genesis10seats5owners,yes>=2/3N;exit7d;grace14d"
    );
    address private constant SENTINEL = address(1);
    QuorumSeats public immutable seats;
    uint256 public immutable deploymentChainId;
    QuorumBoard public immutable board;
    QuorumAssembly public immutable assemblyBook;
    ISafe public immutable safe;
    address public immutable founder;
    QuorumSafePolicy public immutable safePolicy;
    bool public handedOver;
    bytes32 public founderAcceptance;
    uint256 public proposalCount;
    uint256 public budgetCount;
    uint256 public executingProposal;
    bytes32 private authorizedCall;
    bool private installing;
    bool private moduleInFlight;

    enum Kind {
        Ordinary,
        Major,
        Handover
    }
    enum Choice {
        No,
        Yes,
        Abstain
    }

    struct Action {
        address target;
        uint256 value;
        bytes data;
        bytes32 expectedReturnHash;
    }

    struct Proposal {
        uint256 proposer;
        uint256 postId;
        uint256 snapshot;
        bytes32 workHash;
        Kind kind;
        uint64 start;
        uint64 end;
        uint64 executableAt;
        uint64 expires;
        uint32 electorate;
        uint32 ownerDiversity;
        uint32 yes;
        uint32 no;
        uint32 abstain;
        bool executed;
        bytes32 commitment;
        bytes32 constitution;
        bytes32 handoverBundle;
        uint256 budget;
        uint256 amount;
    }

    struct Budget {
        address asset;
        address recipient;
        uint256 cap;
        uint256 spent;
        uint64 expires;
        bytes32 purpose;
    }
    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Action[]) private actions;
    mapping(uint256 => mapping(uint256 => bool)) public hasVoted;
    mapping(uint256 => uint256) public liveProposal;
    mapping(uint256 => Budget) public budgets;
    mapping(uint256 => bool) public usedPost;

    event FounderAccepted(bytes32 indexed bundle);
    event Proposed(
        uint256 indexed id,
        uint256 indexed seat,
        Kind kind,
        uint256 postId,
        bytes32 commitment,
        uint32 electorate,
        uint64 voteEnd,
        uint64 executableAt
    );
    event Voted(uint256 indexed proposal, uint256 indexed seat, Choice choice, bytes32 rationaleHash);
    event BudgetApproved(
        uint256 indexed id,
        address indexed asset,
        address indexed recipient,
        uint256 cap,
        bytes32 purpose,
        uint64 expires
    );
    event Executed(uint256 indexed proposal, bytes32 indexed commitment);
    event HandedOver(uint256 indexed proposal, bytes32 indexed bundle);

    constructor(
        address seats_,
        address board_,
        address assembly_,
        address safe_,
        address founder_,
        address safePolicy_
    ) {
        require(
            assembly_ != address(0) && seats_ != address(0) && board_ != address(0) && safe_ != address(0)
                && founder_ != address(0),
            AddressInvalid()
        );
        require(safePolicy_ != address(0), SafeHashInvalid());
        seats = QuorumSeats(seats_);
        board = QuorumBoard(board_);
        assemblyBook = QuorumAssembly(assembly_);
        safe = ISafe(safe_);
        founder = founder_;
        safePolicy = QuorumSafePolicy(safePolicy_);
        deploymentChainId = block.chainid;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    function getActions(uint256 id) external view returns (Action[] memory) {
        return actions[id];
    }

    function actionBinding(
        uint256 seat,
        uint256 nonce,
        Kind kind,
        Action[] memory calls,
        uint256 budget,
        uint256 amount,
        bytes32 bundle
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                nonce,
                seat,
                kind,
                keccak256(abi.encode(calls)),
                budget,
                amount,
                seats.constitutionHash(),
                RULES_HASH,
                bundle
            )
        );
    }

    function proposalCommitment(
        uint256 seat,
        uint256 nonce,
        Kind kind,
        Action[] memory calls,
        uint256 budget,
        uint256 amount,
        bytes32 workHash,
        bytes32 bundle
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(actionBinding(seat, nonce, kind, calls, budget, amount, bundle), workHash)
        );
    }

    function proposeMajor(
        uint256 seat,
        uint64 version,
        uint256 postId,
        Action[] calldata calls,
        bytes32 workHash
    ) external nonReentrant returns (uint256 id) {
        require(calls.length > 0 && calls.length <= MAX_ACTIONS, ActionCount());
        uint256 dataBytes;
        for (uint256 i; i < calls.length; ++i) {
            _validateAction(calls[i]);
            dataBytes += calls[i].data.length;
        }
        require(dataBytes <= MAX_CALLDATA, ActionInvalid());
        id = _propose(seat, version, postId, Kind.Major, calls, 0, 0, workHash, bytes32(0));
    }

    /// @notice Ordinary proposals can ONLY spend a major-approved immutable budget.
    function proposeSpend(
        uint256 seat,
        uint64 version,
        uint256 postId,
        uint256 budgetId,
        uint256 amount,
        bytes32 workHash
    ) external nonReentrant returns (uint256 id) {
        Budget memory b = budgets[budgetId];
        require(
            b.recipient != address(0) && block.timestamp < b.expires && amount != 0
                && amount <= b.cap - b.spent,
            BudgetUnavailable()
        );
        Action[] memory calls = spendingAction(budgetId, amount);
        id = _propose(seat, version, postId, Kind.Ordinary, calls, budgetId, amount, workHash, bytes32(0));
    }

    function spendingAction(uint256 budgetId, uint256 amount) public view returns (Action[] memory calls) {
        Budget memory b = budgets[budgetId];
        calls = new Action[](1);
        calls[0] = b.asset == address(0)
            ? Action(b.recipient, amount, bytes(""), bytes32(0))
            : Action(b.asset, 0, abi.encodeCall(IERC20.transfer, (b.recipient, amount)), bytes32(0));
    }

    function proposeHandover(uint256 seat, uint64 version, uint256 postId)
        external
        nonReentrant
        returns (uint256 id)
    {
        require(
            !handedOver && founderAcceptance != bytes32(0) && founderAcceptance == handoverCommitment(),
            FounderAcceptanceRequired()
        );
        Action[] memory calls = new Action[](0);
        id = _propose(seat, version, postId, Kind.Handover, calls, 0, 0, bytes32(0), founderAcceptance);
        require(proposals[id].electorate >= 10 && proposals[id].ownerDiversity >= 5, GenesisTooSmall());
    }

    function _propose(
        uint256 seat,
        uint64 version,
        uint256 postId,
        Kind kind,
        Action[] memory calls,
        uint256 budget,
        uint256 amount,
        bytes32 workHash,
        bytes32 bundle
    ) internal returns (uint256 id) {
        require(
            address(board.seats()) == address(seats) && address(assemblyBook.seats()) == address(seats)
                && address(assemblyBook.board()) == address(board) && seats.owner() == address(safe),
            ConfigurationMismatch()
        );
        require(
            board.active(seat) && seats.validAgent(seat, msg.sender, version, seats.GOVERNANCE()),
            ProposerInactive()
        );
        uint256 previous = liveProposal[seat];
        if (previous != 0) {
            Proposal storage old = proposals[previous];
            require(
                old.executed || block.timestamp > old.expires
                    || (block.timestamp >= old.end && !passed(previous)),
                LiveProposalExists()
            );
        }
        id = ++proposalCount;
        bytes32 commitment = proposalCommitment(seat, id, kind, calls, budget, amount, workHash, bundle);
        QuorumBoard.Post memory post = board.getPost(postId);
        require(
            !usedPost[postId] && post.kind == QuorumBoard.PostKind.Proposal && post.proposal == id
                && post.seat == seat && post.version == version && post.commitment == commitment,
            ProposalPostMismatch()
        );
        usedPost[postId] = true;
        Proposal storage p = proposals[id];
        p.proposer = seat;
        p.postId = postId;
        p.kind = kind;
        p.start = uint64(block.timestamp);
        p.end = uint64(block.timestamp + (kind == Kind.Ordinary ? ORDINARY_VOTE : MAJOR_VOTE));
        p.executableAt = uint64(p.end + (kind == Kind.Ordinary ? ORDINARY_DELAY : MAJOR_DELAY));
        p.expires = uint64(p.executableAt + EXECUTION_GRACE);
        p.commitment = commitment;
        p.constitution = seats.constitutionHash();
        p.handoverBundle = bundle;
        p.budget = budget;
        p.amount = amount;
        p.workHash = workHash;
        require(
            workHash == bytes32(0)
                || assemblyBook.validateWork(
                    workHash, actionBinding(seat, id, kind, calls, budget, amount, bundle), p.executableAt
                ),
            WorkBindingInvalid()
        );
        for (uint256 i; i < calls.length; ++i) {
            actions[id].push(calls[i]);
        }
        liveProposal[seat] = id;
        (p.snapshot, p.electorate, p.ownerDiversity) = assemblyBook.snapshot();
        emit Proposed(id, seat, kind, postId, commitment, p.electorate, p.end, p.executableAt);
    }

    function vote(uint256 id, uint256 seat, uint64 version, Choice choice, bytes32 rationaleHash) public {
        Proposal storage p = proposals[id];
        require(p.end != 0 && block.timestamp < p.end && !hasVoted[id][seat], VoteClosedOrDuplicate());
        require(assemblyBook.eligible(p.snapshot, seat), NotInElectorate());
        require(seats.validAgent(seat, msg.sender, version, seats.GOVERNANCE()), VoteUnauthorized());
        hasVoted[id][seat] = true;
        if (choice == Choice.Yes) ++p.yes;
        else if (choice == Choice.No) ++p.no;
        else ++p.abstain;
        emit Voted(id, seat, choice, rationaleHash);
    }

    function voteWithFeedback(
        uint256 id,
        uint256 seat,
        uint64 version,
        Choice choice,
        bytes32 rationaleHash,
        QuorumBoard.Feedback calldata feedback,
        bytes calldata signature
    ) external {
        require(
            feedback.seat == seat && feedback.authorizationVersion == version
                && feedback.status == QuorumBoard.Status.Voted,
            VoteFeedbackMismatch()
        );
        vote(id, seat, version, choice, rationaleHash);
        board.recordFeedback(feedback, signature);
    }

    function quorum(uint256 id) public view returns (uint256 result) {
        Proposal storage p = proposals[id];
        result = p.kind == Kind.Ordinary ? (uint256(p.electorate) + 4) / 5 : (uint256(p.electorate) + 2) / 3;
        if (result < 5) result = 5;
    }

    function passed(uint256 id) public view returns (bool) {
        Proposal storage p = proposals[id];
        if (p.end == 0 || uint256(p.yes) + p.no + p.abstain < quorum(id)) return false;
        if (p.kind == Kind.Handover) return p.yes > 0 && uint256(p.yes) * 3 >= uint256(p.electorate) * 2;
        if (p.kind == Kind.Major) return p.yes > 0 && uint256(p.yes) * 3 >= (uint256(p.yes) + p.no) * 2;
        return p.yes > p.no;
    }

    function execute(uint256 id) external nonReentrant {
        require(block.chainid == deploymentChainId, WrongChain());
        Proposal storage p = proposals[id];
        require(
            !p.executed && passed(id) && block.timestamp >= p.executableAt && block.timestamp <= p.expires,
            NotExecutable()
        );
        require(assemblyBook.workAccepted(p.workHash), WorkAcceptanceRequired());
        p.executed = true;
        executingProposal = id;
        if (p.kind == Kind.Handover) {
            _handover(id);
        } else {
            require(handedOver, BootstrapOnly());
            _assertBound();
            if (p.kind == Kind.Ordinary) {
                Budget storage b = budgets[p.budget];
                require(block.timestamp < b.expires && p.amount <= b.cap - b.spent, BudgetUnavailable());
                b.spent += p.amount;
            }
            Action[] storage calls = actions[id];
            for (uint256 i; i < calls.length; ++i) {
                Action storage a = calls[i];
                _validateAction(a);
                uint256 senderBefore;
                uint256 recipientBefore;
                Budget memory budget = budgets[p.budget];
                bool tokenSpend = p.kind == Kind.Ordinary && budget.asset != address(0);
                if (tokenSpend) {
                    senderBefore = IERC20(budget.asset).balanceOf(address(safe));
                    recipientBefore = IERC20(budget.asset).balanceOf(budget.recipient);
                }
                bytes memory result = _safeCall(a.target, a.value, a.data);
                if (a.expectedReturnHash != bytes32(0)) {
                    require(keccak256(result) == a.expectedReturnHash, UnexpectedReturn());
                }
                if (tokenSpend) {
                    require(
                        result.length == 0 || (result.length == 32 && abi.decode(result, (bool))),
                        SpendReturnedFalse()
                    );
                    require(
                        senderBefore >= p.amount
                            && IERC20(budget.asset).balanceOf(address(safe)) == senderBefore - p.amount
                            && IERC20(budget.asset).balanceOf(budget.recipient) == recipientBefore + p.amount,
                        InexactBudgetTransfer()
                    );
                }
            }
            _assertBound();
        }
        executingProposal = 0;
        emit Executed(id, p.commitment);
    }

    function majorExecuting() public view returns (bool) {
        return handedOver && executingProposal != 0 && proposals[executingProposal].kind == Kind.Major;
    }

    function approveBudget(address asset, address recipient, uint256 cap, bytes32 purpose, uint64 expires)
        external
    {
        require(msg.sender == address(safe) && majorExecuting(), OnlyMajorExecution());
        require(
            recipient != address(0) && recipient != address(safe) && cap != 0 && purpose != bytes32(0)
                && expires > block.timestamp,
            BudgetInvalid()
        );
        require(asset == address(0) || asset.code.length != 0, BudgetAssetInvalid());
        uint256 id = ++budgetCount;
        budgets[id] = Budget(asset, recipient, cap, 0, expires, purpose);
        emit BudgetApproved(id, asset, recipient, cap, purpose, expires);
    }

    /// @notice Acceptance binds actual deployed code, frozen admission data, constitution and final Safe configuration.
    function handoverCommitment() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                address(this).codehash,
                address(seats),
                address(seats).codehash,
                address(board),
                address(board).codehash,
                address(assemblyBook),
                address(assemblyBook).codehash,
                address(seats.token()),
                address(seats.token()).codehash,
                address(safe),
                founder,
                address(safePolicy),
                address(safePolicy).codehash,
                seats.configurationHash(),
                seats.constitutionHash(),
                RULES_HASH
            )
        );
    }

    function founderAccept(bytes32 exactBundle) external {
        require(msg.sender == founder && !handedOver, OnlyBootstrapFounder());
        require(
            seats.configurationHash() != bytes32(0) && address(board.seats()) == address(seats)
                && address(assemblyBook.seats()) == address(seats)
                && address(assemblyBook.board()) == address(board) && seats.owner() == address(safe),
            ConfigurationMismatch()
        );
        _assertBootstrap(false);
        require(exactBundle == handoverCommitment(), BundleMismatch());
        founderAcceptance = exactBundle;
        emit FounderAccepted(exactBundle);
    }

    function _handover(uint256 id) internal {
        Proposal storage p = proposals[id];
        require(
            !handedOver && p.handoverBundle == founderAcceptance && founderAcceptance == handoverCommitment(),
            HandoverChanged()
        );
        require(p.electorate >= 10 && p.ownerDiversity >= 5, GenesisTooSmall());
        _assertBootstrap(true);
        installing = true;
        _safeCall(address(safe), 0, abi.encodeWithSignature("setGuard(address)", address(this)));
        _safeCall(address(safe), 0, abi.encodeWithSignature("setModuleGuard(address)", address(this)));
        _safeCall(
            address(safe),
            0,
            abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL, founder, address(this))
        );
        installing = false;
        handedOver = true;
        _assertBound();
        emit HandedOver(id, founderAcceptance);
    }

    function _safeCall(address target, uint256 value, bytes memory data)
        internal
        returns (bytes memory result)
    {
        authorizedCall = keccak256(abi.encode(target, value, data));
        bool success;
        (success, result) = safe.execTransactionFromModuleReturnData(target, value, data, 0);
        require(success, SafeExecutionFailed());
        authorizedCall = bytes32(0);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0xe6d7a83a || id == 0x58401ed8;
    }

    /// @dev Owner transactions, refunds included, are categorically disabled after handover.
    function checkTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata,
        address
    ) external view {
        require(msg.sender == address(safe), OnlySafe());
        require(!handedOver && !installing, OwnerPathDisabled());
    }

    function checkAfterExecution(bytes32, bool) external view {
        require(msg.sender == address(safe), OnlySafe());
        if (handedOver) _assertBound();
    }

    function checkModuleTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        address module
    ) external returns (bytes32 hash) {
        require(msg.sender == address(safe) && module == address(this), OnlyGovernanceModule());
        require(
            (handedOver || installing) && operation == 0 && !moduleInFlight && authorizedCall != bytes32(0),
            ModulePathDisabled()
        );
        require(installing || target != address(safe), SafeMutationForbidden());
        hash = keccak256(abi.encode(target, value, data));
        require(hash == authorizedCall, UnauthorizedCall());
        moduleInFlight = true;
    }

    function checkAfterModuleExecution(bytes32 hash, bool) external {
        require(
            msg.sender == address(safe) && moduleInFlight && hash == authorizedCall, ModuleCallbackInvalid()
        );
        moduleInFlight = false;
        if (handedOver) _assertBound();
    }

    function assertBound() external view {
        require(handedOver, BootstrapOnly());
        _assertBound();
    }

    function _assertBootstrap(bool needsModule) internal view {
        require(
            address(safePolicy.safe()) == address(safe) && safePolicy.founder() == founder,
            ConfigurationMismatch()
        );
        safePolicy.assertBootstrap(address(this), needsModule);
    }

    function _assertBound() internal view {
        safePolicy.assertBound(address(this));
    }

    function _validateAction(Action memory a) internal view {
        require(
            a.target != address(0) && a.target != address(safe) && a.data.length <= MAX_CALLDATA,
            ActionInvalid()
        );
        require(a.data.length == 0 || a.target.code.length != 0, TargetNotContract());
    }
}
