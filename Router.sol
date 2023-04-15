// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./IArbitrager.sol";
import "./IWETH.sol";
import "./IUniswapV2Pair.sol";

contract MevSwapRouter {
    using SafeMath for uint;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    modifier onlyOwner () {
        require(msg.sender == owner, "unauthorized");
        _;
    }

    struct SwapEnvelope {
        uint amountIn;
        uint amountOut;

        address tokenIn;
        address tokenOut;
        address to;

        uint8 arbitragingIndex;
        uint16 arbitrageMeanFee;

        address[] swapPairs;
        uint16[] fees;
        uint8[] tokenInIndexes;
        uint8[] pairTypes;
    }

    address public immutable WETH;
    address public immutable owner;
    address public arbitrager;
    address public feeTaker;
    mapping(address => bool) private feeTokenWhitelist;

    constructor(address _feeTaker, address _weth) {
        owner = msg.sender;
        feeTaker = _feeTaker;
        WETH = _weth;

        // weth whitelisted by default for fee
        whitelistFeeToken(WETH, true);
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    function setFeeTokenWhitelist(address[] calldata tokens, bool[] calldata enabled) external onlyOwner {
        require(tokens.length == enabled.length, "invalid length");
        for (uint i = 0; i < tokens.length; i++) {
            whitelistFeeToken(tokens[i], enabled[i]);
        }
    }

    function whitelistFeeToken(address token, bool enabled) internal {
        feeTokenWhitelist[token] = enabled;
    }

    function setFeeTaker(address newFeeTaker) external onlyOwner {
        feeTaker = newFeeTaker;
    }

    function setArbitrager(address newArbitrager) external onlyOwner {
        arbitrager = newArbitrager;
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint pairFee) internal pure returns (uint amountOut) {
        amountOut = (amountIn * pairFee * reserveOut) / ((reserveIn * 10000) + amountIn * pairFee);
    }

    function haveMultiSwapFee(SwapEnvelope calldata swapEnvelope) internal returns (bool) {
        if (swapEnvelope.swapPairs.length == 1) {
            return false;
        }

        address currentFactory = IUniswapV2Pair(swapEnvelope.swapPairs[0]).factory();
        uint i = 1;
        for (i; i < swapEnvelope.arbitragingIndex;) {
            if (IUniswapV2Pair(swapEnvelope.swapPairs[i]).factory() != currentFactory) {
                return true;
            }
        unchecked { ++i; }
        }

        return false;
    }

    function swap(bool _haveMultiSwapFee, SwapEnvelope calldata swapEnvelope) internal virtual {
        (uint amount0Out, uint amount1Out) = (0, 0);
        (uint reserve0, uint reserve1) = (0, 0);
        uint amountIn = 0;
        uint i = 0;
        uint routerFeeBalance = 0;
        address _to;
        address currentPair;
        address tokenIn;
        uint8 tokenInIndex;

        for (i; i < swapEnvelope.arbitragingIndex;) {
            tokenInIndex = swapEnvelope.tokenInIndexes[i];
            currentPair = swapEnvelope.swapPairs[i];

            (reserve0, reserve1,) = IUniswapV2Pair(currentPair).getReserves();

            tokenIn = tokenInIndex == 0 ?
            IUniswapV2Pair(currentPair).token0() :
            IUniswapV2Pair(currentPair).token1();

            // this will handle any fee on transfer
            amountIn = IERC20(tokenIn).balanceOf(currentPair).sub(
                tokenInIndex == 0 ? reserve0 : reserve1
            );

            // becomes amount out - calculate the amount out on the real tokens amount received by the pair
            amountIn = getAmountOut(
                amountIn,
                tokenInIndex == 0 ? reserve0 : reserve1,
                tokenInIndex == 0 ? reserve1 : reserve0,
                swapEnvelope.fees[i]
            );

            (amount0Out, amount1Out) = tokenInIndex == 0 ? (uint(0), amountIn) : (amountIn, uint(0));

            bool lastPathPair = i == swapEnvelope.arbitragingIndex - 1;
            bool handleFee = false;

            if (_haveMultiSwapFee) {
                // recycle tokenIn var to become tokenOut
                tokenIn = swapEnvelope.tokenInIndexes[i] == 0 ?
                IUniswapV2Pair(currentPair).token1() :
                IUniswapV2Pair(currentPair).token0();

                handleFee = feeTokenWhitelist[tokenIn] || lastPathPair;
                if (handleFee) {
                    _haveMultiSwapFee = false;
                    _to = address(this);
                    routerFeeBalance = IERC20(tokenIn).balanceOf(address(this));
                } else {
                    _to = lastPathPair ? swapEnvelope.to : swapEnvelope.swapPairs[i + 1];
                }
            } else {
                _to = lastPathPair ? swapEnvelope.to : swapEnvelope.swapPairs[i + 1];
            }

            if (swapEnvelope.pairTypes[i] == 0) {
                IUniswapV2Pair(currentPair).swap(
                    amount0Out, amount1Out, _to, new bytes(0)
                );
            } else if (swapEnvelope.pairTypes[i] == 1) {
                IUniswapV2Pair(currentPair).swap(
                    amount0Out, amount1Out, _to
                );
            } else {
                revert("unknown pair type");
            }

            if (handleFee) {
                // at this point, the router is holding the amountOut
                // forward the fee to the feeTaker and proceed to the next step of the path

                // check the router balance to prevent weird scenario where the router actually hold some of the tokens received
                routerFeeBalance = IERC20(tokenIn).balanceOf(address(this)).sub(routerFeeBalance);
                // forward fee and amount
                uint feeAmount = routerFeeBalance.sub(routerFeeBalance.mul(9990).div(10000));
                TransferHelper.safeTransfer(tokenIn, feeTaker, feeAmount);
                _to = lastPathPair ? swapEnvelope.to : swapEnvelope.swapPairs[i + 1];
                TransferHelper.safeTransfer(tokenIn, _to, routerFeeBalance.sub(feeAmount));
            }

        unchecked { ++i; }
        }
    }

    function performArbitrage(SwapEnvelope calldata swapEnvelope) internal {
        if (swapEnvelope.arbitragingIndex >= swapEnvelope.swapPairs.length) {
            return;
        }

        if (arbitrager == address(0)) {
            return;
        }

        try IArbitrager(arbitrager).arbitrage(
            swapEnvelope.to,
            swapEnvelope.arbitrageMeanFee,
            swapEnvelope.swapPairs[swapEnvelope.arbitragingIndex:],
            swapEnvelope.fees[swapEnvelope.arbitragingIndex:],
            swapEnvelope.tokenInIndexes[swapEnvelope.arbitragingIndex:],
            swapEnvelope.pairTypes[swapEnvelope.arbitragingIndex:]
        ) {} catch {}
    }

    function checkOutputAndPerformArbitrages(uint balanceBefore, SwapEnvelope calldata swapEnvelope) internal {
        uint balanceAfter = IERC20(swapEnvelope.tokenOut).balanceOf(swapEnvelope.to);
        if (msg.sender == swapEnvelope.to && swapEnvelope.tokenIn == swapEnvelope.tokenOut) {
            // need to take amountIn into account for this scenario
            balanceAfter = balanceAfter.add(swapEnvelope.amountIn);
        }
        require(
            balanceAfter.sub(balanceBefore) >= swapEnvelope.amountOut,
            'Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );

        performArbitrage(swapEnvelope);
    }

    function swapExactTokensForTokens(
        uint deadline,
        SwapEnvelope calldata swapEnvelope
    ) external virtual ensure(deadline) {
        uint balanceBefore = IERC20(swapEnvelope.tokenOut).balanceOf(swapEnvelope.to);

        bool _haveMultiSwapFee = haveMultiSwapFee(swapEnvelope);
        uint amountIn = swapEnvelope.amountIn;

        if (_haveMultiSwapFee && feeTokenWhitelist[swapEnvelope.tokenIn]) {
            uint feeAmount = amountIn.sub(amountIn.mul(9990).div(10000));
            amountIn = amountIn.sub(feeAmount);

            TransferHelper.safeTransferFrom(
                swapEnvelope.tokenIn, msg.sender, swapEnvelope.swapPairs[0], amountIn
            );
            TransferHelper.safeTransferFrom(
                swapEnvelope.tokenIn, msg.sender, feeTaker, feeAmount
            );

            // mark as taken
            _haveMultiSwapFee = false;
        } else {
            TransferHelper.safeTransferFrom(
                swapEnvelope.tokenIn, msg.sender, swapEnvelope.swapPairs[0], amountIn
            );
        }

        swap(_haveMultiSwapFee, swapEnvelope);

        checkOutputAndPerformArbitrages(balanceBefore, swapEnvelope);
    }

    function swapExactETHForTokens(
        uint deadline,
        SwapEnvelope calldata swapEnvelope
    ) external virtual payable ensure(deadline) {
        require(swapEnvelope.tokenIn == WETH, 'Router: INVALID_PATH');

        uint amountIn = swapEnvelope.amountIn;
        uint balanceBefore = IERC20(swapEnvelope.tokenOut).balanceOf(swapEnvelope.to);
        IWETH(WETH).deposit{value: amountIn}();

        bool _haveMultiSwapFee = haveMultiSwapFee(swapEnvelope);
        if (_haveMultiSwapFee) {
            // take multiswap fee as WETH
            uint feeAmount = amountIn.sub(amountIn.mul(9990).div(10000));
            amountIn = amountIn.sub(feeAmount);

            assert(IWETH(WETH).transfer(swapEnvelope.swapPairs[0], amountIn));
            assert(IWETH(WETH).transfer(feeTaker, feeAmount));

            // mark as taken
            _haveMultiSwapFee = false;
        } else {
            assert(IWETH(WETH).transfer(swapEnvelope.swapPairs[0], amountIn));
        }

        swap(_haveMultiSwapFee, swapEnvelope);

        checkOutputAndPerformArbitrages(balanceBefore, swapEnvelope);
    }

    // just in case ETH is sent to the contract for some weird reasons
    function emergencyWithdrawETH() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    // just in case tokens are sent to the contract for some weird reasons
    function emergencyWithdraw(address token) external onlyOwner {
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}