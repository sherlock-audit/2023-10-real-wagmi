// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;
import "../vendor0.8/uniswap/LiquidityAmounts.sol";
import "../vendor0.8/uniswap/TickMath.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IQuoterV2.sol";
import "./ApproveSwapAndPay.sol";
import "../Vault.sol";
import { Constants } from "../libraries/Constants.sol";

// import "hardhat/console.sol";

abstract contract LiquidityManager is ApproveSwapAndPay {
    struct LoanInfo {
        uint128 liquidity;
        uint256 tokenId;
    }

    struct RestoreLiquidityParams {
        bool zeroForSaleToken;
        uint24 fee;
        uint256 slippageBP1000;
        uint256 totalfeesOwed;
        uint256 totalBorrowedAmount;
    }

    struct RestoreLiquidityCache {
        int24 tickLower;
        int24 tickUpper;
        uint24 fee;
        address saleToken;
        address holdToken;
        uint160 sqrtPriceX96;
        uint256 holdTokenDebt;
    }

    address public immutable VAULT_ADDRESS;
    INonfungiblePositionManager public immutable underlyingPositionManager;
    IQuoterV2 public immutable underlyingQuoterV2;

    constructor(
        address _underlyingPositionManagerAddress,
        address _underlyingQuoterV2,
        address _underlyingV3Factory,
        bytes32 _underlyingV3PoolInitCodeHash
    ) ApproveSwapAndPay(_underlyingV3Factory, _underlyingV3PoolInitCodeHash) {
        underlyingPositionManager = INonfungiblePositionManager(_underlyingPositionManagerAddress);
        underlyingQuoterV2 = IQuoterV2(_underlyingQuoterV2);
        bytes32 salt = keccak256(abi.encode(block.timestamp, address(this)));
        VAULT_ADDRESS = address(new Vault{ salt: salt }());
    }

    error InvalidBorrowedLiquidity(uint256 tokenId);
    error TooLittleBorrowedLiquidity(uint128 liquidity);
    error InvalidTokens(uint256 tokenId);
    error NotApproved(uint256 tokenId);
    error InvalidRestoredLiquidity(
        uint256 tokenId,
        uint128 borrowedLiquidity,
        uint128 restoredLiquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 holdTokentBalance,
        uint256 saleTokenBalance
    );

    /**
     * @dev Calculates the borrowed amount from a pool's single side position, rounding up if necessary.
     * @param zeroForSaleToken A boolean value indicating whether the token for sale is the 0th token or not.
     * @param tickLower The lower tick value of the position range.
     * @param tickUpper The upper tick value of the position range.
     * @param liquidity The liquidity of the position.
     * @return borrowedAmount The calculated borrowed amount.
     */
    function _getSingleSideRoundUpBorrowedAmount(
        bool zeroForSaleToken,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) private pure returns (uint256 borrowedAmount) {
        borrowedAmount = (
            zeroForSaleToken
                ? LiquidityAmounts.getAmount1ForLiquidity(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidity
                )
                : LiquidityAmounts.getAmount0ForLiquidity(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidity
                )
        );
        if (borrowedAmount > Constants.MINIMUM_BORROWED_AMOUNT) {
            ++borrowedAmount;
        } else {
            revert TooLittleBorrowedLiquidity(liquidity);
        }
    }

    /**
     * @dev Extracts liquidity from loans and returns the borrowed amount.
     * @param zeroForSaleToken A boolean value indicating whether the token for sale is the 0th token or not.
     * @param token0 The address of one of the tokens in the pair.
     * @param token1 The address of the other token in the pair.
     * @param loans An array of LoanInfo struct instances containing loan information.
     * @return borrowedAmount The total amount borrowed.
     */
    function _extractLiquidity(
        bool zeroForSaleToken,
        address token0,
        address token1,
        LoanInfo[] memory loans
    ) internal returns (uint256 borrowedAmount) {
        if (!zeroForSaleToken) {
            (token0, token1) = (token1, token0);
        }

        for (uint256 i; i < loans.length; ) {
            uint256 tokenId = loans[i].tokenId;
            uint128 liquidity = loans[i].liquidity;
            // Extract position-related details
            {
                int24 tickLower;
                int24 tickUpper;
                uint128 posLiquidity;
                {
                    address operator;
                    address posToken0;
                    address posToken1;

                    (
                        ,
                        operator,
                        posToken0,
                        posToken1,
                        ,
                        tickLower,
                        tickUpper,
                        posLiquidity,
                        ,
                        ,
                        ,

                    ) = underlyingPositionManager.positions(tokenId);
                    // Check operator approval
                    if (operator != address(this)) {
                        revert NotApproved(tokenId);
                    }
                    // Check token validity
                    if (posToken0 != token0 || posToken1 != token1) {
                        revert InvalidTokens(tokenId);
                    }
                }
                // Check borrowed liquidity validity
                if (!(liquidity > 0 && liquidity <= posLiquidity)) {
                    revert InvalidBorrowedLiquidity(tokenId);
                }
                // Calculate borrowed amount
                borrowedAmount += _getSingleSideRoundUpBorrowedAmount(
                    zeroForSaleToken,
                    tickLower,
                    tickUpper,
                    liquidity
                );
            }
            // Decrease liquidity and move to the next loan
            _decreaseLiquidity(tokenId, liquidity);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Restores liquidity from loans.
     * @param params The RestoreLiquidityParams struct containing restoration parameters.
     * @param externalSwap The SwapParams struct containing external swap details.
     * @param loans An array of LoanInfo struct instances containing loan information.
     */
    function _restoreLiquidity(
        RestoreLiquidityParams memory params,
        SwapParams calldata externalSwap,
        LoanInfo[] memory loans
    ) internal {
        RestoreLiquidityCache memory cache;
        for (uint256 i; i < loans.length; ) {
            // Update the cache for the current loan
            LoanInfo memory loan = loans[i];
            _upRestoreLiquidityCache(params.zeroForSaleToken, loan, cache);

            (uint256 holdTokenAmountIn, uint256 amount0, uint256 amount1) = _getHoldTokenAmountIn(
                params.zeroForSaleToken,
                cache.tickLower,
                cache.tickUpper,
                cache.sqrtPriceX96,
                loan.liquidity,
                cache.holdTokenDebt
            );

            if (holdTokenAmountIn > 0) {
                // Quote exact input single for swap
                uint256 saleTokenAmountOut;
                (saleTokenAmountOut, cache.sqrtPriceX96, , ) = underlyingQuoterV2
                    .quoteExactInputSingle(
                        IQuoterV2.QuoteExactInputSingleParams({
                            tokenIn: cache.holdToken,
                            tokenOut: cache.saleToken,
                            amountIn: holdTokenAmountIn,
                            fee: params.fee,
                            sqrtPriceLimitX96: 0
                        })
                    );

                // Perform external swap if external swap target is provided
                if (externalSwap.swapTarget != address(0)) {
                    _patchAmountsAndCallSwap(
                        cache.holdToken,
                        cache.saleToken,
                        externalSwap,
                        holdTokenAmountIn,
                        (saleTokenAmountOut * params.slippageBP1000) / Constants.BPS
                    );
                } else {
                    // Calculate hold token amount in again for new sqrtPriceX96
                    (holdTokenAmountIn, , ) = _getHoldTokenAmountIn(
                        params.zeroForSaleToken,
                        cache.tickLower,
                        cache.tickUpper,
                        cache.sqrtPriceX96,
                        loan.liquidity,
                        cache.holdTokenDebt
                    );

                    // Perform v3 swap exact input and update sqrtPriceX96
                    _v3SwapExactInput(
                        v3SwapExactInputParams({
                            fee: params.fee,
                            tokenIn: cache.holdToken,
                            tokenOut: cache.saleToken,
                            amountIn: holdTokenAmountIn,
                            amountOutMinimum: (saleTokenAmountOut * params.slippageBP1000) /
                                Constants.BPS
                        })
                    );
                    cache.sqrtPriceX96 = _getCurrentSqrtPriceX96(
                        params.zeroForSaleToken,
                        cache.saleToken,
                        cache.holdToken,
                        cache.fee
                    );
                    (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                        cache.sqrtPriceX96,
                        TickMath.getSqrtRatioAtTick(cache.tickLower),
                        TickMath.getSqrtRatioAtTick(cache.tickUpper),
                        loan.liquidity
                    );
                }
            }

            address creditor = underlyingPositionManager.ownerOf(loan.tokenId);
            // Increase liquidity and transfer liquidity owner reward
            _increaseLiquidity(cache.saleToken, cache.holdToken, loan, amount0, amount1);
            uint256 liquidityOwnerReward = FullMath.mulDiv(
                params.totalfeesOwed,
                cache.holdTokenDebt,
                params.totalBorrowedAmount
            ) / Constants.COLLATERAL_BALANCE_PRECISION;

            Vault(VAULT_ADDRESS).transferToken(cache.holdToken, creditor, liquidityOwnerReward);

            unchecked {
                ++i;
            }
        }
    }

    function _getCurrentSqrtPriceX96(
        bool zeroForA,
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (uint160 sqrtPriceX96) {
        if (!zeroForA) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        address poolAddress = computePoolAddress(tokenA, tokenB, fee);
        (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddress).slot0();
    }

    /**
     * @dev Decreases the liquidity of a position by removing tokens.
     * @param tokenId The ID of the position token.
     * @param liquidity The amount of liquidity to be removed.
     */
    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity) private {
        (uint256 amount0, uint256 amount1) = underlyingPositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        if (amount0 == 0 && amount1 == 0) {
            revert InvalidBorrowedLiquidity(tokenId);
        }

        (amount0, amount1) = underlyingPositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: uint128(amount0),
                amount1Max: uint128(amount1)
            })
        );
    }

    /**
     * @dev Increases the liquidity of a position by providing additional tokens.
     * @param saleToken The address of the sale token.
     * @param holdToken The address of the hold token.
     * @param loan An instance of LoanInfo memory struct containing loan details.
     * @param amount0 The amount of token0 to be added to the liquidity.
     * @param amount1 The amount of token1 to be added to the liquidity.
     */
    function _increaseLiquidity(
        address saleToken,
        address holdToken,
        LoanInfo memory loan,
        uint256 amount0,
        uint256 amount1
    ) private {
        if (amount0 > 0) {
            ++amount0;
        }
        if (amount1 > 0) {
            ++amount1;
        }

        (uint128 restoredLiquidity, , ) = underlyingPositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: loan.tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        if (restoredLiquidity < loan.liquidity) {
            (uint256 holdTokentBalance, uint256 saleTokenBalance) = _getPairBalance(
                holdToken,
                saleToken
            );

            revert InvalidRestoredLiquidity(
                loan.tokenId,
                loan.liquidity,
                restoredLiquidity,
                amount0,
                amount1,
                holdTokentBalance,
                saleTokenBalance
            );
        }
    }

    /**
     * @dev Calculates the amount of hold token required for a swap.
     * @param zeroForSaleToken A boolean value indicating whether the token for sale is the 0th token or not.
     * @param tickLower The lower tick of the liquidity range.
     * @param tickUpper The upper tick of the liquidity range.
     * @param sqrtPriceX96 The square root of the price ratio of the sale token to the hold token.
     * @param liquidity The amount of liquidity.
     * @param holdTokenDebt The amount of hold token debt.
     * @return holdTokenAmountIn The amount of hold token needed to provide the specified liquidity.
     * @return amount0 The amount of token0 calculated based on the liquidity.
     * @return amount1 The amount of token1 calculated based on the liquidity.
     */
    function _getHoldTokenAmountIn(
        bool zeroForSaleToken,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 holdTokenDebt
    ) private pure returns (uint256 holdTokenAmountIn, uint256 amount0, uint256 amount1) {
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        if (zeroForSaleToken) {
            holdTokenAmountIn = amount0 == 0 ? 0 : holdTokenDebt - amount1;
        } else {
            holdTokenAmountIn = amount1 == 0 ? 0 : holdTokenDebt - amount0;
        }
    }

    /**
     * @dev Updates the RestoreLiquidityCache struct with data from the underlyingPositionManager contract.
     * @param zeroForSaleToken A boolean value indicating whether the token for sale is the 0th token or not.
     * @param loan The LoanInfo struct containing loan details.
     * @param cache The RestoreLiquidityCache struct to be updated.
     */
    function _upRestoreLiquidityCache(
        bool zeroForSaleToken,
        LoanInfo memory loan,
        RestoreLiquidityCache memory cache
    ) internal view {
        (
            ,
            ,
            cache.saleToken,
            cache.holdToken,
            cache.fee,
            cache.tickLower,
            cache.tickUpper,
            ,
            ,
            ,
            ,

        ) = underlyingPositionManager.positions(loan.tokenId);

        if (!zeroForSaleToken) {
            (cache.saleToken, cache.holdToken) = (cache.holdToken, cache.saleToken);
        }

        cache.holdTokenDebt = _getSingleSideRoundUpBorrowedAmount(
            zeroForSaleToken,
            cache.tickLower,
            cache.tickUpper,
            loan.liquidity
        );
        cache.sqrtPriceX96 = _getCurrentSqrtPriceX96(
            zeroForSaleToken,
            cache.saleToken,
            cache.holdToken,
            cache.fee
        );
    }
}