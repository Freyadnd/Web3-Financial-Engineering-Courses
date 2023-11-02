// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*
=====================================
  AMM DEX — 自动做市商去中心化交易所
=====================================

核心机制：恒定乘积公式  x * y = k
  - x = tokenA 储备量
  - y = tokenB 储备量
  - k = 常数，每次 swap 后保持不变（扣费后近似不变）

功能模块：
  1. addLiquidity    — 添加流动性，获得 LP Token
  2. removeLiquidity — 移除流动性，销毁 LP Token 取回代币
  3. swap            — 代币兑换（含 0.3% 手续费）
  4. getAmountOut    — 查询兑换数量（含手续费）
  5. spotPrice       — 查询当前即时价格

LP Token 说明：
  - 本合约同时是 ERC20，代表流动性份额
  - 首次注入流动性：LP = sqrt(amountA * amountB)
  - 后续注入：LP = min(amountA/reserveA, amountB/reserveB) * totalSupply

配合杠杆的玩法（进阶）：
  1. LP 杠杆：存 LP 贷出 LP（做市杠杆）
  2. Pair 币杠杆：存 LP 贷出 tokenA 或 tokenB（做市同时可做多/做空某 token）
  3. 单 token 杠杆：存 tokenA 按价格贷出 tokenB（单币杠杆，利息分给 LP）
*/

contract AMM is ERC20 {

    // ========== 状态变量 ==========

    IERC20 public tokenA;
    IERC20 public tokenB;

    uint public reserveA;   // tokenA 当前储备量
    uint public reserveB;   // tokenB 当前储备量

    uint public constant FEE_RATE        = 3;     // 手续费率分子：3
    uint public constant FEE_DENOMINATOR = 1000;  // 手续费率分母：1000 => 0.3%

    // ========== 事件 ==========

    event AddLiquidity(
        address indexed provider,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    event RemoveLiquidity(
        address indexed provider,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    event Swap(
        address indexed user,
        address indexed tokenIn,
        uint    amountIn,
        address indexed tokenOut,
        uint    amountOut
    );

    // ========== 构造函数 ==========

    constructor(address _tokenA, address _tokenB)
        ERC20("AMM LP Token", "LP")
    {
        require(_tokenA != _tokenB, "same token");
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // ========== 1. 添加流动性 ==========
    //
    // 用户存入 amountA 个 tokenA 和 amountB 个 tokenB，
    // 获得代表份额的 LP Token。
    //
    // 调用前需先 approve 本合约：
    //   tokenA.approve(address(amm), amountA)
    //   tokenB.approve(address(amm), amountB)

    function addLiquidity(uint amountA, uint amountB)
        external
        returns (uint liquidity)
    {
        require(amountA > 0 && amountB > 0, "amount = 0");

        // 将代币转入合约
        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);

        uint supply = totalSupply();

        if (supply == 0) {
            // 首次添加流动性：LP = sqrt(amountA * amountB)
            // 使用几何平均，避免 LP 价格被操纵
            liquidity = sqrt(amountA * amountB);
        } else {
            // 后续添加：按当前比例，取较小值，防止套利
            liquidity = min(
                amountA * supply / reserveA,
                amountB * supply / reserveB
            );
        }

        require(liquidity > 0, "insufficient liquidity minted");

        _mint(msg.sender, liquidity);

        reserveA += amountA;
        reserveB += amountB;

        emit AddLiquidity(msg.sender, amountA, amountB, liquidity);
    }

    // ========== 2. 移除流动性 ==========
    //
    // 销毁 liquidity 数量的 LP Token，
    // 按比例取回 tokenA 和 tokenB。

    function removeLiquidity(uint liquidity)
        external
        returns (uint amountA, uint amountB)
    {
        require(liquidity > 0, "liquidity = 0");

        uint supply = totalSupply();

        // 按 LP 份额比例计算应归还数量
        amountA = liquidity * reserveA / supply;
        amountB = liquidity * reserveB / supply;

        require(amountA > 0 && amountB > 0, "insufficient liquidity burned");

        // 先销毁 LP Token，防重入
        _burn(msg.sender, liquidity);

        reserveA -= amountA;
        reserveB -= amountB;

        tokenA.transfer(msg.sender, amountA);
        tokenB.transfer(msg.sender, amountB);

        emit RemoveLiquidity(msg.sender, amountA, amountB, liquidity);
    }

    // ========== 3. 交易/兑换 ==========
    //
    // 输入 tokenIn（tokenA 或 tokenB），输出对应代币。
    // 手续费 0.3% 留在池中，自动复利给 LP 持有者。
    //
    // 恒定乘积公式（含手续费）：
    //   amountOut = reserveOut * amountIn * (1 - fee)
    //               / (reserveIn + amountIn * (1 - fee))
    //
    // minAmountOut：最小接受输出量（滑点保护）

    function swap(
        address _tokenIn,
        uint    amountIn,
        uint    minAmountOut
    )
        external
        returns (uint amountOut)
    {
        require(
            _tokenIn == address(tokenA) || _tokenIn == address(tokenB),
            "invalid token"
        );
        require(amountIn > 0, "amountIn = 0");

        bool isTokenA = (_tokenIn == address(tokenA));

        (
            IERC20 tIn,
            IERC20 tOut,
            uint   reserveIn,
            uint   reserveOut
        ) = isTokenA
            ? (tokenA, tokenB, reserveA, reserveB)
            : (tokenB, tokenA, reserveB, reserveA);

        // 转入代币
        tIn.transferFrom(msg.sender, address(this), amountIn);

        // 计算输出量（含 0.3% 手续费）
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);

        require(amountOut >= minAmountOut, "slippage exceeded");
        require(amountOut < reserveOut,    "insufficient liquidity");

        // 转出代币（先更新储备再转出，防重入）
        if (isTokenA) {
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
        }

        tOut.transfer(msg.sender, amountOut);

        emit Swap(msg.sender, _tokenIn, amountIn, address(tOut), amountOut);
    }

    // ========== 查询函数 ==========

    // 根据输入量计算输出量（含 0.3% 手续费）
    // 可在链下或链上调用，不修改状态
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    )
        public
        pure
        returns (uint amountOut)
    {
        require(amountIn > 0,                      "amountIn = 0");
        require(reserveIn > 0 && reserveOut > 0,   "no liquidity");

        // amountIn 扣除手续费后的有效输入
        uint amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_RATE);

        // x * y = k => (reserveIn + amountIn') * (reserveOut - amountOut) = k
        amountOut = reserveOut * amountInWithFee
                    / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    // 查询 tokenA => tokenB 兑换数量
    function getAmountOutAtoB(uint amountA) external view returns (uint) {
        return getAmountOut(amountA, reserveA, reserveB);
    }

    // 查询 tokenB => tokenA 兑换数量
    function getAmountOutBtoA(uint amountB) external view returns (uint) {
        return getAmountOut(amountB, reserveB, reserveA);
    }

    // 即时价格：1 tokenA = ? tokenB（精度 1e18）
    function spotPrice() external view returns (uint price) {
        require(reserveA > 0, "no liquidity");
        price = reserveB * 1e18 / reserveA;
    }

    // 查询池中储备量
    function getReserves() external view returns (uint _reserveA, uint _reserveB) {
        _reserveA = reserveA;
        _reserveB = reserveB;
    }

    // ========== 工具函数 ==========

    // 整数平方根（Babylonian method）
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}
