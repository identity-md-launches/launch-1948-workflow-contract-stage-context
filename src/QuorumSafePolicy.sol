// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ISafe} from "./Interfaces.sol";

/// @notice Read-only checks of Safe 1.5 identity and the entire allowed authority configuration.
/// This policy has no powers, setters, external execution or custody.
contract QuorumSafePolicy {
    error BootstrapOwners();
    error EnableGovernanceModule();
    error FallbackForbidden();
    error GovernanceGuardChanged();
    error GovernanceModuleChanged();
    error GovernanceOwnerChanged();
    error SafeCodeChanged();
    error SafeStorageInvalid();
    error SafeVersion();
    error UnexpectedGuard();
    error UnexpectedModule();

    ISafe public immutable safe;
    address public immutable founder;
    bytes32 public immutable singletonCodeHash;
    bytes32 public immutable proxyCodeHash;
    address private constant SENTINEL = address(1);
    bytes32 public constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 public constant MODULE_GUARD_SLOT =
        0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    bytes32 public constant FALLBACK_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    constructor(address safe_, address founder_, bytes32 singletonHash_, bytes32 proxyHash_) {
        require(
            safe_ != address(0) && founder_ != address(0) && singletonHash_ != bytes32(0)
                && proxyHash_ != bytes32(0),
            "PolicyInvalid"
        );
        safe = ISafe(safe_);
        founder = founder_;
        singletonCodeHash = singletonHash_;
        proxyCodeHash = proxyHash_;
    }

    function _safeSlot(bytes32 slot) internal view returns (address) {
        bytes memory data = safe.getStorageAt(uint256(slot), 1);
        require(data.length == 32, SafeStorageInvalid());
        return address(uint160(uint256(abi.decode(data, (bytes32)))));
    }

    function _assertIdentity() internal view {
        require(
            address(safe).codehash == proxyCodeHash && _safeSlot(bytes32(0)).codehash == singletonCodeHash,
            SafeCodeChanged()
        );
        require(keccak256(bytes(safe.VERSION())) == keccak256("1.5.0"), SafeVersion());
        require(_safeSlot(FALLBACK_SLOT) == address(0), FallbackForbidden());
    }

    function assertBootstrap(address governor, bool needsModule) external view {
        _assertIdentity();
        address[] memory owners = safe.getOwners();
        require(owners.length == 1 && owners[0] == founder && safe.getThreshold() == 1, BootstrapOwners());
        (address[] memory modules, address next) = safe.getModulesPaginated(SENTINEL, 2);
        require(
            next == SENTINEL && (modules.length == 0 || (modules.length == 1 && modules[0] == governor)),
            UnexpectedModule()
        );
        require(!needsModule || modules.length == 1, EnableGovernanceModule());
        address guard = _safeSlot(GUARD_SLOT);
        address moduleGuard = _safeSlot(MODULE_GUARD_SLOT);
        require(
            (guard == address(0) || guard == governor)
                && (moduleGuard == address(0) || moduleGuard == governor),
            UnexpectedGuard()
        );
    }

    function assertBound(address governor) external view {
        _assertIdentity();
        address[] memory owners = safe.getOwners();
        require(
            owners.length == 1 && owners[0] == governor && safe.getThreshold() == 1, GovernanceOwnerChanged()
        );
        (address[] memory modules, address next) = safe.getModulesPaginated(SENTINEL, 2);
        require(modules.length == 1 && modules[0] == governor && next == SENTINEL, GovernanceModuleChanged());
        require(
            _safeSlot(GUARD_SLOT) == governor && _safeSlot(MODULE_GUARD_SLOT) == governor,
            GovernanceGuardChanged()
        );
    }
}
