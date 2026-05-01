# Code Explanation

> Detailed walkthrough of every contract in this repository: `1.sol`, `2.sol`, and `FlashExecutor.sol`.

---

## Table of Contents

1. [Background – Uniswap V4 Architecture](#1-background--uniswap-v4-architecture)
2. [Shared Types and Libraries](#2-shared-types-and-libraries)
3. [1.sol – UniswapV4Swap](#3-1sol--uniswapv4swap)
4. [2.sol – UniswapV4Flash](#4-2sol--uniswapv4flash)
5. [FlashExecutor.sol – The Combined Executor](#5-flashexecutorsol--the-combined-executor)
6. [How the Three Files Relate](#6-how-the-three-files-relate)

---

## 1. Background – Uniswap V4 Architecture

Uniswap V4 uses a **singleton PoolManager** contract. Unlike V2/V3 where each pool is a separate contract, V4 holds **all pools and all balances** inside one contract at address:

```
0x000000000004444c5dc75cB358380D2e3dE08A90  (Ethereum mainnet)
```

### The Unlock / Callback Pattern

Because V4 is a singleton, direct state-changing calls are **not allowed** outside of a locked context. The flow is always:

```
Your Contract
    │
    ├─► poolManager.unlock(data)      ← YOU start the session
    │
PoolManager calls back:
    │
    └─► yourContract.unlockCallback(data)  ← ALL swaps / borrows happen here
            │
            ├─ poolManager.swap(...)
            ├─ poolManager.take(...)   ← receive tokens
            └─ poolManager.settle(...) ← pay tokens back
```

`unlock` does not return until `unlockCallback` finishes **and all debts are zero**. If you take tokens but don't settle the matching debt, the entire transaction reverts.

### Flash Accounting

Instead of moving tokens on every sub-operation, V4 tracks a **running delta** (balance owed). This makes flash loans **completely free** — no fee, no premium — because you simply borrow, use, and repay within the same callback.

---

## 2. Shared Types and Libraries

These types appear across all three files. They are part of the Uniswap V4 core type system.

### `Currency` (user-defined type)

```solidity
type Currency is address;
```

A thin wrapper around `address`. The special value `address(0)` means **native ETH**, not an ERC-20. Every other address is an ERC-20 token contract.

```solidity
library CurrencyLibrary {
    function unwrap(Currency c) internal pure returns (address) { ... }
    function isNative(Currency c) internal pure returns (bool) { ... }
}
```

- `unwrap` – extracts the underlying `address` so you can call ERC-20 methods.
- `isNative` – returns `true` when the currency is ETH (address = 0x000…000).

### `PoolKey` (struct)

```solidity
struct PoolKey {
    Currency currency0;   // lower-address token  (always token0 < token1 by address)
    Currency currency1;   // higher-address token
    uint24   fee;         // pool fee tier in hundredths of a bip (e.g. 3000 = 0.30%)
    int24    tickSpacing; // tick spacing that matches the fee tier
    address  hooks;       // hook contract address, or address(0) for no hooks
}
```

A `PoolKey` uniquely identifies a pool. The same two tokens can have multiple pools (different fee tiers or hooks).

> **Important:** `currency0` must always be the token with the **lower address value** compared to `currency1`. V4 enforces this ordering.

### `BalanceDelta` (user-defined type)

```solidity
type BalanceDelta is int256;
```

Returned by `poolManager.swap`. It packs two `int128` values into one `int256`:
- **High 128 bits** → `amount0` (token0 delta)
- **Low 128 bits** → `amount1` (token1 delta)

Sign convention:
| Sign | Meaning |
|------|---------|
| Negative | *You owe the pool* this amount |
| Positive | *The pool owes you* this amount |

```solidity
library BalanceDeltaLibrary {
    function amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(d) >> 128));  // high bits
    }
    function amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d));  // low bits
    }
}
```

### Sqrt Price Constants

```solidity
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
```

These represent the minimum and maximum price boundaries for a V4 pool swap. When you pass `MIN_SQRT_PRICE + 1` as the price limit on a `zeroForOne` swap (selling token0 for token1), you are telling the pool: "I don't care how far the price moves — fill me as much as possible." Used when you want unconstrained exact-input swaps.

---

## 3. `1.sol` – UniswapV4Swap

### Purpose

A standalone demonstration of how to perform a **single exact-input swap** directly against the Uniswap V4 PoolManager.

### Hardcoded Constants

```solidity
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant WETH         = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
```

`WETH` and `USDC` are provided as reference; the contract does not enforce using them — any pool can be targeted by the caller.

### `SwapParams` struct (internal)

```solidity
struct SwapParams {
    PoolKey key;          // which pool to swap in
    uint128 amountIn;     // how much of the input token to send
    uint128 minAmountOut; // revert if output is less than this
    bool    zeroForOne;   // true = sell token0, buy token1
    address sender;       // who is paying (for the transferFrom)
}
```

This is an **internal** struct used only to pass data through the `unlock` ↔ `unlockCallback` roundtrip. It is not visible to callers.

### `swapExactInput` function

```solidity
function swapExactInput(
    PoolKey calldata key,
    uint128 amountIn,
    uint128 minAmountOut
) external returns (uint256 amountOut)
```

**What it does:**
1. Bundles the caller's parameters into a `SwapParams` struct.
2. ABI-encodes the struct into `bytes`.
3. Calls `poolManager.unlock(data)` — this immediately triggers `unlockCallback`.
4. Decodes the returned `amountOut` from the callback result.

> The function hardcodes `zeroForOne: true`, meaning it always sells `currency0` for `currency1`. For the reverse direction, you would need to modify the code.

### `unlockCallback` function

This is **called by PoolManager**, never by users directly. It contains the real swap logic:

```
Step 1 – poolManager.swap(key, swapParams, "")
         ↓ returns BalanceDelta
Step 2 – Calculate amountOut from delta
         (amount1 if zeroForOne, else amount0)
Step 3 – Check amountOut >= minAmountOut, else revert SwapFailed()
Step 4 – IERC20.transferFrom(sender → poolManager, amountIn)
          poolManager.settle(inputCurrency)     ← clears the input debt
Step 5 – poolManager.take(outputCurrency, sender, amountOut)
          ← moves output tokens directly to the caller's wallet
```

**Key insight:** The user must have previously approved `UniswapV4Swap` to spend their input tokens (ERC-20 `approve`). The contract pulls funds from the user with `transferFrom` inside the callback.

### Errors

| Error | When |
|-------|------|
| `NotPoolManager()` | `unlockCallback` was called by someone other than PoolManager |
| `SwapFailed()` | Output amount is below `minAmountOut` |

---

## 4. `2.sol` – UniswapV4Flash

### Purpose

A standalone demonstration of a **V4 flash loan** — borrowing tokens from the pool for free, doing something with them, and repaying before the callback ends.

### `flash` function

```solidity
function flash(
    Currency currency,
    uint256  amount,
    bytes calldata data
) external
```

**What it does:**
1. Packages `{currency, amount, msg.sender, data}` into `FlashParams`.
2. ABI-encodes and calls `poolManager.unlock(callbackData)`.

The `data` field is arbitrary bytes you can use to pass instructions to your flash loan logic.

### `unlockCallback` function

```
Step 1 – poolManager.take(currency, address(this), amount)
         ↓ tokens are now in this contract (a debt is created)

Step 2 – _executeFlashLoanLogic(currency, amount, data)
         ↓ do whatever you want with the borrowed tokens

Step 3 – Repay:
         If ERC-20:  IERC20.transfer(poolManager, amount)
                     poolManager.settle(currency)
         If ETH:     poolManager.settle{value: amount}(currency)
```

After repayment the delta is zero, so `unlock` succeeds and the transaction completes.

### `_executeFlashLoanLogic` (virtual hook)

```solidity
function _executeFlashLoanLogic(
    Currency currency,
    uint256 amount,
    bytes memory data
) internal virtual {
    // override this in a subclass
}
```

This is an **override point**. In `2.sol` it does nothing. You are meant to subclass `UniswapV4Flash` and override this function with your arbitrage, liquidation, or other logic.

### Why flash loans are free in V4

In V3, `flashLoan` charged a fee (same as the swap fee). In V4, the flash accounting system just tracks the delta. Since `take` and `settle` perfectly cancel each other out with no surplus required, **no fee is charged**.

### Errors

| Error | When |
|-------|------|
| `NotPoolManager()` | Callback was called by wrong address |
| `FlashLoanFailed()` | Defined but not explicitly thrown in this file (reserved for subclasses) |

---

## 5. `FlashExecutor.sol` – The Combined Executor

### Purpose

`FlashExecutor` merges the flash loan pattern from `2.sol` with the swap execution pattern from `1.sol` into a **single production-ready executor**. It:

1. Flash-borrows tokens.
2. Runs an arbitrary sequence of V4 swaps with those tokens.
3. Repays the loan from the swap proceeds.
4. Sends leftover profit to the caller's chosen address.
5. Reverts the entire transaction if profit falls below a minimum threshold.

### Architecture Overview

```
Caller
  │
  ▼
execute(flashCurrency, flashAmount, steps[], minProfit, recipient)
  │
  ▼
poolManager.unlock(encodedParams)
  │
  ▼ (PoolManager calls back)
unlockCallback(encodedParams)
  │
  ├─ 1. take(flashCurrency → this contract)   [borrow]
  │
  ├─ 2. for each SwapStep:
  │       poolManager.swap(...)
  │       _settleFromContract(inputCurrency)   [pay input]
  │       poolManager.take(outputCurrency)     [receive output]
  │
  ├─ 3. _repay(flashCurrency, flashAmount)     [pay back loan]
  │
  └─ 4. _sweep(flashCurrency, minProfit, recipient)  [send profit]
```

### `ReentrancyGuard`

An inline, dependency-free reentrancy guard is included:

```solidity
abstract contract ReentrancyGuard {
    uint256 private _status = 1;   // 1 = not entered, 2 = entered
    modifier nonReentrant() { ... }
}
```

The `execute` function is marked `nonReentrant`. This prevents a malicious `recipient` contract (receiving ETH profit) from re-entering `execute` mid-execution.

### `SwapStep` struct

```solidity
struct SwapStep {
    PoolKey key;          // which V4 pool
    bool    zeroForOne;   // direction: true = sell currency0, false = sell currency1
    uint128 amountIn;     // exact input amount for this hop
    uint128 minAmountOut; // minimum acceptable output (slippage guard per hop)
}
```

You build an **array** of `SwapStep` to define a multi-hop path. Each hop receives the output of the previous hop as (some of) its input.

### `CallbackParams` struct (internal)

```solidity
struct CallbackParams {
    Currency   flashCurrency;  // token to borrow
    uint256    flashAmount;    // amount to borrow
    SwapStep[] steps;          // ordered swap hops
    uint256    minProfit;      // minimum net profit required
    address    recipient;      // where profit goes
}
```

This struct is ABI-encoded, passed through `poolManager.unlock`, and decoded inside `unlockCallback`. It is never exposed to users directly — you interact only through `execute(...)`.

### `execute` function

```solidity
function execute(
    Currency   flashCurrency,
    uint256    flashAmount,
    SwapStep[] calldata steps,
    uint256    minProfit,
    address    recipient
) external nonReentrant
```

The **sole entry point** for callers. All five parameters are explained in detail in [PARAMETERS.md](./PARAMETERS.md).

### `unlockCallback` function

Called exclusively by PoolManager. Performs four stages:

**Stage 1 – Borrow**
```solidity
poolManager.take(p.flashCurrency, address(this), p.flashAmount);
```
Transfers `flashAmount` tokens to the executor contract. Creates a debt that must be cleared before the callback ends.

**Stage 2 – Swap Loop**
```solidity
for (uint256 i = 0; i < p.steps.length; i++) {
    _executeSwapStep(p.steps[i], i);
}
```
Each step swaps using `poolManager.swap`, then immediately settles the input and takes the output via flash accounting.

**Stage 3 – Repay**
```solidity
_repay(p.flashCurrency, p.flashAmount);
```
Sends exactly `flashAmount` back to PoolManager and calls `settle`. This clears the original borrow debt.

**Stage 4 – Sweep**
```solidity
uint256 profit = _sweep(p.flashCurrency, p.minProfit, p.recipient);
```
Reads the executor's remaining token balance. If it's below `minProfit`, the whole transaction reverts. Otherwise, transfers the balance to `recipient`.

### `_executeSwapStep` internals

```solidity
BalanceDelta delta = poolManager.swap(step.key, IPoolManager.SwapParams({
    zeroForOne:        step.zeroForOne,
    amountSpecified:   -int256(uint256(step.amountIn)),  // negative = exact input
    sqrtPriceLimitX96: step.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
}), bytes(""));
```

- `amountSpecified` is **negative** to signal "exact input" mode.
- `sqrtPriceLimitX96` is set to the extreme (min or max) so there is no price cap — the swap fills the full `amountIn` as long as liquidity allows.

The output amount is extracted safely:
```solidity
int128 rawOut = step.zeroForOne ? delta.amount1() : delta.amount0();
require(rawOut > 0, "FlashExecutor: non-positive swap output");
uint256 amountOut = uint256(int256(rawOut));
```

A positive `rawOut` means the pool owes us tokens. The `require` guard prevents a silent underflow if something goes unexpectedly wrong.

### Custom Errors

| Error | Parameters | Meaning |
|-------|-----------|---------|
| `NotPoolManager()` | — | `unlockCallback` was not called by PoolManager |
| `InsufficientProfit(got, minimum)` | actual, required | Profit after repayment is too low |
| `SwapOutputTooLow(step, got, minimum)` | step index, actual, required | A swap hop produced less than `minAmountOut` |
| `TransferFailed()` | — | An ERC-20 `transfer` or ETH `call` returned false |

---

## 6. How the Three Files Relate

```
1.sol  ──────────────────────────────────────────────────────────┐
  Provides the swap execution pattern:                           │
  unlock → unlockCallback → poolManager.swap → settle/take       │
                                                                 │
2.sol  ──────────────────────────────────────────────────────────┤
  Provides the flash loan pattern:                               ├──► FlashExecutor.sol
  unlock → take (borrow) → logic → settle (repay)               │    Combines both patterns
                                                                 │    into one atomic executor
FlashExecutor.sol  ──────────────────────────────────────────────┘
  = 2.sol's flash borrow/repay
  + 1.sol's swap execution (repeated N times for multi-hop)
  + profit check and sweep
  + reentrancy guard
```

`1.sol` and `2.sol` are teaching examples. `FlashExecutor.sol` is the production contract that makes them useful together.
