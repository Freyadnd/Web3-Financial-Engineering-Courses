
<h1 align="center">
  Web3 金融工程课程
</h1>

<h2 align="center">
  从零构建 DeFi 基础设施 · 代码即课堂
</h2>

[![GitHub stars](https://img.shields.io/github/stars/PhiloCwh/Web3-Financial-Engineering-Courses/.svg?style=social&label=Stars)](https://github.com/PhiloCwh/Web3-Financial-Engineering-Courses)
[![GitHub watchers](https://img.shields.io/github/watchers/PhiloCwh/Web3-Financial-Engineering-Courses.svg?style=social&label=Watch)](https://github.com/PhiloCwh/Web3-Financial-Engineering-Courses)

---

## 项目简介

一起从 0 到 1，从基础知识和代码层面构建 DeFi 基础设施（DEX、流动性协议……），
再到构建传统金融衍生品（期货、期权、远期……）。

每个模块遵循同一节奏：

> **数学原理 → 代码实现 → 测试验证 → 应用思考**

---

## 目录

- [快速开始](#快速开始)
- [模块 0.1 · AMM DEX](#模块-01--amm-dex)
- [模块 0.2 · 流动性协议（银行）](#模块-02--流动性协议银行)
- [后续模块路线图](#后续模块路线图)
- [视频平台](#视频平台)

---

## 快速开始

### 环境要求

| 工具 | 版本 | 安装 |
|------|------|------|
| [Foundry](https://getfoundry.sh) | ≥ 1.0 | `curl -L https://foundry.paradigm.xyz \| bash` |
| Git | 任意 | 系统自带 |

### 克隆并安装依赖

```bash
git clone https://github.com/PhiloCwh/Web3-Financial-Engineering-Courses.git
cd Web3-Financial-Engineering-Courses

# 安装 OpenZeppelin（首次运行需要）
forge install OpenZeppelin/openzeppelin-contracts
```

### 运行所有测试

```bash
forge test -vv
```

预期输出：

```
Ran 12 tests for test/AMM.t.sol:AMMTest       ✓ 12 passed
Ran  9 tests for test/Bank1.t.sol:Bank1Test   ✓  9 passed
21 tests passed, 0 failed
```

### 运行单个模块的测试

```bash
# 只跑 AMM 测试
forge test --match-path test/AMM.t.sol -vv

# 只跑 Bank1 测试
forge test --match-path test/Bank1.t.sol -vv

# 查看详细 gas 报告
forge test --gas-report
```

### 项目文件结构

```
Web3-Financial-Engineering-Courses/
├── foundry.toml                              # Foundry 配置
├── lib/
│   └── openzeppelin-contracts/               # OZ 合约库
├── test/
│   ├── mocks/MockERC20.sol                   # 测试用 ERC20
│   ├── AMM.t.sol                             # AMM DEX 测试（12 个）
│   └── Bank1.t.sol                           # Bank1 测试（9 个）
└── 0.web3_financial_infrastructure/
    ├── dex_protocol/
    │   └── dex.sol                           # ← 模块 0.1：AMM DEX
    └── liquidity_protocol/
        ├── bank0.sol                         # ETH 存取（最简版）
        ├── bank1.sol                         # ETH + ERC20 存取
        └── bank.sol                          # 完整借贷协议（进阶）
```

---

## 模块 0.1 · AMM DEX

> 文件：`0.web3_financial_infrastructure/dex_protocol/dex.sol`
> 测试：`test/AMM.t.sol`

### 什么是 AMM？

传统交易所用**订单簿**撮合买卖双方。AMM（自动做市商）用一条**数学曲线**取代订单簿，
任何时刻都能自动给出兑换价格——不需要对手方，不需要人工报价。

Uniswap V2（本模块参考对象）使用的曲线是：

```
x · y = k
```

- `x`：池中 tokenA 的数量
- `y`：池中 tokenB 的数量
- `k`：常数（每次 swap 后保持近似不变）

**核心直觉**：你往池子里放更多 tokenA，池子里 tokenB 就必须变少，来维持乘积 k 不变。
这就是价格——tokenA 供给多了，它相对 tokenB 就变便宜了。

---

### Step 1 · 部署合约

```solidity
// 创建一个 ETH/USDC 交易对
AMM amm = new AMM(address(WETH), address(USDC));
```

构造函数只存两件事：tokenA 和 tokenB 的地址。
此时池子里没有资产，`reserveA = reserveB = 0`。

---

### Step 2 · 添加流动性（`addLiquidity`）

**谁来添加？** 做市商（Liquidity Provider，LP）。
他们存入双边资产，换取 **LP Token**（代表池子份额的凭证）。

```solidity
// 先授权（ERC20 标准步骤）
tokenA.approve(address(amm), 100e18);
tokenB.approve(address(amm), 100e18);

// 存入 100 tokenA + 100 tokenB
uint lpReceived = amm.addLiquidity(100e18, 100e18);
// lpReceived = sqrt(100e18 × 100e18) = 100e18
```

**首次注入的 LP 计算公式：**

```
LP = sqrt(amountA × amountB)
```

使用几何平均的原因：让 LP 的价值与代币单价无关，防止首个 LP 通过微小注入操纵单价。

**后续注入的 LP 计算公式：**

```
LP = min(amountA / reserveA, amountB / reserveB) × totalSupply
```

取较小值是为了防止单边注入套利——如果你存入的比例不对，只会按当前池子比例计算，
多余的代币会退回（本合约中实际上需要调用方传入正确比例，否则会有精度损失）。

**代码走读（`dex.sol:addLiquidity`）：**

```
用户调用 addLiquidity(amountA, amountB)
    ↓
transferFrom 把两种代币转入合约
    ↓
计算 LP 数量
    ├─ 首次：LP = sqrt(amountA * amountB)
    └─ 后续：LP = min(amountA/reserveA, amountB/reserveB) * totalSupply
    ↓
_mint(msg.sender, LP)   → 铸造 LP Token 给用户
    ↓
reserveA += amountA     → 更新储备量
reserveB += amountB
```

---

### Step 3 · 代币兑换（`swap`）

```solidity
// bob 想用 10 tokenA 换 tokenB
// 先查一下能换多少
uint expectedOut = amm.getAmountOutAtoB(10e18);
// expectedOut ≈ 9.066e18（含 0.3% 手续费）

// 设置滑点保护：最少要收到 9e18（否则 revert）
tokenA.approve(address(amm), 10e18);
uint received = amm.swap(address(tokenA), 10e18, 9e18);
```

**含手续费的恒定乘积公式：**

设 `amountIn` 为输入量，`fee = 0.3% = 3/1000`：

```
amountIn_effective = amountIn × (1 - fee)
                   = amountIn × 997 / 1000

amountOut = reserveOut × amountIn_effective
            / (reserveIn + amountIn_effective)
```

**为什么要乘以 997/1000 而不是直接 × 0.997？**
Solidity 没有小数，所有计算必须用整数。997/1000 等价于 0.3% 手续费，
且乘法先于除法可以避免精度损失。

**手续费去哪了？**
手续费**留在池子里**。swap 后 `reserveIn` 增加的是完整的 `amountIn`，
但 `reserveOut` 只减少 `amountOut`（< 理论值），差价就是手续费。
这意味着每次 swap 后 `k` 微微增大，LP 持有者自动按份额受益。

**代码走读（`dex.sol:swap`）：**

```
用户调用 swap(tokenIn, amountIn, minAmountOut)
    ↓
验证 tokenIn 是 tokenA 或 tokenB
    ↓
transferFrom → 把 amountIn 转入合约
    ↓
getAmountOut(amountIn, reserveIn, reserveOut) → 计算输出量
    ↓
require(amountOut >= minAmountOut)  → 滑点保护
    ↓
更新储备量
├─ reserveIn  += amountIn
└─ reserveOut -= amountOut
    ↓
transfer → 把 amountOut 发给用户
```

**价格滑点直觉：**

| swap 规模 | reserveA | 对应 amountOut |
|-----------|----------|----------------|
| 10 in / 100 池 (10%) | 100→110 | ≈ 9.07（理论 10）|
| 50 in / 100 池 (50%) | 100→150 | ≈ 33.2（理论 50）|
| 90 in / 100 池 (90%) | 100→190 | ≈ 47.3（理论 90）|

池子越浅，大额交易的价格损耗越大。这是 AMM 设计上**鼓励深度流动性**的内在机制。

---

### Step 4 · 移除流动性（`removeLiquidity`）

```solidity
// alice 持有 100 LP，全部取回
(uint retA, uint retB) = amm.removeLiquidity(100e18);
// 如果期间有人 swap，retA 和 retB 会因手续费而略多于初始存入量
```

**计算公式：**

```
amountA = liquidity / totalSupply × reserveA
amountB = liquidity / totalSupply × reserveB
```

**代码走读（`dex.sol:removeLiquidity`）：**

```
用户调用 removeLiquidity(liquidity)
    ↓
按比例计算 amountA 和 amountB
    ↓
_burn(msg.sender, liquidity)  → 先销毁 LP（防重入）
    ↓
reserveA -= amountA
reserveB -= amountB
    ↓
transfer tokenA 和 tokenB 给用户
```

---

### 完整交互示例

```bash
# 部署后（用 Foundry script 或 cast）：

# 1. alice 添加流动性
cast send $AMM "addLiquidity(uint,uint)" 100ether 100ether \
  --from $ALICE --unlocked

# 2. bob 用 10 tokenA 换 tokenB（最少收 9）
cast send $AMM "swap(address,uint,uint)" $TOKEN_A 10ether 9ether \
  --from $BOB --unlocked

# 3. 查看当前价格
cast call $AMM "spotPrice()(uint)"

# 4. alice 取回流动性
cast send $AMM "removeLiquidity(uint)" 100ether \
  --from $ALICE --unlocked
```

---

### AMM 进阶思考：配合杠杆的玩法

> 以下是协议设计的延伸方向，代码尚未实现，供讨论。

| 模式 | 机制 | 类比 |
|------|------|------|
| LP 杠杆 | 存 LP 贷出 LP，放大做市收益 | 房贷炒房 |
| Pair 币杠杆 | 存 LP 贷出 tokenA 或 B，做多/做空某一侧 | 股票质押借款 |
| 单 token 杠杆 | 存 tokenA，按价格贷出 70% tokenB | 保证金交易 |

---

## 模块 0.2 · 流动性协议（银行）

> 文件：`0.web3_financial_infrastructure/liquidity_protocol/`
> 测试：`test/Bank1.t.sol`

流动性协议（Lending Protocol）是 DeFi 的另一个基础设施。
用户可以存入资产赚取利息，也可以超额抵押借出资产。
Compound、Aave 都属于这一类。

本模块分三个递进版本：

```
bank0.sol  →  bank1.sol  →  bank.sol
 ETH 存取     + ERC20       + 利息计算
                             + 清算机制
```

---

### Bank0：最简版（仅 ETH）

> 文件：`liquidity_protocol/bank0.sol`

**功能：**
- `depositEth()`：存入 ETH，内部记账
- `withdrawEth(uint amount)`：取出 ETH

**代码走读：**

```solidity
// 存入
function depositEth() public payable {
    _balance[msg.sender] += msg.value;   // msg.value = 用户发送的 ETH 数量
}

// 取出
function withdrawEth(uint _amount) public payable {
    address payable user = payable(msg.sender);
    user.transfer(_amount);              // 从合约发 ETH 给用户
    _balance[msg.sender] -= msg.value;  // ⚠️ Bug：应为 -= _amount
}
```

> **学习任务**：`withdrawEth` 中有一个 bug。
> `msg.value` 在非 payable 调用时永远是 0，导致余额不会减少。
> 找到它并修复——这是你的第一个 Solidity debug 练习。

---

### Bank1：ERC20 版

> 文件：`liquidity_protocol/bank1.sol`
> 测试：`forge test --match-path test/Bank1.t.sol -vv`

在 bank0 基础上增加了 ERC20 代币的存取。

**ERC20 转账的两步流程（重要！）**

与 ETH 直接发送不同，ERC20 合约不会主动扣你的钱。必须先 `approve`（授权），
再由目标合约调用 `transferFrom`：

```
用户                    ERC20 合约              Bank1 合约
  │                        │                       │
  ├─ approve(bank1, 100) ──►│                       │
  │    "允许 bank1 从我这里取 100 个代币"          │
  │                        │                       │
  ├─ depositErc20(token, 100) ────────────────────►│
  │                        │                       │
  │                        │◄─ transferFrom(用户, bank1, 100)
  │                        │   "bank1 来取走 100 个代币"
  │                        │──────────────────────►│
  │                        │    转账成功，bank1 记账 │
```

**代码走读（`bank1.sol`）：**

```solidity
// Step 1：授权（在合约外，用户自己调用）
token.approve(address(bank), amount);

// Step 2：存入
function depositErc20(address _erc20, uint _amount) public {
    address user = msg.sender;
    IERC20 erc20 = IERC20(_erc20);

    erc20.transferFrom(user, address(this), _amount);   // 从用户拉取代币
    _erc20Balance[user][_erc20] += _amount;              // 内部记账
}

// Step 3：取出
function withdrawErc20(address _erc20, uint _amount) public {
    address user = msg.sender;
    require(_erc20Balance[user][_erc20] >= _amount, "???"); // 余额检查

    IERC20 erc20 = IERC20(_erc20);
    erc20.transfer(user, _amount);           // 合约发代币给用户
    _erc20Balance[user][_erc20] -= _amount;  // 更新账本
}
```

**数据结构设计：**

```solidity
// 用双重 mapping 隔离不同用户、不同代币的余额
mapping(address => mapping(address => uint)) _erc20Balance;
//               用户地址          代币地址     余额

// 查询：alice 存了多少 USDC
uint balance = _erc20Balance[alice][USDC_ADDRESS];
```

**运行测试验证：**

```bash
forge test --match-path test/Bank1.t.sol -vv
```

测试覆盖了以下场景：

| 测试 | 场景 |
|------|------|
| `test_depositErc20_contractReceivesTokens` | 存入后合约余额增加 |
| `test_depositErc20_accumulates` | 多次存入累加正确 |
| `test_withdrawErc20_returnsTokens` | 取出后代币完整归还 |
| `test_withdrawErc20_revert_insufficient` | 超额取出触发 revert |
| `test_erc20_independentAccounts` | 两个用户账本互不影响 |

---

### Bank（完整借贷协议）

> 文件：`liquidity_protocol/bank.sol`（进行中）

这是完整版的借贷协议，核心挑战是**利息计算**。

#### 为什么利息计算很难？

每次存款、借款、还款都会改变全局利率。
如果直接记录"用户存了 X，过了 T 秒，利率是 R"，
当利率中途变化时，你没法知道每段时间的利率是多少。

**解决方案：时间段分账（微积分离散化）**

```
时间轴：
t0 ──────── t1 ──────── t2 ──────── t3
   利率 r0       利率 r1       利率 r2

每次有人存款/借款时，记录一个"快照"（ProfitStruct）：
  - starTime：本段开始时间
  - endTime：本段结束时间
  - ratePerSecond：本段利率（每秒）

用户利息 = Σ (用户在该段的负债 × 该段利率 × 该段时长)
```

**数学表达：**

$$P = \sum_{i=0}^{n} p_i, \quad p_i = \text{userDebt}_i \times \text{rate}_i \times \Delta t_i$$

**利率模型（资金利用率驱动）：**

$$\text{rate} = \frac{\text{allBorrowed}}{\text{allBalance}}$$

- 借款越多 → 利率越高（鼓励还款，鼓励更多人存款）
- 借款越少 → 利率越低（鼓励借款，提高资金利用率）

这与 Compound 的"跳跃利率模型"原理相同，只是简化了曲线形状。

**代码走读（`bank.sol:deposit`）：**

```
用户调用 deposit(amount)
    ↓
index++                   → 新建一个时间段
    ↓
transferFrom(用户, 合约)  → 拉取资产
    ↓
记录上一段的结束时间 (profitStructSort[index-1].endTime)
记录本段的开始时间  (profitStructSort[index].starTime)
记录上一段的利率    (由当前资金利用率计算)
    ↓
balance[用户] += amount
AllBalance    += amount
```

每次操作（存、借、还）都会"切断"当前时间段，记录快照，再开启新段。
这样每段的利率和时长都被完整保存，之后可以精确回溯。

**清算机制：**

当用户的"借款 + 利息 > 存款 × 清算线"时，任何人都可以触发清算：

```solidity
// 清算因子 = (借款 + 利息) / 存款
// 超过 80% 即可被清算
function liquidationCondition() public view returns (bool) {
    return liquidationConditionFactor() > 0.8e18;
}
```

**清算因子 > 80%** 的意思是：你的债务已经占到抵押品的 80%，
系统认为你的风险太高，允许第三方用折扣价买走你的抵押品以偿债。

---

## 后续模块路线图

### 1 · 传统金融价格与定价

- FT 定价：订单簿的买卖均衡
- NFT 定价：为何难以估值
- 流动性溢价与折价

### 2 · Web3 金融定价机制

#### 2.1 订单撮合 DEX
基于链上订单簿的 DEX（如 dYdX 早期版本）实现。

#### 2.2 算法定价 DEX（本模块 0.1 已实现）

#### 2.3 Uniswap V2 机制深入

| 特性 | 说明 |
|------|------|
| 恒定乘积 | `x * y = k` |
| 价格预言机 | 累积价格防操纵 |
| 闪电贷 | 同块借还，无需抵押 |
| 协议手续费 | 0.05% 归协议方 |

#### 2.4 Curve 稳定币 AMM

Curve 专为稳定币设计，引入混合曲线：

```
A · n^n · Σx_i  +  D  =  A · n^n · D  +  D^(n+1) / (n^n · Πx_i)
```

在价格接近 1:1 时，曲线比 `x*y=k` 平坦得多，大额稳定币交换的滑点极低。

### 3 · 金融衍生品

基于 AMM 和借贷协议，可以构建：
- **永续合约**：无到期日的杠杆多空
- **期权**：支付权利金，获得买入/卖出权
- **远期**：约定未来价格立刻成交

### 4 · LP 做多策略

LP 提供者天然持有双边资产，面临无常损失（Impermanent Loss）。
如何通过对冲/杠杆策略将 LP 头寸转化为方向性做多？

### 5-7 · Compound 杠杆与 Alpaca 策略

- **Compound 杠杆**：存 A 借 B 再买 A，循环放大 A 的多头敞口
- **组合资产**：多协议组合降低风险
- **Alpaca 模式**：LP + 借贷的杠杆做市策略

### 8-10 · 远期合约

- 传统金融远期定价（无套利定价）：`F = S · e^{rT}`
- 链上远期的实现：预言机 + 结算逻辑

### 11-14 · 期货与 GMX

- 期货 vs 远期的区别（逐日盯市结算）
- GMX 的永续合约机制（GLP 池 + 资金费率）

---

## 视频平台

[Philo 的 B 站频道](https://space.bilibili.com/323920542/channel/collectiondetail?sid=1078973)

---

## 项目贡献者

[![contrib graph](https://contrib.rocks/image?repo=PhiloCwh/Web3-Financial-Engineering-Courses)](https://github.com/PhiloCwh/Web3-Financial-Engineering-Courses/graphs/contributors)

---

## 未完待续……

> 路线图仍在演进中，欢迎 PR 和 Issue。
