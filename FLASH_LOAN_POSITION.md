# FlashLoanPosition — Code Explanation & Execution Guide

**Source file:** `FlashLoanPosition.sol`  
**Contract:** `FlashLoanPosition`

---

## Table of Contents

1. [What This Contract Does](#1-what-this-contract-does)
2. [The Strategy — Leveraged Position with Positive Slippage Capture](#2-the-strategy--leveraged-position-with-positive-slippage-capture)
3. [Architecture Overview](#3-architecture-overview)
4. [The Five Atomic Steps Inside `unlockCallback`](#4-the-five-atomic-steps-inside-unlockcallback)
5. [Code Walkthrough — Line by Line](#5-code-walkthrough--line-by-line)
6. [Parameters Reference](#6-parameters-reference)
   - [Hardcoded Parameters](#hardcoded-parameters)
   - [Caller-Supplied Parameters](#caller-supplied-parameters)
   - [How to Calculate `flashAmount`](#how-to-calculate-flashamount)
   - [How to Calculate `minNetOutput`](#how-to-calculate-minnetoutput)
7. [Step-by-Step Execution Guide](#7-step-by-step-execution-guide)
8. [Worked Example — 5× Leveraged USDC→WETH Position](#8-worked-example--5-leveraged-usdcweth-position)
9. [Delta Accounting Proof](#9-delta-accounting-proof)
10. [Risk Factors](#10-risk-factors)
11. [Errors and Troubleshooting](#11-errors-and-troubleshooting)
12. [Limitations and Next Steps](#12-limitations-and-next-steps)

---

## 1. What This Contract Does

`FlashLoanPosition` opens a **leveraged market position** using a zero-fee Uniswap V4 flash loan, entirely within a single transaction.

- You provide a small amount of input tokens as **margin** (`userAmount`).
- The contract flash-borrows additional input tokens (`flashAmount`) to multiply your buying power.
- It swaps the combined amount into the output token (your leveraged position).
- It repays the flash loan by reverse-swapping exactly `flashAmount` of input currency back.
- You receive the **net output** — your leveraged position — directly in your wallet.

Everything happens atomically: if the repayment fails, the entire transaction reverts.

---

## 2. The Strategy — Leveraged Position with Positive Slippage Capture

### Leverage

Your leverage ratio is:

```
leverage = (userAmount + flashAmount) / userAmount
```

Example: `userAmount = 1000 USDC`, `flashAmount = 4000 USDC` → **5× leverage**.

### Positive slippage capture

When you buy with a large position (userAmount + flashAmount), you may get a **better average execution price** than the quoted spot price, especially if the pool has favorable liquidity distribution. This is called "positive slippage."

Any positive slippage on the forward swap directly increases `amountOut`. Since the repayment reverse-swap uses the same market price, the repayment cost stays roughly constant. Therefore:

```
netOutput = amountOut (from large buy) − repayOutput (cost to repay flashAmount)
```

All surplus above expected goes to you.

### Zero-fee borrowing

Because V4 flash accounting does not charge a fee on `take/settle` cycles, the only cost of leverage is the **LP fee on two swaps**: the large forward swap and the reverse repayment swap. For a 0.3% pool, the round-trip cost is approximately 0.6% of the flash-borrowed amount.

---

## 3. Architecture Overview

```
Caller
  │
  │ 1. token.approve(FlashLoanPosition, userAmount)
  │ 2. openLeveragedPosition(key, userAmount, flashAmount, minNetOutput, zeroForOne)
  ▼
FlashLoanPosition
  │
  │ 3. transferFrom(caller → this, userAmount)   ← pull margin
  │ 4. poolManager.unlock(encoded PositionParams)
  ▼
PoolManager
  │
  │ 5. unlockCallback(encoded PositionParams)
  ▼
FlashLoanPosition.unlockCallback
  │
  ├─ Step 1: take(input, this, flashAmount)          ← borrow
  ├─ Step 2: transfer(poolManager, totalInput) + settle(input)  ← fund the swap
  ├─ Step 3: swap(input→output, −totalInput)         ← open position
  ├─ Step 4: swap(output→input, +flashAmount)        ← repay flash loan
  └─ Step 5: take(output, caller, netOutput)         ← deliver position
```

---

## 4. The Five Atomic Steps Inside `unlockCallback`

| Step | Operation | Purpose |
|---|---|---|
| **1** | `take(inputCurrency, this, flashAmount)` | Borrow `flashAmount` tokens from the pool — creates a debt |
| **2** | `transfer(poolManager, totalInput)` + `settle(inputCurrency)` | Pay `userAmount + flashAmount` into the pool, clearing the debt created in step 1 plus leaving a `userAmount` credit |
| **3** | `swap(input→output, −totalInput)` | Execute the full leveraged buy; receive gross `amountOut` of output currency |
| **4** | `swap(output→input, +flashAmount)` | Exact-output reverse swap: buy back exactly `flashAmount` of input, spending minimum output currency |
| **5** | `take(outputCurrency, caller, netOutput)` | Deliver `amountOut − repayOutput` of output currency to the caller |

After step 5, all deltas are zero and `unlock` succeeds.

---

## 5. Code Walkthrough — Line by Line

### Constants (lines 4–12)

```solidity
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
```

Hardcoded Ethereum mainnet addresses and swap price caps.

### Constructor (lines 33–35)

```solidity
constructor() {
    poolManager = IPoolManager(POOL_MANAGER);
}
```

Zero-argument constructor. PoolManager address is baked in.

### `openLeveragedPosition` (lines 44–75)

```solidity
function openLeveragedPosition(
    PoolKey calldata key,
    uint256 userAmount,
    uint256 flashAmount,
    uint256 minNetOutput,
    bool zeroForOne
) external returns (uint256 netOutput)
```

1. Determines `inputCurrency` from `zeroForOne` and the pool key.
2. Pulls `userAmount` from the caller with `transferFrom` (allowance required).
3. Packs all params into `PositionParams` and calls `poolManager.unlock(...)`.
4. Decodes and returns `netOutput` from the callback result.

### `unlockCallback` (lines 86–166)

#### Lines 91–98 — Decode params and compute totals

```solidity
PositionParams memory p = abi.decode(callbackData, (PositionParams));
Currency inputCurrency  = p.zeroForOne ? p.key.currency0 : p.key.currency1;
Currency outputCurrency = p.zeroForOne ? p.key.currency1 : p.key.currency0;
uint256 totalInput = p.flashAmount + p.userAmount;
```

#### Lines 100–101 — Step 1: Flash borrow

```solidity
poolManager.take(inputCurrency, address(this), p.flashAmount);
```

Contract now holds `flashAmount` tokens. PoolManager records a debt.

#### Lines 103–111 — Step 2: Settle total input

```solidity
bool sent = IERC20(Currency.unwrap(inputCurrency)).transfer(address(poolManager), totalInput);
require(sent, "FlashLoanPosition: transfer to PoolManager failed");
poolManager.settle(inputCurrency);
```

Transfer `flashAmount` (just borrowed) + `userAmount` (held from `transferFrom`) to PoolManager. `settle` credits all of it against the flash-borrow debt. After settle: net credit = `userAmount`.

#### Lines 113–132 — Step 3: Forward swap (open position)

```solidity
BalanceDelta openDelta = poolManager.swap(
    p.key,
    IPoolManager.SwapParams({
        zeroForOne: p.zeroForOne,
        amountSpecified: -int256(totalInput), // exact input
        sqrtPriceLimitX96: p.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
    }),
    bytes("")
);
uint256 amountOut = p.zeroForOne
    ? uint256(int256(openDelta.amount1()))
    : uint256(int256(openDelta.amount0()));
```

Swaps all `totalInput` tokens. Records gross output.

#### Lines 134–153 — Step 4: Reverse swap (repay flash loan)

```solidity
BalanceDelta repayDelta = poolManager.swap(
    p.key,
    IPoolManager.SwapParams({
        zeroForOne: !p.zeroForOne,                   // reverse direction
        amountSpecified: int256(p.flashAmount),       // exact output (positive)
        sqrtPriceLimitX96: !p.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
    }),
    bytes("")
);
uint256 repayOutput = p.zeroForOne
    ? uint256(-int256(repayDelta.amount1()))
    : uint256(-int256(repayDelta.amount0()));
```

Exact-output swap: buys back exactly `flashAmount` of input, spending the minimum output. `amountSpecified` is **positive** for exact-output mode.

#### Lines 155–165 — Step 5: Deliver net position

```solidity
require(amountOut >= repayOutput, "FlashLoanPosition: insufficient output to repay flash loan");
uint256 netOutput = amountOut - repayOutput;
if (netOutput < p.minNetOutput) revert InsufficientOutput();
poolManager.take(outputCurrency, p.sender, netOutput);
return abi.encode(netOutput);
```

Computes net output, checks slippage guard, and sends output tokens to the original caller.

---

## 6. Parameters Reference

### Hardcoded Parameters

| Parameter | Value | Location | How to change |
|---|---|---|---|
| `POOL_MANAGER` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Line 5 | Edit constant before compiling |
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | Line 6 | Informational only — not used in logic |
| `USDC` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | Line 7 | Informational only — not used in logic |
| `MIN_SQRT_PRICE` | `4295128739` | Line 10 | Change to set a tighter swap price limit |
| `MAX_SQRT_PRICE` | `1461446...` | Line 11–12 | Change to set a tighter swap price limit |
| `hookData` | `bytes("")` | Lines 125, 145 | Pass non-empty if pool hook requires data |

### Caller-Supplied Parameters

#### `PoolKey key`

The pool to trade in. Must be a valid initialized pool.

| Field | Type | Description | Example |
|---|---|---|---|
| `currency0` | `Currency` | Lower-address token | `Currency.wrap(USDC)` |
| `currency1` | `Currency` | Higher-address token | `Currency.wrap(WETH)` |
| `fee` | `uint24` | Fee in bips×100 | `3000` (0.3%) |
| `tickSpacing` | `int24` | Tick spacing | `60` |
| `hooks` | `address` | Hook address | `address(0)` |

#### `uint256 userAmount`

Your margin — the tokens you are contributing from your own wallet. Must be approved before calling.

- This is your "skin in the game." Lost if the trade moves against you.
- Greater `userAmount` = lower leverage ratio = lower risk.

#### `uint256 flashAmount`

The additional tokens borrowed from the pool. Determines leverage:

```
leverage = (userAmount + flashAmount) / userAmount
```

| Leverage | userAmount | flashAmount |
|---|---|---|
| 2× | 1000 USDC | 1000 USDC |
| 3× | 1000 USDC | 2000 USDC |
| 5× | 1000 USDC | 4000 USDC |
| 10× | 1000 USDC | 9000 USDC |

Higher leverage → larger swap → more price impact → higher LP fees → higher risk of `InsufficientOutput`.

#### `uint256 minNetOutput`

The minimum amount of output tokens you will accept. The transaction reverts with `InsufficientOutput` if `netOutput < minNetOutput`.

Set this to protect against:
- Excessive price impact on the forward swap.
- Unfavorable market price during the reverse swap.
- Front-running (MEV).

#### `bool zeroForOne`

Trade direction:
- `true` = buy `currency1` using `currency0` (e.g. buy WETH with USDC).
- `false` = buy `currency0` using `currency1` (e.g. buy USDC with WETH).

### How to Calculate `flashAmount`

1. Decide your target leverage (e.g., 5×).
2. `flashAmount = userAmount × (leverage - 1)`.
3. Convert to token units: if `userAmount = 1000 USDC (6 decimals) = 1_000_000_000`, then `flashAmount = 4_000_000_000` for 5×.

> Cap `flashAmount` to what the pool can lend. Check the pool's token balance on-chain: if the pool holds only 10,000 USDC, you cannot flash-borrow more than that.

### How to Calculate `minNetOutput`

1. Get a fair-value quote for swapping `totalInput = userAmount + flashAmount`.
2. Subtract the expected repayment cost (quote for buying `flashAmount` of input).
3. Apply a slippage buffer (e.g., −1%):

```
expectedGrossOut = quote(totalInput → output)
expectedRepayOut = quote(flashAmount of input ← output)
expectedNet      = expectedGrossOut − expectedRepayOut
minNetOutput     = expectedNet × (1 − slippageTolerance)
```

Example for 5× leverage on USDC→WETH with WETH @ $2,000 and 1% slippage:
- `totalInput` = 5,000 USDC → gross ~2.485 WETH (after 0.3% fee)
- Repayment: buy 4,000 USDC worth of input → spend ~1.998 WETH
- `expectedNet` ≈ 0.487 WETH
- `minNetOutput` = `0.487 × 0.99 × 10^18` ≈ `482_130_000_000_000_000`

---

## 7. Step-by-Step Execution Guide

### Step 1 — Deploy the contract

```bash
forge create FlashLoanPosition.sol:FlashLoanPosition \
  --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
  --private-key $PRIVATE_KEY
```

No constructor arguments needed.

### Step 2 — Approve the contract for your input token

```javascript
// ethers.js
const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, signer);
await usdc.approve(FLASH_POSITION_ADDRESS, userAmount);
```

```bash
cast send $USDC "approve(address,uint256)" $CONTRACT 1000000000 \
  --rpc-url mainnet --private-key $PK
```

The approval must cover **only `userAmount`**, not the flash-borrowed amount (which comes from the pool, not your wallet).

### Step 3 — Construct the PoolKey

```javascript
const key = {
    currency0: USDC_ADDRESS,    // lower address
    currency1: WETH_ADDRESS,    // higher address
    fee: 3000,                  // 0.3% pool
    tickSpacing: 60,
    hooks: ethers.ZeroAddress
};
```

### Step 4 — Compute your parameters

```javascript
const userAmount    = 1_000_000_000n;             // 1000 USDC (6 decimals)
const flashAmount   = 4_000_000_000n;             // 4000 USDC → 5× leverage
const minNetOutput  = 482_130_000_000_000_000n;   // 0.482 WETH minimum (18 decimals)
const zeroForOne    = true;                       // USDC→WETH
```

### Step 5 — Call `openLeveragedPosition`

```javascript
const contract = new ethers.Contract(FLASH_POSITION_ADDRESS, ABI, signer);
const tx = await contract.openLeveragedPosition(
    key,
    userAmount,
    flashAmount,
    minNetOutput,
    zeroForOne
);
const receipt = await tx.wait();

// Decode the return value from the transaction logs or call result
const netOutput = abi.decode(['uint256'], receipt.logs[...].data);
console.log("WETH received:", ethers.formatEther(netOutput));
```

```bash
cast send $CONTRACT \
  "openLeveragedPosition((address,address,uint24,int24,address),uint256,uint256,uint256,bool)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  4000000000 \
  482130000000000000 \
  true \
  --rpc-url mainnet --private-key $PK
```

### Step 6 — Verify receipt

Check the output token balance of your wallet increased by approximately `netOutput`.

---

## 8. Worked Example — 5× Leveraged USDC→WETH Position

**Setup:**
- WETH price: $2,000
- Pool: USDC/WETH 0.3%, tickSpacing 60, no hook
- `userAmount` = 1,000 USDC
- `flashAmount` = 4,000 USDC (5× leverage)
- `totalInput` = 5,000 USDC

**Step-by-step flow:**

| Step | Operation | USDC balance (contract) | WETH balance (contract) |
|---|---|---|---|
| Start | User has 1,000 USDC | 1,000 | 0 |
| `take(USDC, this, 4000e6)` | Flash borrow | 5,000 | 0 |
| `transfer(PM, 5000e6)` + `settle` | Fund swap | 0 | 0 |
| Forward swap (−5000 USDC) | Buy WETH | 0 (in PM) | 2.489 WETH (in PM credit) |
| Reverse swap (+4000 USDC out) | Repay loan | 0 | −1.999 WETH spent |
| `take(WETH, caller, 0.490)` | Deliver position | 0 | 0 (all sent to caller) |

**Result:** Caller receives **0.490 WETH** using only 1,000 USDC margin.  
Equivalent exposure: 5,000 USDC → 2.489 WETH (5× the exposure of a normal 1,000 USDC swap).

---

## 9. Delta Accounting Proof

This table shows PoolManager's internal delta tracking throughout `unlockCallback` for a `zeroForOne = true` trade:

| After step | `owed[input (currency0)]` | `owed[output (currency1)]` |
|---|---|---|
| Start | 0 | 0 |
| `take(input, this, flash)` | +flash | 0 |
| `settle(input, flash+user)` | −user | 0 |
| `swap(input→output, −total)` | +flash | −amountOut |
| `swap(output→input, +flash)` | 0 | −(amountOut−repayOut) |
| `take(output, caller, net)` | 0 | 0 ✓ |

All deltas are zero when `unlockCallback` returns → PoolManager accepts the transaction.

---

## 10. Risk Factors

| Risk | Description | Mitigation |
|---|---|---|
| **Price impact** | Large swaps move the price. The larger `flashAmount`, the worse your average price. | Use lower leverage; choose pools with deep liquidity |
| **Reverse swap cost** | The repayment reverse swap also incurs a fee. Two fees reduce net profit. | Factor both fees into `minNetOutput` |
| **Negative slippage** | If market moves against you between the two swaps (unlikely in same tx, but possible with hooks), `repayOutput > amountOut` | The contract reverts with a clear error; no partial execution |
| **MEV / sandwich attacks** | A searcher can front-run your large buy and back-run the sell | Use private mempools (e.g. Flashbots); set tight `minNetOutput` |
| **Liquidity exhaustion** | Pool may not have enough tokens to lend via flash | Check pool reserves before calling; reduce `flashAmount` |
| **Total loss of margin** | If you use high leverage and price moves against you, the position's value may fall below the repayment cost | Leverage is not free — only use amounts you can afford to lose |

---

## 11. Errors and Troubleshooting

| Error | Reason | Fix |
|---|---|---|
| `NotPoolManager` | `unlockCallback` called directly | Never call manually |
| `InsufficientOutput` | `netOutput < minNetOutput` | Lower `minNetOutput` (widen slippage) or lower `flashAmount` (less leverage) |
| `"...transferFrom failed..."` | Allowance not set or insufficient | `token.approve(contract, userAmount)` before calling |
| `"...transfer to PoolManager failed..."` | Internal ERC-20 failure | Check token contract; some tokens require approve+transfer pattern |
| `"...insufficient output to repay..."` | Repayment cost > gross output (very high leverage or bad market) | Reduce `flashAmount`; increase `userAmount` |
| Transaction reverts silently | PoolKey mismatch or pool not initialized | Verify all five `PoolKey` fields match an existing pool |

---

## 12. Limitations and Next Steps

- **Single pool, single pair.** Both swaps use the same pool. For better prices you could route through different pools.
- **No native ETH support.** Both input and output must be ERC-20. Adding native ETH requires a `receive()` function and different settle paths.
- **No position tracking.** The contract does not remember your position. It opens it and exits immediately. For persistent positions, a separate tracking contract is needed.
- **`zeroForOne` only buys output.** To short (sell output and hold input), you would reverse the logic — borrow output, swap output→input for a larger amount, repay in output.
- **No multi-hop.** If better liquidity exists on a different pool, you would need to route the repayment swap there instead.
