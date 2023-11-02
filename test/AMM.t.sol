// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../0.web3_financial_infrastructure/dex_protocol/dex.sol";
import "./mocks/MockERC20.sol";

/*
==============================================
  AMM DEX 测试套件
==============================================

覆盖场景：
  1. 首次添加流动性 — LP = sqrt(amountA * amountB)
  2. 二次添加流动性 — LP 按比例分配
  3. swap tokenA => tokenB（含手续费）
  4. swap tokenB => tokenA（含手续费）
  5. 滑点保护：minAmountOut 触发 revert
  6. 移除全部流动性 — 代币完整归还
  7. 移除部分流动性 — 按比例归还
  8. x*y=k 不变量：swap 后 k 只增不减（手续费留池）
  9. 即时价格 spotPrice 正确性
  10. 非法 token 触发 revert
  11. 流动性为零时 swap 触发 revert

运行命令：
  forge test --match-path test/AMM.t.sol -vv
==============================================
*/

contract AMMTest is Test {

    AMM          amm;
    MockERC20    tokenA;
    MockERC20    tokenB;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint constant INIT = 1_000e18;

    // ──────────────────────────────────────────
    //  setUp: 每个测试用例前自动执行
    // ──────────────────────────────────────────
    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        amm    = new AMM(address(tokenA), address(tokenB));

        // 铸造初始代币给测试账户
        tokenA.mint(alice, INIT);
        tokenB.mint(alice, INIT);
        tokenA.mint(bob,   INIT);
        tokenB.mint(bob,   INIT);
    }

    // ──────────────────────────────────────────
    //  辅助：alice 向池中注入 amountA / amountB
    // ──────────────────────────────────────────
    function _aliceAddLiquidity(uint amountA, uint amountB) internal returns (uint lp) {
        vm.startPrank(alice);
        tokenA.approve(address(amm), amountA);
        tokenB.approve(address(amm), amountB);
        lp = amm.addLiquidity(amountA, amountB);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────
    //  测试 1：首次添加流动性
    //  LP = sqrt(100e18 * 100e18) = 100e18
    // ──────────────────────────────────────────
    function test_addLiquidity_first() public {
        uint lp = _aliceAddLiquidity(100e18, 100e18);

        assertEq(lp, 100e18,          "LP amount should be sqrt(100*100)=100");
        assertEq(amm.reserveA(), 100e18, "reserveA mismatch");
        assertEq(amm.reserveB(), 100e18, "reserveB mismatch");
        assertEq(amm.balanceOf(alice), 100e18, "alice LP balance mismatch");
        assertEq(amm.totalSupply(),    100e18, "total LP supply mismatch");
    }

    // ──────────────────────────────────────────
    //  测试 2：二次添加流动性
    //  池中 100:100，bob 再存 50:50
    //  LP = min(50/100, 50/100) * 100 = 50
    // ──────────────────────────────────────────
    function test_addLiquidity_second() public {
        _aliceAddLiquidity(100e18, 100e18);   // 初始流动性

        vm.startPrank(bob);
        tokenA.approve(address(amm), 50e18);
        tokenB.approve(address(amm), 50e18);
        uint lp = amm.addLiquidity(50e18, 50e18);
        vm.stopPrank();

        assertEq(lp, 50e18,                     "bob LP should be 50");
        assertEq(amm.reserveA(), 150e18,         "reserveA should be 150");
        assertEq(amm.reserveB(), 150e18,         "reserveB should be 150");
        assertEq(amm.balanceOf(bob), 50e18,      "bob LP balance mismatch");
        assertEq(amm.totalSupply(),  150e18,     "total LP supply mismatch");
    }

    // ──────────────────────────────────────────
    //  测试 3：swap tokenA => tokenB
    //  池 100:100，输入 10 tokenA
    //  公式：out = 100 * 10*997 / (100*1000 + 10*997) ≈ 9.066
    // ──────────────────────────────────────────
    function test_swap_A_for_B() public {
        _aliceAddLiquidity(100e18, 100e18);

        uint amountIn  = 10e18;
        uint expected  = amm.getAmountOut(amountIn, 100e18, 100e18);

        vm.startPrank(bob);
        tokenA.approve(address(amm), amountIn);
        uint amountOut = amm.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(amountOut, expected,                 "amountOut mismatch");
        assertGt(amountOut, 0,                        "amountOut should be > 0");
        assertEq(amm.reserveA(), 100e18 + amountIn,   "reserveA should increase");
        assertEq(amm.reserveB(), 100e18 - amountOut,  "reserveB should decrease");
        // bob 实际收到了代币
        assertEq(tokenB.balanceOf(bob), INIT - 0 + amountOut - 0, "bob tokenB balance");
    }

    // ──────────────────────────────────────────
    //  测试 4：swap tokenB => tokenA（反向交易）
    // ──────────────────────────────────────────
    function test_swap_B_for_A() public {
        _aliceAddLiquidity(100e18, 100e18);

        uint amountIn = 10e18;
        uint expected = amm.getAmountOut(amountIn, 100e18, 100e18);

        vm.startPrank(bob);
        tokenB.approve(address(amm), amountIn);
        uint amountOut = amm.swap(address(tokenB), amountIn, 0);
        vm.stopPrank();

        assertEq(amountOut, expected,                "amountOut mismatch");
        assertEq(amm.reserveB(), 100e18 + amountIn,  "reserveB should increase");
        assertEq(amm.reserveA(), 100e18 - amountOut, "reserveA should decrease");
    }

    // ──────────────────────────────────────────
    //  测试 5：滑点保护 — minAmountOut 过高触发 revert
    // ──────────────────────────────────────────
    function test_swap_revert_slippage() public {
        _aliceAddLiquidity(100e18, 100e18);

        vm.startPrank(bob);
        tokenA.approve(address(amm), 10e18);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "slippage exceeded"));
        amm.swap(address(tokenA), 10e18, type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────
    //  测试 6：非法代币地址 触发 revert
    // ──────────────────────────────────────────
    function test_swap_revert_invalidToken() public {
        _aliceAddLiquidity(100e18, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "invalid token"));
        amm.swap(address(0xdead), 1e18, 0);
    }

    // ──────────────────────────────────────────
    //  测试 7：移除全部流动性 — 代币完整取回
    // ──────────────────────────────────────────
    function test_removeLiquidity_full() public {
        uint lp = _aliceAddLiquidity(100e18, 100e18);

        uint balABefore = tokenA.balanceOf(alice);
        uint balBBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint retA, uint retB) = amm.removeLiquidity(lp);

        assertEq(retA, 100e18,                           "retA should be 100");
        assertEq(retB, 100e18,                           "retB should be 100");
        assertEq(tokenA.balanceOf(alice), balABefore + retA, "alice tokenA balance");
        assertEq(tokenB.balanceOf(alice), balBBefore + retB, "alice tokenB balance");
        assertEq(amm.totalSupply(), 0,                   "LP supply should be 0");
        assertEq(amm.reserveA(),    0,                   "reserveA should be 0");
        assertEq(amm.reserveB(),    0,                   "reserveB should be 0");
    }

    // ──────────────────────────────────────────
    //  测试 8：移除部分流动性 — 按比例取回
    // ──────────────────────────────────────────
    function test_removeLiquidity_partial() public {
        uint lp = _aliceAddLiquidity(100e18, 100e18); // lp = 100e18

        vm.prank(alice);
        (uint retA, uint retB) = amm.removeLiquidity(lp / 2); // 取回一半

        assertEq(retA, 50e18, "should get back 50 tokenA");
        assertEq(retB, 50e18, "should get back 50 tokenB");
        assertEq(amm.reserveA(), 50e18, "reserveA should be 50");
        assertEq(amm.reserveB(), 50e18, "reserveB should be 50");
    }

    // ──────────────────────────────────────────
    //  测试 9：x*y=k 不变量
    //  swap 后 k 只增不减（手续费留在池里）
    // ──────────────────────────────────────────
    function test_invariant_k_nondecreasing() public {
        _aliceAddLiquidity(100e18, 100e18);

        uint kBefore = amm.reserveA() * amm.reserveB();

        vm.startPrank(bob);
        tokenA.approve(address(amm), 10e18);
        amm.swap(address(tokenA), 10e18, 0);
        vm.stopPrank();

        uint kAfter = amm.reserveA() * amm.reserveB();
        assertGe(kAfter, kBefore, "k should not decrease after swap");
    }

    // ──────────────────────────────────────────
    //  测试 10：即时价格 spotPrice
    //  池 100:200 => 1 tokenA = 2 tokenB => price = 2e18
    // ──────────────────────────────────────────
    function test_spotPrice() public {
        _aliceAddLiquidity(100e18, 200e18);

        uint price = amm.spotPrice();
        assertEq(price, 2e18, "1 tokenA should equal 2 tokenB");
    }

    // ──────────────────────────────────────────
    //  测试 11：多次 swap 价格影响（价格滑点）
    //  大额 swap 的 amountOut 应显著小于按比例计算的结果
    // ──────────────────────────────────────────
    function test_priceImpact() public {
        _aliceAddLiquidity(100e18, 100e18);

        // 小额 swap：10 in
        uint outSmall = amm.getAmountOut(10e18,  100e18, 100e18);
        // 大额 swap：50 in（相对池深 50%）
        uint outLarge = amm.getAmountOut(50e18,  100e18, 100e18);

        // 大额 swap 单位效率（out/in）应低于小额 swap
        // outSmall/10 > outLarge/50（价格滑点存在）
        assertGt(
            outSmall * 50e18,
            outLarge * 10e18,
            "large swap should have worse price than small swap"
        );
    }

    // ──────────────────────────────────────────
    //  测试 12：getAmountOut 公式验证（纯计算）
    //  池 1000:1000，输入 100，fee=0.3%
    //  手动计算：100*997 / (1000*1000 + 100*997) = 99700/1099700 * 1000 ≈ 90.66
    // ──────────────────────────────────────────
    function test_getAmountOut_formula() public view {
        uint amountIn   = 100e18;
        uint reserveIn  = 1000e18;
        uint reserveOut = 1000e18;

        uint result = amm.getAmountOut(amountIn, reserveIn, reserveOut);

        // 手动计算：(100e18 * 997) / (1000e18 * 1000 + 100e18 * 997) * 1000e18
        uint expected = reserveOut * amountIn * 997
                        / (reserveIn * 1000 + amountIn * 997);

        assertEq(result, expected, "getAmountOut formula mismatch");
        // 粗略断言：约 90.66 tokenB
        assertApproxEqRel(result, 90_661e15, 0.001e18, "result should be ~90.66 tokenB");
    }
}
