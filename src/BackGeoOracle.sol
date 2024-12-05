// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Oracle} from "../libraries/Oracle.sol";

contract BackGeoOracle is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        // TODO: verify if ok overriding virtual with view
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool. The currency0 must be base currency to prevent
        // rogue oracles.
        require(
            key.fee == 0 && key.tickSpacing == TickMath.MAX_TICK_SPACING && key.currency0.isAddressZero(),
            OnlyOneOraclePoolAllowed()
        );
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

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _updatePool(key);
        return (BackGeoOracle.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // same as before. Could allow call from manager or this address, provided all calls to
    //  this address either come from manager of from this address, i.e. are restricted
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        int128 feeAmount;

        if (sender != address(this)) {
            feeAmount = abi.decode(poolManager.unlock(abi.encode(key, params, delta)), (int128));
        }

        return (BackGeoOracle.afterSwap.selector, feeAmount); //feeAmount.toInt128()
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

    struct CallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        BalanceDelta delta;
    }

    /// @notice prepares the hook for swap on the pool manager
    /// @dev This call is only callable by this contract via poolManager.unlock
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory result) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.key.toId();
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        bool shouldBackrun = true;

        // we only have 1 stored observation
        Oracle.Observation memory last = observations[PoolId.wrap(keccak256(abi.encode(data.key)))][0];
        int128 tickDelta = int128(tick - last.prevTick);

        // we are only interested in the absolute tick delta
        if (tickDelta < 0) {
            tickDelta = -tickDelta;
        }

        if (tickDelta <= Oracle.MIN_ABS_TICK_MOVE) {
            // early escape to save gas for normal transactions
            shouldBackrun = false;
        } else if (tickDelta <= Oracle.TARGET_ABS_TICK_MOVE) {
            int128 numerator = (tickDelta - Oracle.MIN_ABS_TICK_MOVE) * 10000;
            int128 denominator = (Oracle.TARGET_ABS_TICK_MOVE - Oracle.MIN_ABS_TICK_MOVE) * 10000;
            data.params.amountSpecified = data.params.amountSpecified * numerator / denominator;
        } else if (tickDelta < Oracle.LIMIT_ABS_TICK_MOVE) {
            int128 numerator = (tickDelta - Oracle.TARGET_ABS_TICK_MOVE) * 10000 + 5000;
            int128 denominator = (Oracle.LIMIT_ABS_TICK_MOVE - Oracle.TARGET_ABS_TICK_MOVE) * 10000 * 2;
            data.params.amountSpecified = data.params.amountSpecified * numerator / denominator;
        } else {
            // Full backrun
        }

        BalanceDelta delta;

        // early escape if no backrun is necessary, to save gas on small impact swaps
        if (shouldBackrun) {
            data.params.zeroForOne = !data.params.zeroForOne;
            data.params.sqrtPriceLimitX96 = data.params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = poolManager.swap(data.key, data.params, "");
        }

        return abi.encode(delta);
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
