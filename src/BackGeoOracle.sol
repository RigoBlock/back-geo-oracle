// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Oracle} from "./libraries/Oracle.sol";

contract BackGroOracle is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using PoolIdLibrary for PoolKey;

    using StateLibrary for IPoolManager;

    /// @notice Oracle pools do not have fees because they exist to serve as an oracle for a pair of tokens
    error OnlyOneOraclePoolAllowed();

    /// @notice Oracle positions must be full range
    error OraclePositionsMustBeFullRange();

    /// @notice Oracle pools must have liquidity locked so that they cannot become more susceptible to price manipulation
    error OraclePoolMustLockLiquidity();

    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The list of observations for a given pool ID
    mapping(PoolId => Oracle.Observation[65535]) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(PoolId => ObservationState) public states;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        onlyByManager
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool. The currency0 must be base currency to prevent
        // rogue oracles.
        if (key.fee != 0 || key.tickSpacing != TickMath.MAX_TICK_SPACING || key.currency0 !== address(0)) revert OnlyOneOraclePoolAllowed();
        return GeomeanOracle.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        onlyByManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp());
        return GeomeanOracle.afterInitialize.selector;
    }

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(PoolKey calldata key) private {
        PoolId id = key.toId();
        (, int24 tick,,) = manager.getSlot0(id);

        uint128 liquidity = manager.getLiquidity(id);

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), tick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        int24 maxTickSpacing = manager.MAX_TICK_SPACING();
        if (
            params.tickLower != TickMath.minUsableTick(maxTickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(maxTickSpacing)
        ) revert OraclePositionsMustBeFullRange();
        _updatePool(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyByManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _updatePool(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyByManager returns (bytes4, int128) {
        int128 feeAmount;

        if (sender !== address(this)) {
            feeAmount = abi.decode(poolManager.unlock(abi.encode(key, params, delta)), int128);
        }

        return (BaseHook.afterSwap.selector, feeAmount); //feeAmount.toInt128()
    }

    struct CallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        BalanceDelta delta;
    }

    /// @notice prepares the hook for swap on the pool manager
    /// @dev This call is only callable by this contract via poolManager.unlock
    function unlockCallback(bytes calldata rawData) external override onlyByManager returns (bytes memory result) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        (, int24 tick,,) = manager.getSlot0(id);
        bool shouldBackrun = true;

        // overwrite undefined amount with backrun amount
        if ((tick - last.prevTick) > 9116 || (tick - last.prevTick) < -9116) {
            // Full backrun
        } else if ((tick - last.prevTick) > 4558 || (tick - last.prevTick) < -4558) {
            data.params.amountSpecified = data.params.amountSpecified * 4 * 1.1;
        } else if ((tick - last.prevTick) > 410 || (tick - last.prevTick) < -410) {
            data.params.amountSpecified = data.params.amountSpecified * 4 * 0.9;
        } else {
            shouldBackrun = false;
        }

        BalanceDelta memory delta;

        // early escape if no backrun is necessary, to save gas on small impact swaps
        if (shouldBackrun) {
            data.params.zeroForOne = !data.params.zeroForOne;
            data.params.sqrtPriceLimitX96 = data.params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = poolManager.swap(data.key, data.params, "");
        }

        return abi.encode(delta);
    }
}
