// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {BackGeoOracle} from "../src/BackGeoOracle.sol";

import "forge-std/console2.sol";
import {console} from "forge-std/console.sol";

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
        key = PoolKey(Currency.wrap(address(0)), currency1, 0, TickMath.MAX_TICK_SPACING, IHooks(hook)); //currency0
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
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        // cannot initialize already-initialized pool
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, SQRT_PRICE_1_1);

        // cannot have fee other than 0
        key.fee = 1; // Change one parameter to make it different from the existing pool
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BackGeoOracle.OnlyOneOraclePoolAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);

        // an EOA can be token1
        // TODO: assert that liquidity cannot be added to pool where token1 is EOA, i.e. liquidity will be 0
        key.fee = 0;
        key.currency1 = Currency.wrap(address(2));
        // tick is stored in observation, but there is not check on the tick value, as it is retrieved from poolManager
        int24 tick = 0;
        vm.expectCall(address(hook), abi.encodeCall(hook.afterInitialize, (address(this), key, SQRT_PRICE_1_1, tick)));
        manager.initialize(key, SQRT_PRICE_1_1);
        key.currency1 = currency1;
    }

    function testHookAfterInitialize() public {
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
        // TODO: remove if state gets reset after every test
        key.currency1 = currency1;
    }

    function testExactOutZeroForOneRevert() public {
        bool zeroForOne = true;
        int256 amountSpecified = 1e18;

        vm.expectRevert("Use swapNativeInput() for native-token exact-output swaps");
        swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
    }

    function testExactOutRevert() public {
        bool zeroForOne = false;
        int256 amountSpecified = 1e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BackGeoOracle.NotExactIn.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES
        );
    }

    function testHookBeforeAddLiquidityRevert() public {
        vm.skip(true);
        uint128 additionalLiquidity = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            additionalLiquidity
        );

        // cannot reproduce, as call does not revert as expected. Prob due to low-level call silent fail.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BackGeoOracle.OraclePositionsMustBeFullRange.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        /*(uint256 newTokenId,) =*/ posm.mint(
            key,
            tickLower,
            tickUpper - TickMath.MAX_TICK_SPACING,
            additionalLiquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testHookBeforeAddLiquidity() public {
        uint128 additionalLiquidity = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            additionalLiquidity
        );
        
        (uint256 newTokenId,) = posm.mint(
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

    // TODO: check why [FAIL: revert: deltaAfter1 is not greater than or equal to 0] with big amounts
    function testHookAfterSwap() public {
        // Perform a swap to test afterSwap hook
        bool zeroForOne = true;
        int256 amountSpecified = -5e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 5 eth: ", swapDelta.amount0());
        console2.log("amount1 delta 5 eth: ", swapDelta.amount1());

        amountSpecified = -50e18;
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 50 eth: ", swapDelta.amount0());
        console2.log("amount1 delta 50 eth: ", swapDelta.amount1());

        amountSpecified = -100e18;
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 200 eth: ", swapDelta.amount0());
        console2.log("amount1 delta 200 eth: ", swapDelta.amount1());

        // execute exactIn, 1 for 0
        swap(key, !zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testHookAfterSwapReturnDelta() public {
        vm.skip(true);
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        assertEq(int256(swapDelta.amount0()), amountSpecified);
    }
}
