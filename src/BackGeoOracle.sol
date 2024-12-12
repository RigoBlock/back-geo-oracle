// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Oracle} from "../libraries/Oracle.sol";

contract BackGeoOracle is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for int256;

    using StateLibrary for IPoolManager;

    /// @notice Oracle pools do not have fees because they exist to serve as an oracle for a pair of tokens
    error OnlyOneOraclePoolAllowed();

    /// @notice Oracle positions must be full range
    error OraclePositionsMustBeFullRange();

    /// @notice Only exactInput swap types are allowed
    error NotExactIn();

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
            beforeRemoveLiquidity: true,
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

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool.
        require(key.fee == 0 && key.tickSpacing == TickMath.MAX_TICK_SPACING, OnlyOneOraclePoolAllowed());
        return BackGeoOracle.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);
        return BackGeoOracle.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;
        require(
            params.tickLower == TickMath.minUsableTick(maxTickSpacing)
                && params.tickUpper == TickMath.maxUsableTick(maxTickSpacing),
            OraclePositionsMustBeFullRange()
        );
        _updatePool(key);
        return BackGeoOracle.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        _updatePool(key);
        return BackGeoOracle.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // only exactIn swaps are supported
        require(params.amountSpecified < 0, NotExactIn());
        _updatePool(key);
        return (BackGeoOracle.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // the unspecified currency is always the one user is buying, so we charge a fee to settle the backrun
        (BalanceDelta hookDelta, bool isBackrun) = _backrun(sender, key, params);

        if (isBackrun) {
            bool _isCurrency0Specified = (params.amountSpecified < 0 == params.zeroForOne);

            // in backrun we invert zeroForOne and sign of amountSpecified, currency specified is same
            (Currency currencySpecified, int128 backAmountSpecified, int128 backAmountUnspecified) = (
                _isCurrency0Specified
                    ? (key.currency0, hookDelta.amount0(), hookDelta.amount1())
                    : (key.currency1, hookDelta.amount1(), hookDelta.amount0())
            );

            // the following condition must always be true since we only support ExactInput swaps
            assert(backAmountUnspecified < 0 && backAmountSpecified > 0);

            // return to the user backrun amount in the specified currency
            poolManager.mint(sender, CurrencyLibrary.toId(currencySpecified), uint256(int256(backAmountSpecified)));
            return (BackGeoOracle.afterSwap.selector, -backAmountUnspecified);
        }

        return (BackGeoOracle.afterSwap.selector, BalanceDelta.unwrap(hookDelta).toInt128());
    }

    /// @notice Increase the cardinality target for the given pool
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));

        ObservationState storage state = states[id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }

    function _backrun(address, PoolKey calldata key, IPoolManager.SwapParams memory params)
        private
        returns (BalanceDelta hookDelta, bool shouldBackrun)
    {
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        // we only have 1 stored observation
        Oracle.Observation memory last = observations[PoolId.wrap(keccak256(abi.encode(key)))][0];
        int24 tickDelta = tick - last.prevTick;

        // we are only interested in the absolute tick delta
        if (tickDelta < 0) {
            tickDelta = -tickDelta;
        }

        // we apply a 1 bps tolerance for rounding errors that prevent full amount backrun
        if (tickDelta <= Oracle.MIN_ABS_TICK_MOVE) {
            // early escape to save gas for normal transactions
        } else if (tickDelta < Oracle.LIMIT_ABS_TICK_MOVE) {
            shouldBackrun = true;
            int128 numerator = int128(tickDelta) * 9999;
            int128 denominator = int128(Oracle.LIMIT_ABS_TICK_MOVE) * 10000;
            params.amountSpecified = params.amountSpecified * numerator / denominator;
        } else {
            // Full backrun
            shouldBackrun = true;
            params.amountSpecified = params.amountSpecified * 9999 / 10000;
        }

        // early escape if no backrun is necessary, to save gas on small impact swaps
        if (shouldBackrun) {
            params.zeroForOne = !params.zeroForOne;
            params.amountSpecified = -params.amountSpecified;
            params.sqrtPriceLimitX96 = params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

            // transfer deltas to user
            hookDelta = poolManager.swap(key, params, "");
        } else {
            hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        }
    }

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(PoolKey calldata key) private {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), tick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );
    }

    /// @notice Returns the observation for the given pool key and observation index
    function getObservation(PoolKey calldata key, uint256 index)
        external
        view
        returns (Oracle.Observation memory observation)
    {
        observation = observations[PoolId.wrap(keccak256(abi.encode(key)))][index];
    }

    /// @notice Returns the state for the given pool key
    function getState(PoolKey calldata key) external view returns (ObservationState memory state) {
        state = states[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    /// @notice Observe the given pool for the timestamps
    /// @dev Method to be used to extract TWAP.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId id = key.toId();

        ObservationState memory state = states[id];

        (, int24 tick,,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        return observations[id].observe(_blockTimestamp(), secondsAgos, tick, state.index, liquidity, state.cardinality);
    }

    /// @dev For mocking
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }
}
