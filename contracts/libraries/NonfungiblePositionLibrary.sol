// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0;
pragma abicoder v2;

import '@uniswap/v3-core-optimism/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core-optimism/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-core-optimism/contracts/libraries/FullMath.sol';
import '@uniswap/v3-core-optimism/contracts/libraries/TickMath.sol';
import '@uniswap/lib/contracts/libraries/SafeERC20Namer.sol';

import '../interfaces/IERC20Metadata.sol';
import '../interfaces/INonfungiblePositionManager.sol';
import './LiquidityAmounts.sol';
import './PoolAddress.sol';
import './PositionKey.sol';

import './ChainId.sol';
import './NFTDescriptor.sol';
import './TokenRatioSortOrder.sol';

/// @title Function for getting the current chain ID
library NonfungiblePositionLibrary {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH9 = 0x4200000000000000000000000000000000000006;

    /// @notice Emitted when liquidity is increased for a position NFT
    /// @dev Also emitted when a token is minted
    /// @param tokenId The ID of the token for which liquidity was increased
    /// @param liquidity The amount by which liquidity for the NFT position was increased
    /// @param amount0 The amount of token0 that was paid for the increase in liquidity
    /// @param amount1 The amount of token1 that was paid for the increase in liquidity
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when liquidity is decreased for a position NFT
    /// @param tokenId The ID of the token for which liquidity was decreased
    /// @param liquidity The amount by which liquidity for the NFT position was decreased
    /// @param amount0 The amount of token0 that was accounted for the decrease in liquidity
    /// @param amount1 The amount of token1 that was accounted for the decrease in liquidity
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when tokens are collected for a position NFT
    /// @dev The amounts reported may not be exactly equivalent to the amounts transferred, due to rounding behavior
    /// @param tokenId The ID of the token for which underlying tokens were collected
    /// @param recipient The address of the account that received the collected tokens
    /// @param amount0 The amount of token0 owed to the position that was collected
    /// @param amount1 The amount of token1 owed to the position that was collected
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    /**
     * @dev We emit the IncreaseLiquidity event in this method because otherwise bytecode that results from compiling
     * this for the OVM (with the optimizer on) results in unsafe opcodes. Details:
     *   - The final 32 bytes of the bytecode are 3067048beee31b25b2f1681f88dac838c8bba36af25bfb2b7cf7473a5847e35f,
     *     where 5b is the unsafe opcode
     *   - That 32 byte value is the event ID of the IncreaseLiquidity event
     *   - The IncreaseLiquidity event is emitted twice in this contract
     *   - The optimizer does not want to PUSH this multiple times, so when it sees it emitted twice, it optimizes the
     *     value into a constant, which is appended to the code
     *   - Solution: Only emit the event once in a helper function, which results in those 32 bytes being added
     *     with PUSH32, meaning you cannot JUMP to them. Whereas without this helper function they are added to
     *     the end with CODECOPY, which you can JUMP to, so the Safety Checker believes it's unsafe
     */
    function _emitIncreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal {
        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Produces the URI describing a particular token ID for a position manager
    /// @dev Note this URI may be a data: URI with the JSON contents directly inlined
    /// @param tokenId The ID of the token for which to produce a description, which may not be valid
    /// @return The URI of the ERC721-compliant metadata
    function tokenURI(
        IUniswapV3Pool pool,
        PoolAddress.PoolKey memory poolKey,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (string memory) {
        bool _flipRatio = flipRatio(poolKey.token0, poolKey.token1, ChainId.get());
        address quoteTokenAddress = !_flipRatio ? poolKey.token1 : poolKey.token0;
        address baseTokenAddress = !_flipRatio ? poolKey.token0 : poolKey.token1;
        (, int24 tick, , , , , ) = pool.slot0();

        return
            NFTDescriptor.constructTokenURI(
                NFTDescriptor.ConstructTokenURIParams({
                    tokenId: tokenId,
                    quoteTokenAddress: quoteTokenAddress,
                    baseTokenAddress: baseTokenAddress,
                    quoteTokenSymbol: quoteTokenAddress == WETH9
                        ? 'ETH'
                        : SafeERC20Namer.tokenSymbol(quoteTokenAddress),
                    baseTokenSymbol: baseTokenAddress == WETH9 ? 'ETH' : SafeERC20Namer.tokenSymbol(baseTokenAddress),
                    quoteTokenDecimals: IERC20Metadata(quoteTokenAddress).decimals(),
                    baseTokenDecimals: IERC20Metadata(baseTokenAddress).decimals(),
                    flipRatio: _flipRatio,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    tickCurrent: tick,
                    tickSpacing: pool.tickSpacing(),
                    fee: poolKey.fee,
                    poolAddress: address(pool)
                })
            );
    }

    function flipRatio(
        address token0,
        address token1,
        uint256 chainId
    ) public view returns (bool) {
        return tokenRatioPriority(token0, chainId) > tokenRatioPriority(token1, chainId);
    }

    function tokenRatioPriority(address token, uint256 chainId) public view returns (int256) {
        if (token == WETH9) {
            return TokenRatioSortOrder.DENOMINATOR;
        }
        if (chainId == 1) {
            if (token == USDC) {
                return TokenRatioSortOrder.NUMERATOR_MOST;
            } else if (token == USDT) {
                return TokenRatioSortOrder.NUMERATOR_MORE;
            } else if (token == DAI) {
                return TokenRatioSortOrder.NUMERATOR;
            } else if (token == TBTC) {
                return TokenRatioSortOrder.DENOMINATOR_MORE;
            } else if (token == WBTC) {
                return TokenRatioSortOrder.DENOMINATOR_MOST;
            } else {
                return 0;
            }
        }
        return 0;
    }

    struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    function collect(
        IUniswapV3Pool pool,
        INonfungiblePositionManager.Position storage position,
        INonfungiblePositionManager.CollectParams calldata params
    ) public returns (uint256 amount0, uint256 amount1) {
        require(params.amount0Max > 0 || params.amount1Max > 0);

        // allow collecting to the nft position manager address with address 0
        address recipient = params.recipient == address(0) ? address(this) : params.recipient;

        (uint128 tokensOwed0, uint128 tokensOwed1) = (position.tokensOwed0, position.tokensOwed1);

        // trigger an update of the position fees owed and fee growth snapshots if it has any liquidity
        if (position.liquidity > 0) {
            pool.burn(position.tickLower, position.tickUpper, 0);
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) =
                pool.positions(PositionKey.compute(address(this), position.tickLower, position.tickUpper));

            tokensOwed0 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );
            tokensOwed1 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );

            position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
            position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        }

        // compute the arguments to give to the pool#collect method
        (uint128 amount0Collect, uint128 amount1Collect) =
            (
                params.amount0Max > tokensOwed0 ? tokensOwed0 : params.amount0Max,
                params.amount1Max > tokensOwed1 ? tokensOwed1 : params.amount1Max
            );

        // the actual amounts collected are returned
        (amount0, amount1) = pool.collect(
            recipient,
            position.tickLower,
            position.tickUpper,
            amount0Collect,
            amount1Collect
        );

        // sometimes there will be a few less wei than expected due to rounding down in core, but we just subtract the full amount expected
        // instead of the actual amount so we can burn the token
        (position.tokensOwed0, position.tokensOwed1) = (tokensOwed0 - amount0Collect, tokensOwed1 - amount1Collect);

        emit Collect(params.tokenId, recipient, amount0Collect, amount1Collect);
    }

    function decreaseLiquidity(
        IUniswapV3Pool pool,
        INonfungiblePositionManager.Position storage position,
        INonfungiblePositionManager.DecreaseLiquidityParams calldata params
    ) public returns (uint256 amount0, uint256 amount1) {
        require(params.liquidity > 0);
        uint128 positionLiquidity = position.liquidity;
        require(positionLiquidity >= params.liquidity);

        (amount0, amount1) = pool.burn(position.tickLower, position.tickUpper, params.liquidity);

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);
        // this is now updated to the current transaction
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 +=
            uint128(amount0) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    positionLiquidity,
                    FixedPoint128.Q128
                )
            );
        position.tokensOwed1 +=
            uint128(amount1) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    positionLiquidity,
                    FixedPoint128.Q128
                )
            );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        // subtraction is safe because we checked positionLiquidity is gte params.liquidity
        position.liquidity = positionLiquidity - params.liquidity;

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    /// @notice Add liquidity to an initialized pool
    function addLiquidity(
        IUniswapV3Pool pool,
        PoolAddress.PoolKey memory poolKey,
        INonfungiblePositionManager.AddLiquidityParams memory params
    )
        public
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // compute the liquidity amount
        {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');
    }

    function increaseLiquidity(
        IUniswapV3Pool pool,
        PoolAddress.PoolKey memory poolKey,
        INonfungiblePositionManager.Position storage position,
        INonfungiblePositionManager.IncreaseLiquidityParams calldata params
    )
        public
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (liquidity, amount0, amount1) = addLiquidity(
            pool,
            poolKey,
            INonfungiblePositionManager.AddLiquidityParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this)
            })
        );

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);

        // this is now updated to the current transaction
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(
            FullMath.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        position.tokensOwed1 += uint128(
            FullMath.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity += liquidity;

        _emitIncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    function updatePosition(
        IUniswapV3Pool pool,
        INonfungiblePositionManager.MintParams calldata params,
        INonfungiblePositionManager.Position storage position,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint80 poolId
    ) public {
        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.nonce = 0;
        position.operator = address(0);
        position.poolId = poolId;
        position.tickLower = params.tickLower;
        position.tickUpper = params.tickUpper;
        position.liquidity = liquidity;
        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        _emitIncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }
}
