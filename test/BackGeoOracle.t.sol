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
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {Oracle} from "../libraries/Oracle.sol";
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
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("BackGeoOracle.sol:BackGeoOracle", constructorArgs, flags);
        hook = BackGeoOracle(flags);

        // Create the pool
        key = PoolKey(Currency.wrap(address(0)), currency1, 0, TickMath.MAX_TICK_SPACING, IHooks(hook)); //currency0
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_2_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_2_1,
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
        assertTrue(permissions.beforeRemoveLiquidity);
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
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_2_1);

        // cannot initialize already-initialized pool
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, SQRT_PRICE_2_1);

        PoolKey memory newKey = key;

        // cannot have fee other than 0
        newKey.fee = 1; // Change one parameter to make it different from the existing pool
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BackGeoOracle.OnlyOneOraclePoolAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(newKey, SQRT_PRICE_2_1);

        // an EOA can be token1
        newKey.fee = 0;
        newKey.currency1 = Currency.wrap(address(2));
        int24 tick = 0;
        vm.expectCall(address(hook), abi.encodeCall(hook.afterInitialize, (address(this), newKey, SQRT_PRICE_1_1, tick)));
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    function testHookAfterInitialize() public {
        PoolKey memory newKey = key;
        newKey.currency1 = Currency.wrap(address(0x123)); // Example new address for currency1
        //vm.expectEmit(true, true, true, true);
        //emit Initialize(
        //    newKey.toId(), 
        //    newKey.currency0, 
        //    newKey.currency1, 
        //    newKey.fee, 
        //    newKey.tickSpacing, 
        //    newKey.hooks, 
        //    SQRT_PRICE_1_1, 
        //    TickMath.getTickAtSqrtPrice(SQRT_PRICE_1_1)
        //);
        manager.initialize(newKey, SQRT_PRICE_1_1);

        // state assertions
        BackGeoOracle.ObservationState memory observationState = hook.getState(newKey);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 1);

        // observation assertions
        Oracle.Observation memory observation = hook.getObservation(newKey, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
    }

    function testAfterInitializeObserve0() public view {
        uint32[] memory secondsAgo = new uint32[](1);
        secondsAgo[0] = 0;
        (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) =
            hook.observe(key, secondsAgo);
        assertEq(tickCumulatives.length, 1);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 1);
        assertEq(tickCumulatives[0], 0);
        assertEq(secondsPerLiquidityCumulativeX128s[0], 0);
    }

    /// forge-config: default.allow_internal_expect_revert = true
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

    /// @dev This test is designed to allows external applications use the oracle safely without asserting that the target address has code.
    /// @dev The following test reverts as expected, but foundry does not recognize the error (possibly another call is executed before the failing one).
    /// forge-config: default.allow_internal_expect_revert = true
    function testBeforeAddLiquidityToken0isEoaRevert() public {
        vm.skip(true); // skip as transaction reverts, but foundry asserts revert on a previous call
        PoolKey memory newKey = key;
        newKey.currency1 = Currency.wrap(address(2));
        uint128 additionalLiquidity = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            additionalLiquidity
        );
        manager.initialize(newKey, SQRT_PRICE_2_1);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        posm.mint(
            newKey,
            tickLower,
            tickUpper,
            additionalLiquidity,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    /// @dev The following test reverts as expected, but foundry does not recognize the error (possibly another call is executed before the failing one).
    function testHookBeforeAddLiquidityRevert() public {
        vm.skip(true); // skip as transaction reverts, but foundry asserts revert on a previous call
        uint128 additionalLiquidity = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_2_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper - TickMath.MAX_TICK_SPACING),
            additionalLiquidity
        );
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
            SQRT_PRICE_2_1,
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

    function testBeforeModifyPositionObservationAndCardinality() public {
        vm.warp(vm.getBlockTimestamp() + 2);
        hook.increaseCardinalityNext(key, 2);
        BackGeoOracle.ObservationState memory observationState = hook.getState(key);
        assertEq(observationState.index, 0);
        assertEq(observationState.cardinality, 1);
        assertEq(observationState.cardinalityNext, 2);
        (, int24 tick,,) = manager.getSlot0(poolId);
        // when sqrtPriceLimitX96 = 2^96, tick is 0 (log1.0001(price))
        assertEq(uint256(int256(tick)), 6931);

        uint256 liquidityToRemove = 1e18;
        posm.decreaseLiquidity(
            tokenId,
            liquidityToRemove,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            address(this),
            vm.getBlockTimestamp(),
            ZERO_BYTES
        );

        // cardinality is updated
        observationState = hook.getState(key);
        assertEq(observationState.index, 1);
        assertEq(observationState.cardinality, 2);
        assertEq(observationState.cardinalityNext, 2);

        // index 0 is untouched
        Oracle.Observation memory observation = hook.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.blockTimestamp, 1);
        assertEq(observation.tickCumulative, 0);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 0);
        assertEq(observation.prevTick, 6931);

        // index 1 is written
        observation = hook.getObservation(key, 1);
        assertTrue(observation.initialized);
        // timestamp of observation is the one of the block it is recorded in
        assertEq(observation.blockTimestamp, 3);
        assertEq(observation.tickCumulative, 13862);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 6805647338418769269);
        assertEq(observation.prevTick, 6931);

        vm.warp(vm.getBlockTimestamp() + 1);
        hook.increaseCardinalityNext(key, 3);
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        observation = hook.getObservation(key, 2);
        assertTrue(observation.initialized);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 10242842963882794152);
        assertEq(observation.tickCumulative, 20793);
        assertEq(observation.prevTick, 6931);
        (, tick,,) = manager.getSlot0(poolId);
        assertEq(int256(tick), 6648);

        vm.warp(vm.getBlockTimestamp() + 1);
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // we do not increase cardinality, so observation will be overwritten to oldest
        observation = hook.getObservation(key, 0);
        assertTrue(observation.initialized);
        assertEq(observation.secondsPerLiquidityCumulativeX128, 13680038589346819035);
        assertEq(observation.tickCumulative, 27441);
        assertEq(int256(observation.prevTick), 6648);
        assertEq(observation.blockTimestamp, 5);
        (, tick,,) = manager.getSlot0(poolId);
        assertEq(int256(tick), 6368);
    }

    function testHookAfterSwap() public {
        // Perform a swap to test afterSwap hook
        bool zeroForOne = true;
        int256 amountSpecified = -5e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 5 eth: %d", swapDelta.amount0());
        console2.log("amount1 delta 5 eth: %d", swapDelta.amount1());

        amountSpecified = -50e18;
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 50 eth: %d", swapDelta.amount0());
        console2.log("amount1 delta 50 eth: %d", swapDelta.amount1());

        amountSpecified = -100e18;
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        console2.log("amount0 delta 200 eth: %d", swapDelta.amount0());
        console2.log("amount1 delta 200 eth: %d", swapDelta.amount1());

        // execute exactIn, 1 for 0
        swap(key, !zeroForOne, amountSpecified, ZERO_BYTES);
    }

    function testHookAfterSwapReturnDelta() public {
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        assertEq(int256(swapDelta.amount0()), amountSpecified);
    }
}
