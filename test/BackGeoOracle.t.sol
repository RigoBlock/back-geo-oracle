// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BackGeoOracle} from "../src/BackGeoOracle.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract BackGeoOracleTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BackGeoOracle hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG| Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("BackGeoOracle.sol:BackGeoOracle", constructorArgs, flags);
        hook = BackGeoOracle(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 0, TickMath.MAX_TICK_SPACING, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testConstructor() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    function testGetHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function testHookBeforeInitialize() public {
        // TODO: verify why this error is not found, which is imported from SafeCallback
        //vm.expectRevert(BackGeoOracle.NotPoolManager.selector);
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        // cannot initialize already-initialized pool
        vm.expectRevert(BackGeoOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(key, SQRT_PRICE_1_1);

        // cannot have fee other than 0
        key.fee = 1; // Change one parameter to make it different from the existing pool
        vm.expectRevert(BackGeoOracle.OnlyOneOraclePoolAllowed.selector);
        manager.initialize(key, SQRT_PRICE_1_1);

        key.fee = 0;
        // TODO: use actual token for currency1
        key.currency1 = Currency.wrap(address(2));
        // TODO: we can check here if pool reverts if not token, so can avoid asserting target is contract/token in rb
        // or expect revert if address is not a token
        //vm.expectCall(address(hook), abi.encodeCall(hook.afterInitialize, (address(this), key, SQRT_PRICE_1_1, tick))); extract tick
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function testHookAfterInitialize() public {
        // Since `afterInitialize` should be called after pool initialization, 
        // we check if the hook was called by looking at state changes or events.
        key.currency1 = Currency.wrap(address(0x123)); // Example new address for currency1
        //vm.expectEmit(true, true, true, true);
        //emit Initialize(
        //    key.toId(), 
        //    key.currency0, 
        //    key.currency1, 
        //    key.fee, 
        //    key.tickSpacing, 
        //    key.hooks, 
        //    SQRT_PRICE_1_1, 
        //    TickMath.getTickAtSqrtPrice(SQRT_PRICE_1_1)
        //);
        manager.initialize(key, SQRT_PRICE_1_1);

        assertTrue(hook.getState(key).cardinalityNext == 1);
    }

    function testHookBeforeSwap() public {
        // Setup for swap
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // Example amount for swap

        swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
    }

    function testHookAfterSwap() public {
        // Perform a swap to test afterSwap hook
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        /*BalanceDelta swapDelta =*/ swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testHookBeforeAddLiquidity() public {
        // Add more liquidity to test beforeAddLiquidity hook
        uint128 additionalLiquidity = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            additionalLiquidity
        );
        
        vm.expectRevert(BackGeoOracle.OraclePositionsMustBeFullRange.selector);
        (uint256 newTokenId,) = posm.mint(
            key,
            0,
            tickUpper,
            additionalLiquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        
        //vm.expectCall(address(hook), abi.encodeCall(hook.afterInitialize, (address(this), key, SQRT_PRICE_1_1, tick))); extract tick
        (newTokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            additionalLiquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        assertTrue(newTokenId != 0);

        uint256 liquidityToRemove = 1e18;
        posm.decreaseLiquidity(
            tokenId,
            liquidityToRemove,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testHookAfterSwapReturnDelta() public {
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        assertEq(int256(swapDelta.amount0()), amountSpecified);
    }
}
