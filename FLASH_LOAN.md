# UniswapV4Flash — Code Explanation & Execution Guide

**Source file:** `2.sol`  
**Contract:** `UniswapV4Flash`

---

## Table of Contents

1. [What This Contract Does](#1-what-this-contract-does)
2. [Why V4 Flash Loans Are Free](#2-why-v4-flash-loans-are-free)
3. [Architecture Overview](#3-architecture-overview)
4. [Code Walkthrough — Line by Line](#4-code-walkthrough--line-by-line)
5. [Parameters Reference](#5-parameters-reference)
   - [Hardcoded Parameters](#hardcoded-parameters)
   - [Caller-Supplied Parameters](#caller-supplied-parameters)
6. [Step-by-Step Execution Guide](#6-step-by-step-execution-guide)
7. [How to Add Your Own Flash Loan Logic](#7-how-to-add-your-own-flash-loan-logic)
8. [Worked Example — Borrow 100 WETH, Do Arbitrage, Repay](#8-worked-example--borrow-100-weth-do-arbitrage-repay)
9. [Errors and Troubleshooting](#9-errors-and-troubleshooting)
10. [Limitations and Next Steps](#10-limitations-and-next-steps)

---

## 1. What This Contract Does

`UniswapV4Flash` is a base contract for executing **zero-fee flash loans** on Uniswap V4. It:

1. Borrows any amount of any token (or native ETH) from the V4 PoolManager.
2. Gives you a virtual function `_executeFlashLoanLogic` to put your custom logic in (arbitrage, liquidation, collateral swap, etc.).
3. Repays the exact borrowed amount before the PoolManager callback returns.

Because V4 uses flash accounting, there is **no fee** charged on the borrow itself — you only pay for gas.

---

## 2. Why V4 Flash Loans Are Free

In Uniswap V2/V3, flash loans charge a fee (0.3% / 0.05% depending on the pool). V4 eliminates this by using **flash accounting**:

- `poolManager.take(currency, to, amount)` does NOT actually send tokens — it just increments an internal "debt" counter.
- `poolManager.settle(currency)` does NOT require a fee — it simply zeroes out the debt when the matching token amount arrives.

The PoolManager only verifies at the **end of `unlockCallback`** that all debts are zero. There is no fee computation for the borrow period. Your only costs are:
- **Gas** for the callback execution.
- **LP fees** for any swaps you execute inside the callback.

---

## 3. Architecture Overview

```
Caller
  │
  │ 1. flash(currency, amount, customData)
  ▼
UniswapV4Flash
  │
  │ 2. poolManager.unlock(encoded FlashParams)
  ▼
PoolManager
  │
  │ 3. unlockCallback(encoded FlashParams)
  ▼
UniswapV4Flash.unlockCallback
  │
  ├─ 4. poolManager.take(currency, this, amount)
  │      ↳ contract now holds `amount` tokens; debt = +amount
  │
  ├─ 5. _executeFlashLoanLogic(currency, amount, data)
  │      ↳ YOUR custom code goes here
  │
  └─ 6. Repay:
         (ERC-20) token.transfer(poolManager, amount) + poolManager.settle(currency)
         (ETH)    poolManager.settle{value: amount}(currency)
         ↳ debt = 0, unlock succeeds
```

---

## 4. Code Walkthrough — Line by Line

### Constructor (lines 16–18)

```solidity
constructor() {
    poolManager = IPoolManager(POOL_MANAGER);
}
```

No arguments — the PoolManager address is hardcoded from `POOL_MANAGER` constant.

### `flash` function (lines 24–37)

```solidity
function flash(Currency currency, uint256 amount, bytes calldata data) external
```

Entry point for callers. It:
1. Packs `currency`, `amount`, `msg.sender`, and `data` into `FlashParams`.
2. ABI-encodes it and passes to `poolManager.unlock(...)`.

The `data` field is arbitrary bytes you can use to pass instructions to `_executeFlashLoanLogic` — for example, specifying which arbitrage path to take.

### `unlockCallback` (lines 40–78)

Called automatically by the PoolManager. Key steps:

**Line 45** — Security check (must be PoolManager):
```solidity
if (msg.sender != address(poolManager)) revert NotPoolManager();
```

**Line 50** — Borrow tokens (creates debt):
```solidity
poolManager.take(params.currency, address(this), params.amount);
// The contract now has `params.amount` tokens available
// The PoolManager records: debt[this][currency] = +params.amount
```

**Line 58** — Call your custom logic:
```solidity
_executeFlashLoanLogic(params.currency, params.amount, params.data);
```

**Lines 65–74** — Repay:
```solidity
if (!isNative(params.currency)) {
    // ERC-20 path
    IERC20(Currency.unwrap(params.currency)).transfer(address(poolManager), params.amount);
    poolManager.settle(params.currency);
} else {
    // Native ETH path
    poolManager.settle{value: params.amount}(params.currency);
}
```

`transfer` moves tokens to the PoolManager. `settle` tells the PoolManager to credit those tokens against the debt. After this, the debt is zero and `unlock` completes successfully.

### `_executeFlashLoanLogic` (lines 81–88)

```solidity
function _executeFlashLoanLogic(
    Currency currency,
    uint256 amount,
    bytes memory data
) internal virtual {
    // Override in a subcontract
}
```

This is an **empty virtual function** — a hook for you to override in a derived contract. The borrowed tokens (`amount` of `currency`) are held by `address(this)` when this function is called.

### `isNative` helper (lines 90–92)

```solidity
function isNative(Currency currency) internal pure returns (bool) {
    return Currency.unwrap(currency) == address(0);
}
```

Returns `true` if the currency is native ETH (represented as `address(0)`).

---

## 5. Parameters Reference

### Hardcoded Parameters

| Parameter | Value | Location | How to change |
|---|---|---|---|
| `POOL_MANAGER` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Line 5 | Edit constant before compiling |
| Repayment amount | Exactly `params.amount` (borrow == repay) | Lines 66–73 | Do not change — V4 requires exact repayment |

### Caller-Supplied Parameters

#### `Currency currency`

The token to borrow. Use `Currency.wrap(tokenAddress)` for ERC-20s, or `Currency.wrap(address(0))` for native ETH.

| What to borrow | Value |
|---|---|
| WETH | `Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)` |
| USDC | `Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)` |
| Native ETH | `Currency.wrap(address(0))` |
| Any ERC-20 | `Currency.wrap(<token address>)` |

> **Requirement:** The PoolManager must hold enough of this token to lend. If the pool has zero liquidity in that token, `take` will revert.

#### `uint256 amount`

How many tokens (or wei of ETH) to borrow, in the token's smallest unit.

Examples:
- 100 WETH → `100e18` = `100_000_000_000_000_000_000`
- 50,000 USDC → `50000e6` = `50_000_000_000`

#### `bytes calldata data`

Arbitrary bytes forwarded to `_executeFlashLoanLogic`. You define their meaning in your subcontract. Pass `""` (empty bytes) if you don't need custom data.

Example uses:
- Encode a target DEX address and swap path for an arbitrage.
- Encode a liquidation target address.
- Encode a new collateral address for a collateral swap.

---

## 6. Step-by-Step Execution Guide

### Step 1 — Create a subcontract with your logic

`UniswapV4Flash` is a base contract. You must inherit it and override `_executeFlashLoanLogic`:

```solidity
contract MyArbitrageBot is UniswapV4Flash {
    function _executeFlashLoanLogic(
        Currency currency,
        uint256 amount,
        bytes memory data
    ) internal override {
        // Decode your custom instructions
        (address targetDex, bytes memory path) = abi.decode(data, (address, bytes));

        // Approve the DEX and execute the profitable trade
        address token = Currency.unwrap(currency);
        IERC20(token).approve(targetDex, amount);
        // ... call targetDex ...

        // After your trades, this contract must still hold `amount` of `currency`
        // to repay the flash loan.
    }
}
```

### Step 2 — Deploy your subcontract

```bash
forge create MyArbitrageBot.sol:MyArbitrageBot \
  --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
  --private-key $PRIVATE_KEY
```

### Step 3 — Fund the contract if needed

If your logic requires initial capital (e.g. to cover fees), transfer it to the contract before the flash loan:

```bash
cast send $CONTRACT --value 1ether --rpc-url mainnet --private-key $PK
```

### Step 4 — Call `flash`

```javascript
// ethers.js
const flashContract = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);

const currency = WETH_ADDRESS;             // borrow WETH
const amount = ethers.parseEther("100");   // 100 WETH
const customData = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "bytes"],
    [TARGET_DEX, swapPath]
);

const tx = await flashContract.flash(currency, amount, customData);
await tx.wait();
```

```bash
# cast — borrow 100 WETH, empty data
cast send $CONTRACT \
  "flash(address,uint256,bytes)" \
  $WETH 100000000000000000000 0x \
  --rpc-url mainnet --private-key $PK
```

### Step 5 — Verify outcome

Check that:
- The flash loan repayment succeeded (transaction did not revert).
- Your profit was captured (check your wallet or the contract's token balance).

---

## 7. How to Add Your Own Flash Loan Logic

Inside `_executeFlashLoanLogic`, the contract holds `amount` of `currency`. You have **full freedom** to use these tokens. The only constraint: **before the function returns, the contract must still hold exactly `amount` of `currency`** (to repay the loan after the function).

### Common patterns

#### Arbitrage between two DEXes

```solidity
function _executeFlashLoanLogic(Currency currency, uint256 amount, bytes memory data) internal override {
    address token = Currency.unwrap(currency);

    // Swap all borrowed tokens on DEX A (e.g. Uniswap V3)
    uint256 received = swapOnDexA(token, amount);

    // Swap back on DEX B (e.g. Curve) — should return more than `amount`
    uint256 repayToken = swapOnDexB(anotherToken, received);

    // Keep the profit in this contract
    // repayToken >= amount must hold, otherwise the tx reverts
}
```

#### Liquidation

```solidity
function _executeFlashLoanLogic(Currency currency, uint256 amount, bytes memory data) internal override {
    address borrower = abi.decode(data, (address));

    // Repay borrower's debt on Aave/Compound using borrowed tokens
    liquidate(borrower, amount);

    // Receive the collateral (worth more than `amount`)
    // Sell part of collateral to recover `amount` for repayment
}
```

#### Collateral swap

```solidity
function _executeFlashLoanLogic(Currency currency, uint256 amount, bytes memory data) internal override {
    // 1. Use flash-borrowed USDC to repay your USDC debt on a lending protocol
    // 2. Withdraw your WETH collateral
    // 3. Swap WETH → USDC to repay the flash loan
}
```

---

## 8. Worked Example — Borrow 100 WETH, Do Arbitrage, Repay

**Scenario:** WETH is 0.1% cheaper on Curve than on Uniswap V4. You borrow 100 WETH, sell on V4, buy on Curve, keep the spread.

| Step | Action | WETH balance | USDC balance |
|---|---|---|---|
| Start | — | 0 | 0 |
| `take(WETH, this, 100e18)` | Borrow 100 WETH | 100 WETH | 0 |
| Sell 100 WETH on V4 | Get USDC | 0 WETH | 200,000 USDC |
| Buy 100.1 WETH on Curve | Spend USDC | 100.1 WETH | 0 USDC |
| `transfer(poolManager, 100e18)` + `settle` | Repay 100 WETH | 0.1 WETH | 0 USDC |
| **Profit** | **0.1 WETH in contract** | — | — |

---

## 9. Errors and Troubleshooting

| Error | Reason | Fix |
|---|---|---|
| `NotPoolManager` | `unlockCallback` called directly | Never call it manually |
| `FlashLoanFailed` | Defined but not used in repayment path | Check custom logic does not throw |
| `ERC20: transfer amount exceeds balance` | Contract doesn't hold `amount` at repayment time | Ensure `_executeFlashLoanLogic` leaves `amount` of the token in the contract |
| Pool has no liquidity | `take` reverts because the PoolManager holds less than `amount` | Borrow from a pool with sufficient liquidity |
| Transaction runs out of gas | Complex logic inside callback | Increase gas limit; optimize callback logic |

---

## 10. Limitations and Next Steps

- **No automatic profit extraction.** Profits remain in the contract after the callback. Add a withdrawal function to retrieve them.
- **Single token borrow.** The base contract borrows only one token. Override `unlockCallback` directly to borrow multiple tokens in one unlock.
- **Re-entrancy risk.** If `_executeFlashLoanLogic` calls external contracts, ensure those cannot re-enter `flash` or `unlockCallback`.
- **Requires subclassing.** The base contract's `_executeFlashLoanLogic` is a no-op. Without overriding it, the flash loan borrows and immediately repays — which costs only gas.
