// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISeatNFT {
    function ownerOf(uint256) external view returns (address);
    function getApproved(uint256) external view returns (address);
    function supportsInterface(bytes4) external view returns (bool);
}

interface ISafe {
    function VERSION() external view returns (string memory);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address, uint256) external view returns (address[] memory, address);
    function getStorageAt(uint256, uint256) external view returns (bytes memory);
    function execTransactionFromModuleReturnData(address, uint256, bytes calldata, uint8)
        external
        returns (bool, bytes memory);
}

abstract contract ReentrancyLock {
    uint256 private entered;
    modifier nonReentrant() {
        require(entered == 0, "Reentrancy");
        entered = 1;
        _;
        entered = 0;
    }
}

library TokenCall {
    function callToken(address token, bytes memory data) internal {
        require(token.code.length != 0, "TokenNotContract");
        (bool ok, bytes memory result) = token.call(data);
        require(
            ok && (result.length == 0 || (result.length == 32 && abi.decode(result, (bool)))),
            "TokenCallFailed"
        );
    }
}

library Signatures {
    function recover(bytes32 digest, bytes calldata signature) internal pure returns (address signer) {
        require(signature.length == 65, "SignatureLength");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        require(
            uint256(s) <= 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
                && (v == 27 || v == 28),
            "SignatureMalleable"
        );
        signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "SignatureInvalid");
    }
}
