// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

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

interface IMsgSender {
    function msgSender() external view returns (address);
}

/// @notice A Uniswap V4 hook implementing an oracle with backrun functionality for price impact mitigation.
/// @dev This hook includes backrun logic that relies on swap routers implementing the IMsgSender interface when a backrun is triggered (see `_afterSwap`).
/// @dev Swap routers interacting with this hook must implement the `msgSender()` method to return the address that will receive ERC6909 tokens in a backrun, which is critical for proper crediting of tokens.
/// @dev Failure to implement `msgSender()` will cause transactions that trigger a backrun to revert, preventing the potential locking of ERC6909 tokens in the swap router.
/// @dev The address returned by `msgSender()` should be capable of burning ERC6909 tokens to avoid locking the ERC6909 balance.
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

    /// @notice Original sender must be returned by the router in order to correctly credit ERC6909 in the event of a backrun
    error CallingRouterDoesNotReturnSender();

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

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool.
        if (key.fee != 0 || key.tickSpacing != TickMath.MAX_TICK_SPACING) {
            revert OnlyOneOraclePoolAllowed();
        }

        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4) {
        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;

        if (params.tickLower != TickMath.minUsableTick(maxTickSpacing)
            || params.tickUpper != TickMath.maxUsableTick(maxTickSpacing)
        ) {
            revert OraclePositionsMustBeFullRange();
        }

        _updatePool(key);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4) {
        _updatePool(key);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        // only exactIn swaps are supported
        if (params.amountSpecified >= 0) {
            revert NotExactIn();
        }

        _updatePool(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        // the unspecified currency is always the one user is buying, so we charge a fee to settle the backrun
        (BalanceDelta hookDelta, bool isBackrun) = _backrun(key, params, swapDelta);

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

            address backrunAmountRecipient;

            // retrieve original sender. The calling router is expected to implement msgSender() method
            try IMsgSender(sender).msgSender() returns (address originalSender) {
                backrunAmountRecipient = originalSender;
            } catch {
                revert CallingRouterDoesNotReturnSender();
            }

            // return to the user backrun amount in the specified currency
            poolManager.mint(backrunAmountRecipient, CurrencyLibrary.toId(currencySpecified), uint256(int256(backAmountSpecified)));
            return (BaseHook.afterSwap.selector, -backAmountUnspecified);
        }

        return (BaseHook.afterSwap.selector, BalanceDelta.unwrap(hookDelta).toInt128());
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

    function _backrun(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        BalanceDelta swapDelta
    ) private returns (BalanceDelta hookDelta, bool shouldBackrun) {
        PoolId poolId = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Oracle.Observation memory last = observations[id][states[id].index];
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
            params.amountSpecified = swapDelta.amount0() * numerator / denominator;
        } else {
            // Full backrun
            shouldBackrun = true;
            params.amountSpecified = swapDelta.amount0() * 9999 / 10000;
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
