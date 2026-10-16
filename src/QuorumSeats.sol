// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ISeatNFT, TokenCall, ReentrancyLock} from "./Interfaces.sol";

/// @notice Refundable fixed stakes and owner-scoped, separately accepted agent authority.
/// @dev Exact-token NFT approval is a transfer fuse: ERC-721 transfers clear it. This contract
///      has no NFT transfer function and never uses an operator approval in its place.
contract QuorumSeats is ReentrancyLock {
    uint256 public constant MAX_SEATS = 128;
    uint64 public constant ACTIVATION_DELAY = 24 hours;
    uint64 public constant EXIT_DELAY = 7 days;
    uint64 public constant MAX_AUTHORIZATION = 365 days;
    uint8 public constant FEEDBACK = 1;
    uint8 public constant GOVERNANCE = 2;
    uint8 public constant DISCUSSION = 4;
    uint8 public constant STAKE = 8;
    uint256 public constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    address public immutable owner;
    IERC20 public immutable token;
    ISeatNFT public nft;
    uint256 public connectedAtAdmission;
    uint256 public stakeAmount;
    uint256 public totalDeposited;
    bytes32 public admissionHash;
    string public admissionSource;
    bytes32 public constitutionHash;
    bytes32 public configurationHash;

    struct Seat {
        address depositor;
        address agent;
        uint64 version;
        uint64 expires;
        uint8 scopes;
        bytes32 acceptedConstitution;
        uint256 stakeLimit;
        uint64 activationAt;
        uint64 exitAt;
        uint64 generation;
    }

    mapping(uint256 => Seat) private seats;
    mapping(address => uint256) private keySeatPlusOne;
    uint256[] private depositedSeats;
    mapping(uint256 => uint256) private indexPlusOne;

    event AdmissionConfigured(
        address indexed nft, uint256 connectedSeats, uint256 stake, bytes32 sourceHash, string source
    );
    event ConstitutionChanged(bytes32 indexed oldHash, bytes32 indexed newHash);
    event Authorized(
        uint256 indexed seat,
        address indexed owner,
        address indexed agent,
        uint64 version,
        uint8 scopes,
        uint64 expires,
        uint256 stakeLimit
    );
    event AgentAccepted(uint256 indexed seat, uint64 version, bytes32 constitution, bool hourlyCommitment);
    event AgentDeclined(uint256 indexed seat, uint64 version);
    event Revoked(uint256 indexed seat, uint64 version);
    event Deposited(
        uint256 indexed seat, address indexed owner, uint256 amount, uint64 activationAt, uint64 generation
    );
    event ExitRequested(uint256 indexed seat, uint64 availableAt);
    event Withdrawn(uint256 indexed seat, address indexed owner, uint256 amount);

    constructor(address token_, address owner_, bytes32 constitution_) {
        require(
            token_ != address(0) && owner_ != address(0) && constitution_ != bytes32(0),
            "InvalidConfiguration"
        );
        token = IERC20(token_);
        owner = owner_;
        constitutionHash = constitution_;
    }

    /// @notice The launch Safe verifies the canonical NFT and the service's fixed admission dataset.
    /// No deposit is possible until this one-time, publicly evidenced configuration succeeds.
    function configureAdmission(address nft_, uint256 count, bytes32 sourceHash, string calldata source)
        external
    {
        require(msg.sender == owner, "OnlyOwner");
        require(configurationHash == bytes32(0), "AdmissionFrozen");
        require(nft_.code.length != 0 && ISeatNFT(nft_).supportsInterface(0x80ac58cd), "NotERC721");
        require(
            count != 0 && sourceHash != bytes32(0) && bytes(source).length != 0
                && bytes(source).length <= 512,
            "AdmissionInvalid"
        );
        require(token.totalSupply() == EXPECTED_SUPPLY && token.decimals() == 18, "WrongLaunchToken");
        uint256 amount = (EXPECTED_SUPPLY * 750 / 10_000) / count;
        require(amount != 0, "ZeroStake");
        nft = ISeatNFT(nft_);
        connectedAtAdmission = count;
        stakeAmount = amount;
        admissionHash = sourceHash;
        admissionSource = source;
        configurationHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                address(token),
                address(token).codehash,
                nft_,
                nft_.codehash,
                count,
                amount,
                sourceHash,
                keccak256(bytes(source))
            )
        );
        emit AdmissionConfigured(nft_, count, amount, sourceHash, source);
    }

    /// @notice After handover the Safe can call this only through a major, delayed proposal.
    /// Existing frozen votes retain their electorate; future eligibility needs fresh acceptance.
    function setConstitution(bytes32 newHash) external {
        require(msg.sender == owner, "OnlyOwner");
        require(newHash != bytes32(0) && newHash != constitutionHash, "ConstitutionInvalid");
        emit ConstitutionChanged(constitutionHash, newHash);
        constitutionHash = newHash;
    }

    function getSeat(uint256 id) external view returns (Seat memory) {
        return seats[id];
    }

    function depositedCount() external view returns (uint256) {
        return depositedSeats.length;
    }

    function depositedSeatAt(uint256 index) external view returns (uint256) {
        return depositedSeats[index];
    }

    function isDeposited(uint256 id) public view returns (bool) {
        return indexPlusOne[id] != 0;
    }

    function authorize(uint256 id, address agent, uint8 scopes, uint64 expires, uint256 stakeLimit) external {
        require(configurationHash != bytes32(0), "AdmissionNotConfigured");
        require(id != type(uint256).max, "SeatIdInvalid");
        require(nft.ownerOf(id) == msg.sender && nft.getApproved(id) == address(this), "OwnerOrApproval");
        require(
            agent != address(0) && agent != msg.sender && scopes != 0 && scopes <= 15, "AuthorizationInvalid"
        );
        require(
            expires > block.timestamp && expires <= block.timestamp + MAX_AUTHORIZATION
                && stakeLimit <= stakeAmount,
            "AuthorizationBounds"
        );
        Seat storage s = seats[id];
        require(!isDeposited(id) || s.depositor == msg.sender, "StakeOutstanding");
        require(keySeatPlusOne[agent] == 0 || keySeatPlusOne[agent] == id + 1, "KeyAlreadyUsed");
        if (s.agent != address(0)) delete keySeatPlusOne[s.agent];
        s.depositor = msg.sender;
        s.agent = agent;
        ++s.version;
        s.scopes = scopes;
        s.expires = expires;
        s.stakeLimit = stakeLimit;
        s.acceptedConstitution = bytes32(0);
        keySeatPlusOne[agent] = id + 1;
        emit Authorized(id, msg.sender, agent, s.version, scopes, expires, stakeLimit);
    }

    function accept(uint256 id, uint64 version, bytes32 constitution, bool hourlyCommitment) external {
        Seat storage s = seats[id];
        require(_authority(id, s, msg.sender, version, 0), "UnauthorizedAgent");
        require(hourlyCommitment && constitution == constitutionHash, "AcceptanceInvalid");
        s.acceptedConstitution = constitution;
        emit AgentAccepted(id, version, constitution, true);
    }

    function decline(uint256 id, uint64 version) external {
        Seat storage s = seats[id];
        require(s.agent == msg.sender && s.version == version, "UnauthorizedAgent");
        s.acceptedConstitution = bytes32(0);
        emit AgentDeclined(id, version);
    }

    function revoke(uint256 id) external {
        Seat storage s = seats[id];
        require(s.depositor == msg.sender || _currentOwner(id) == msg.sender, "OnlySeatOwner");
        if (s.agent != address(0)) delete keySeatPlusOne[s.agent];
        s.agent = address(0);
        s.acceptedConstitution = bytes32(0);
        ++s.version;
        emit Revoked(id, s.version);
    }

    function validAgent(uint256 id, address actor, uint64 version, uint8 scope) public view returns (bool) {
        Seat storage s = seats[id];
        return s.acceptedConstitution != bytes32(0) && _authority(id, s, actor, version, scope);
    }

    function qualified(uint256 id) public view returns (bool) {
        Seat storage s = seats[id];
        return isDeposited(id) && s.exitAt == 0 && block.timestamp >= s.activationAt
            && s.acceptedConstitution == constitutionHash
            && validAgent(id, s.agent, s.version, FEEDBACK | GOVERNANCE);
    }

    function deposit(uint256 id) external nonReentrant {
        require(configurationHash != bytes32(0), "AdmissionNotConfigured");
        Seat storage s = seats[id];
        require(
            validAgent(id, s.agent, s.version, 0) && s.acceptedConstitution == constitutionHash,
            "AgentNotAccepted"
        );
        require(
            msg.sender == s.depositor
                || (validAgent(id, msg.sender, s.version, STAKE) && s.stakeLimit == stakeAmount),
            "DepositUnauthorized"
        );
        require(!isDeposited(id) && depositedSeats.length < MAX_SEATS, "SeatAlreadyStakedOrCapacity");
        s.activationAt = uint64(block.timestamp + ACTIVATION_DELAY);
        s.exitAt = 0;
        ++s.generation;
        depositedSeats.push(id);
        indexPlusOne[id] = depositedSeats.length;
        totalDeposited += stakeAmount;
        uint256 beforeBalance = token.balanceOf(address(this));
        TokenCall.callToken(
            address(token), abi.encodeCall(IERC20.transferFrom, (s.depositor, address(this), stakeAmount))
        );
        require(token.balanceOf(address(this)) == beforeBalance + stakeAmount, "InexactDeposit");
        emit Deposited(id, s.depositor, stakeAmount, s.activationAt, s.generation);
    }

    /// @dev A transferred NFT never transfers ownership of refundable tokens.
    function requestExit(uint256 id) external {
        Seat storage s = seats[id];
        require(isDeposited(id) && s.exitAt == 0, "ExitInvalid");
        require(
            msg.sender == s.depositor || _currentOwner(id) == msg.sender
                || validAgent(id, msg.sender, s.version, STAKE),
            "ExitUnauthorized"
        );
        s.exitAt = uint64(block.timestamp + EXIT_DELAY);
        emit ExitRequested(id, s.exitAt);
    }

    function withdraw(uint256 id) external nonReentrant {
        Seat storage s = seats[id];
        require(isDeposited(id) && s.exitAt != 0 && block.timestamp >= s.exitAt, "ExitPending");
        // Permissionless completion, but the recipient is permanently the original depositor.
        address recipient = s.depositor;
        uint256 index = indexPlusOne[id] - 1;
        uint256 last = depositedSeats[depositedSeats.length - 1];
        depositedSeats[index] = last;
        indexPlusOne[last] = index + 1;
        depositedSeats.pop();
        delete indexPlusOne[id];
        totalDeposited -= stakeAmount;
        s.activationAt = 0;
        s.exitAt = 0;
        if (s.agent != address(0)) delete keySeatPlusOne[s.agent];
        s.agent = address(0);
        s.acceptedConstitution = bytes32(0);
        ++s.version;
        TokenCall.callToken(address(token), abi.encodeCall(IERC20.transfer, (recipient, stakeAmount)));
        emit Withdrawn(id, recipient, stakeAmount);
    }

    function _authority(uint256 id, Seat storage s, address actor, uint64 version, uint8 scope)
        internal
        view
        returns (bool)
    {
        if (
            actor == address(0) || s.agent != actor || s.version != version || block.timestamp >= s.expires
                || (s.scopes & scope) != scope
        ) return false;
        if (_currentOwner(id) != s.depositor) return false;
        try nft.getApproved(id) returns (address approved) {
            return approved == address(this);
        } catch {
            return false;
        }
    }

    function _currentOwner(uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address current) {
            return current;
        } catch {
            return address(0);
        }
    }
}
