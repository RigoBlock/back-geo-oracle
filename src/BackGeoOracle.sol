// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
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

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

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

    // TODO: check whether we want an oracle to exist where token0 is base currency only
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        onlyByManager
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook. In other words,
        // there may only be one pool per pair of tokens that use this hook. The tick spacing is set to the maximum
        // because we only allow max range liquidity in this pool.
        if (key.fee != 0 || key.tickSpacing != manager.MAX_TICK_SPACING()) revert OnlyOneOraclePoolAllowed();
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

    // TODO: is onlyByManager modifier necessary in these methods?
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyByManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // TODO: update should store min tick, max tick observed in a block. We cannot use the swap tick delta as a swap can be
        // divided into multiple ones. Should use min and max to verify what the tick delta is, and what the after swap fee will be.
        _updatePool(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.SwapParams params;
        uint256 backrunAmount;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyByManager returns (bytes4, int128) {
        // fee will be in the unspecified token of the swap
        bool isCurrency0Specified = (params.amountSpecified < 0 == params.zeroForOne);

        (Currency currencyUnspecified, int128 amountUnspecified) =
            (isCurrency0Specified) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

        // if exactOutput swap, get the absolute output amount
        if (amountUnspecified < 0) amountUnspecified = -amountUnspecified;

        // TODO: apply range-based fee
        uint256 rangeBasedFee;
        uint256 feeAmount = uint256(int256(amountUnspecified)).mulWadDown(rangeBasedFee);

        // mint ERC6909 as its cheaper than ERC20 transfer
        poolManager.mint(address(this), CurrencyLibrary.toId(currencyUnspecified), feeAmount);

        // backrun swap
        // TODO: correctly detect undetected amount token, as we want to make sure we are able to take the undetermined amount
        //  i.e. we are selling in the undetermined amount
        if (callBackData.params.zeroForOne) {
            //Flash swap token1 for token0. We do not have to worry about front running, as we are backrunning
            IPoolManager.SwapParams memory token1to0 = IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: feeAmount,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta = poolManager.swap(data.key, token1to0);
            // TODO: repay delta to sender
            return abi.encode(delta);
        } else {
            IPoolManager.SwapParams memory token0to1 = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: feeAmount,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta = poolManager.swap(data.key, token0to1);
        }
        // technically, as minting the token is a liability, if we return the full amount, we can return delta 0
        // and avoid minting the nft, so we do not need to transfer back. This means no tax is applied to the caller,
        // and we should check if this is enough to guarantee the token won't be moved. We should check smaller increments
        // as an attacker could potentially try to manipulate illiquid tokens quite frequently.

        // at this point, we could repay to the tokens to the user, or should decide how to best allocate extra funds

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }
}
