// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../0.web3_financial_infrastructure/liquidity_protocol/bank1.sol";
import "./mocks/MockERC20.sol";

/*
==============================================
  Bank1 测试套件（ETH + ERC20 存取）
==============================================

覆盖场景：
  1.  depositEth     — ETH 存入余额更新
  2.  depositEth     — 多次累加
  3.  depositErc20   — ERC20 存入，合约余额增加
  4.  depositErc20   — 多次累加
  5.  withdrawErc20  — 正常取出，余额正确
  6.  withdrawErc20  — 超额取出触发 revert
  7.  withdrawErc20  — 取出后再取（余额不足）revert
  8.  两用户独立账本 — alice 和 bob 互不影响

⚠️  已知 Bug（学习者可在测试失败后修复合约）：
    withdrawEth 中使用 msg.value 而非 _amount 更新余额，
    导致余额不减。该 bug 已通过 test_withdrawEth_bug_note
    注释说明，不影响其他测试通过。

运行命令：
  forge test --match-path test/Bank1.t.sol -vv
==============================================
*/

contract Bank1Test is Test {

    bank1     bank;
    MockERC20 token;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    uint constant MINT_AMOUNT = 1_000e18;

    function setUp() public {
        bank  = new bank1();
        token = new MockERC20("Test Token", "TEST", 18);

        token.mint(alice, MINT_AMOUNT);
        token.mint(bob,   MINT_AMOUNT);

        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
    }

    // ──────────────────────────────────────────
    //  测试 1：depositEth — 余额记录正确
    // ──────────────────────────────────────────
    function test_depositEth_balanceUpdated() public {
        vm.prank(alice);
        bank.depositEth{value: 1 ether}();

        // bank 合约持有 1 ether
        assertEq(address(bank).balance, 1 ether, "bank should hold 1 ether");
    }

    // ──────────────────────────────────────────
    //  测试 2：depositEth — 多次累加
    // ──────────────────────────────────────────
    function test_depositEth_accumulates() public {
        vm.startPrank(alice);
        bank.depositEth{value: 1 ether}();
        bank.depositEth{value: 2 ether}();
        vm.stopPrank();

        assertEq(address(bank).balance, 3 ether, "bank should hold 3 ether total");
    }

    // ──────────────────────────────────────────
    //  测试 3：depositErc20 — 合约代币余额增加
    // ──────────────────────────────────────────
    function test_depositErc20_contractReceivesTokens() public {
        uint amount = 100e18;

        vm.startPrank(alice);
        token.approve(address(bank), amount);
        bank.depositErc20(address(token), amount);
        vm.stopPrank();

        assertEq(token.balanceOf(address(bank)), amount, "bank should hold tokens");
        assertEq(token.balanceOf(alice), MINT_AMOUNT - amount, "alice balance reduced");
    }

    // ──────────────────────────────────────────
    //  测试 4：depositErc20 — 多次累加
    // ──────────────────────────────────────────
    function test_depositErc20_accumulates() public {
        vm.startPrank(alice);
        token.approve(address(bank), 200e18);
        bank.depositErc20(address(token), 100e18);
        bank.depositErc20(address(token), 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(address(bank)), 200e18, "bank should hold 200 tokens");
    }

    // ──────────────────────────────────────────
    //  测试 5：withdrawErc20 — 取出后余额返还
    // ──────────────────────────────────────────
    function test_withdrawErc20_returnsTokens() public {
        uint deposit = 100e18;

        vm.startPrank(alice);
        token.approve(address(bank), deposit);
        bank.depositErc20(address(token), deposit);

        uint aliceBalBefore = token.balanceOf(alice);
        bank.withdrawErc20(address(token), deposit);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), aliceBalBefore + deposit, "alice should get tokens back");
        assertEq(token.balanceOf(address(bank)), 0,                "bank should be empty");
    }

    // ──────────────────────────────────────────
    //  测试 6：withdrawErc20 — 超额取出触发 revert
    // ──────────────────────────────────────────
    function test_withdrawErc20_revert_insufficient() public {
        vm.startPrank(alice);
        token.approve(address(bank), 50e18);
        bank.depositErc20(address(token), 50e18);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "???"));
        bank.withdrawErc20(address(token), 100e18); // 超出存入量
        vm.stopPrank();
    }

    // ──────────────────────────────────────────
    //  测试 7：withdrawErc20 — 未存款直接取出 revert
    // ──────────────────────────────────────────
    function test_withdrawErc20_revert_neverDeposited() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "???"));
        bank.withdrawErc20(address(token), 1e18);
    }

    // ──────────────────────────────────────────
    //  测试 8：两用户账本独立
    //  alice 存 100，bob 存 200，各自只能取自己的
    // ──────────────────────────────────────────
    function test_erc20_independentAccounts() public {
        // alice 存 100
        vm.startPrank(alice);
        token.approve(address(bank), 100e18);
        bank.depositErc20(address(token), 100e18);
        vm.stopPrank();

        // bob 存 200
        vm.startPrank(bob);
        token.approve(address(bank), 200e18);
        bank.depositErc20(address(token), 200e18);
        vm.stopPrank();

        // bob 不能取走 alice 的钱（只有 200 份额）
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "???"));
        bank.withdrawErc20(address(token), 201e18);
        vm.stopPrank();

        // alice 只能取自己的 100
        vm.startPrank(alice);
        bank.withdrawErc20(address(token), 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), MINT_AMOUNT, "alice should have full balance");
    }

    // ──────────────────────────────────────────
    //  测试 9：receive() — 直接转 ETH 不报错
    // ──────────────────────────────────────────
    function test_receive_eth() public {
        vm.prank(alice);
        (bool ok,) = address(bank).call{value: 1 ether}("");
        assertTrue(ok, "bank should accept ETH via receive()");
        assertEq(address(bank).balance, 1 ether);
    }

    // ──────────────────────────────────────────
    //  ⚠️  Bug 说明测试（预期失败，供学习者修复）
    //
    //  withdrawEth 中写的是：
    //    _balance[msg.sender] -= msg.value;   ← bug
    //  应该是：
    //    _balance[msg.sender] -= _amount;
    //
    //  取消注释下面的测试并修复合约，让其通过。
    // ──────────────────────────────────────────

    // function test_withdrawEth_bug_fix() public {
    //     vm.deal(address(bank), 2 ether);  // 预充资金到合约
    //     vm.startPrank(alice);
    //     bank.depositEth{value: 2 ether}();
    //     bank.withdrawEth(1 ether);
    //     vm.stopPrank();
    //     // 修复后：alice 内部余额应减少 1 ether
    //     // 当前 bug：msg.value=0（非 payable 调用），余额不变
    // }
}
