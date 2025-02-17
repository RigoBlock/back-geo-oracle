// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Shared constants used in scripts
contract Constants {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev populated with default anvil addresses
    PositionManager constant posm = PositionManager(payable(address(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0)));
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

    address private immutable poolManager;
    IPoolManager immutable POOLMANAGER = IPoolManager(address(poolManager));

    constructor() {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        } else if (chainId == 10) {
            poolManager = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        } else if (chainId == 8453) {
            poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        } else if (chainId == 42161) {
            poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        } else if (chainId == 137) {
            poolManager = 0x67366782805870060151383F4BbFF9daB53e5cD6;
        } else if (chainId == 81457) {
            poolManager = 0x1631559198A9e474033433b2958daBC135ab6446;
        } else if (chainId == 7777777) {
            poolManager = 0x0575338e4C17006aE181B47900A84404247CA30f;
        } else if (chainId == 480) {
            poolManager = 0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33;
        } else if (chainId == 57073) {
            poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        } else if (chainId == 1868) {
            poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        } else if (chainId == 43114) {
            poolManager = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;
        } else if (chainId == 56) {
            poolManager = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
        } else if (chainId == 1301) {
            poolManager = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        } else if (chainId == 11155111) {
            poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        } else {
            poolManager = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
        }
    }
}
