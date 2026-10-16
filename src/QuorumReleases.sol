// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuorumGovernance} from "./QuorumGovernance.sol";

/// @notice Exact approved artifacts; publication reports are explicitly untrusted observations.
contract QuorumReleases {
    address public immutable owner;
    QuorumGovernance public immutable governance;

    struct Release {
        bytes32 sourceHash;
        bytes32 buildHash;
        bytes32 siteHash;
        bytes32 connectorHash;
        bytes32 migrationHash;
        uint64 approvedAt;
        uint256 proposal;
        string manifestURI;
    }
    mapping(bytes32 => Release) private releases;
    bytes32 public currentRelease;
    event ReleaseApproved(
        bytes32 indexed releaseId,
        uint256 indexed proposal,
        bytes32 siteHash,
        bytes32 connectorHash,
        string manifestURI
    );
    event PublicationObserved(
        bytes32 indexed releaseId, address indexed observer, bytes32 publishedHash, string contentURI
    );

    constructor(address governance_, address owner_) {
        require(governance_ != address(0) && owner_ != address(0), "ConfigurationInvalid");
        governance = QuorumGovernance(governance_);
        owner = owner_;
    }

    function approveRelease(
        bytes32 sourceHash,
        bytes32 buildHash,
        bytes32 siteHash,
        bytes32 connectorHash,
        bytes32 migrationHash,
        string calldata manifestURI
    ) external returns (bytes32 id) {
        require(
            msg.sender == owner && address(governance.safe()) == owner && governance.majorExecuting(),
            "OnlyMajorExecution"
        );
        require(
            sourceHash != bytes32(0) && buildHash != bytes32(0) && siteHash != bytes32(0)
                && connectorHash != bytes32(0),
            "ArtifactHashMissing"
        );
        require(bytes(manifestURI).length > 0 && bytes(manifestURI).length <= 512, "ManifestURIInvalid");
        id = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                sourceHash,
                buildHash,
                siteHash,
                connectorHash,
                migrationHash,
                keccak256(bytes(manifestURI))
            )
        );
        require(releases[id].approvedAt == 0, "ReleaseAlreadyApproved");
        releases[id] = Release(
            sourceHash,
            buildHash,
            siteHash,
            connectorHash,
            migrationHash,
            uint64(block.timestamp),
            governance.executingProposal(),
            manifestURI
        );
        currentRelease = id;
        emit ReleaseApproved(id, governance.executingProposal(), siteHash, connectorHash, manifestURI);
    }

    function getRelease(bytes32 id) external view returns (Release memory) {
        return releases[id];
    }

    /// @notice An RPC/IPFS observer's claim is not proof of hosting, approval, availability or permanence.
    function observePublication(bytes32 id, bytes32 publishedHash, string calldata uri) external {
        require(releases[id].approvedAt != 0 && publishedHash != bytes32(0), "PublicationInvalid");
        require(bytes(uri).length != 0 && bytes(uri).length <= 512, "URIInvalid");
        emit PublicationObserved(id, msg.sender, publishedHash, uri);
    }
}
