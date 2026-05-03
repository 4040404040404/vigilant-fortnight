# Shared Concepts — Uniswap V4 Fundamentals

This document explains the types, interfaces, and patterns that are shared across **all four contracts** in this repository. Read this first before diving into any individual contract guide.

---

## Table of Contents

1. [How Uniswap V4 Works (High Level)](#1-how-uniswap-v4-works-high-level)
2. [The Unlock / unlockCallback Pattern](#2-the-unlock--unlockcallback-pattern)
3. [Global Constants](#3-global-constants)
4. [The `PoolKey` Struct](#4-the-poolkey-struct)
5. [The `Currency` Type](#5-the-currency-type)
6. [The `BalanceDelta` Type](#6-the-balancedelta-type)
7. [Flash Accounting — Why V4 Flash Loans Are Free](#7-flash-accounting--why-v4-flash-loans-are-free)
8. [Sqrt Price and Ticks](#8-sqrt-price-and-ticks)
9. [Common Errors](#9-common-errors)
10. [Tooling Prerequisites](#10-tooling-prerequisites)

---

## 1. How Uniswap V4 Works (High Level)

Uniswap V4 uses a **singleton architecture**: instead of deploying a separate pool contract for every pair (as V2/V3 did), V4 stores ALL pools inside one contract called the **PoolManager**.

```
Your Contract ──calls──▶ PoolManager.unlock(data)
                              │
                              └──calls──▶ Your Contract.unlockCallback(data)
                                              │
                                        (do swaps / flash loans / etc.)
                                              │
                                        return to PoolManager
                                   (PoolManager checks all deltas = 0)
```

Key difference from V2/V3:
- You **never** interact with an individual pool contract.
- Every operation (swap, flash loan, add liquidity) happens **inside** the callback.
- The PoolManager enforces that your token debts are fully settled **before** the callback returns.

---

## 2. The Unlock / unlockCallback Pattern

### `poolManager.unlock(data)`

Calling `unlock` does three things:
1. Puts the PoolManager into "unlocked" mode (only one unlock can be active at a time).
2. Immediately calls `unlockCallback(data)` **back on your contract**.
3. After the callback returns, verifies that every currency delta is zero — i.e., you paid everything you owe and collected nothing extra.

### `unlockCallback(bytes calldata data)`

This is where **all real logic lives**. You implement this function in your contract. Inside it you can:
- Call `poolManager.swap(...)` to execute swaps.
- Call `poolManager.take(currency, to, amount)` to borrow tokens (creates a debt).
- Call `poolManager.settle(currency)` to repay a debt (tokens must already be in the PoolManager).

### Security guard — always validate the caller

```solidity
function unlockCallback(bytes calldata data) external override returns (bytes memory) {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    // ...
}
```

Without this check, anyone could call `unlockCallback` directly and manipulate your contract.

---

## 3. Global Constants

These are hardcoded at the top of every contract:

| Constant | Value | Meaning |
|---|---|---|
| `POOL_MANAGER` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Uniswap V4 PoolManager on **Ethereum mainnet** |
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | Wrapped Ether ERC-20 |
| `USDC` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDC stablecoin ERC-20 |
| `MIN_SQRT_PRICE` | `4295128739` | Minimum valid sqrtPriceX96 (used as price limit for zeroForOne swaps) |
| `MAX_SQRT_PRICE` | `1461446703485210103287273052203988822378723970342` | Maximum valid sqrtPriceX96 (used as price limit for oneForZero swaps) |

> **Network:** All contracts target **Ethereum mainnet**. To deploy on a testnet, change `POOL_MANAGER` to the appropriate address.

---

## 4. The `PoolKey` Struct

Every pool in V4 is uniquely identified by its `PoolKey`:

```solidity
struct PoolKey {
    Currency currency0;   // Lower address token
    Currency currency1;   // Higher address token
    uint24   fee;         // LP fee in hundredths of a bip (e.g. 3000 = 0.3%)
    int24    tickSpacing; // Tick granularity (e.g. 60 for 0.3% pools)
    address  hooks;       // Hook contract address (address(0) = no hook)
}
```

### Rules for `currency0` and `currency1`
- `currency0` MUST have a **lower** address value than `currency1`.
- If you swap WETH/USDC: USDC (`0xA0b8...`) < WETH (`0xC02a...`) → `currency0 = USDC`, `currency1 = WETH`.
- You can verify ordering: `uint160(address(token0)) < uint160(address(token1))`.

### Common fee tiers and tick spacings

| Fee (uint24) | Fee % | tickSpacing |
|---|---|---|
| `100` | 0.01% | `1` |
| `500` | 0.05% | `10` |
| `3000` | 0.30% | `60` |
| `10000` | 1.00% | `200` |

### Example PoolKey (USDC/WETH 0.3% pool)

```solidity
PoolKey memory key = PoolKey({
    currency0: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
    currency1: Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH
    fee: 3000,
    tickSpacing: 60,
    hooks: address(0)
});
```

### How to get the PoolKey for a real pool

You can look up existing V4 pools on [Uniswap V4 Explorer](https://app.uniswap.org) or read the pool initialization event logs from the PoolManager. The `PoolKey` struct is ABI-encoded inside the `Initialize` event.

---

## 5. The `Currency` Type

```solidity
type Currency is address;
```

`Currency` is a thin type alias over `address`. It exists to make the code more readable and type-safe. Unwrap it to get the raw address:

```solidity
address tokenAddr = Currency.unwrap(myCurrency);
// or via the library helper:
address tokenAddr = myCurrency.unwrap();
```

### Native ETH

Native ETH is represented as `Currency.wrap(address(0))`:

```solidity
Currency nativeETH = Currency.wrap(address(0));
bool isEth = Currency.unwrap(nativeETH) == address(0); // true
```

---

## 6. The `BalanceDelta` Type

```solidity
type BalanceDelta is int256;
```

`BalanceDelta` is returned by `poolManager.swap(...)` and `poolManager.modifyLiquidity(...)`. It packs two `int128` values into a single `int256`:

| Bits | Meaning |
|---|---|
| Upper 128 bits | `amount0` — change in `currency0` |
| Lower 128 bits | `amount1` — change in `currency1` |

### Sign convention

- **Negative** = you owe the pool this amount (you must pay/settle it).
- **Positive** = the pool owes you this amount (you can take it).

### Extracting amounts

```solidity
int128 amt0 = delta.amount0(); // from BalanceDeltaLibrary
int128 amt1 = delta.amount1();

// When zeroForOne = true (currency0 → currency1):
//   delta.amount0() is negative  (you paid currency0)
//   delta.amount1() is positive  (you receive currency1)
uint256 received = uint256(int256(delta.amount1()));
```

---

## 7. Flash Accounting — Why V4 Flash Loans Are Free

In V4, the PoolManager tracks every token credit and debt as an in-memory "delta" during the unlock session. No tokens actually move until `settle` or `take` is called. This means:

1. You can call `take(token, this, 1000)` to "borrow" 1000 tokens — the PoolManager just increments your debt.
2. Use those tokens for anything.
3. Transfer 1000 tokens **back** to the PoolManager, then call `settle(token)` to clear the debt.

Because V4 never charges a fee for this borrow/repay cycle (unlike Aave, which charges 0.09%), the flash loan itself is **free**. You only pay for gas and the swap fees of any trades you execute inside the callback.

---

## 8. Sqrt Price and Ticks

Uniswap V3/V4 represent prices as `sqrtPriceX96` — the square root of the price, scaled by `2^96`:

```
sqrtPriceX96 = sqrt(price) × 2^96
price = (sqrtPriceX96 / 2^96)^2
```

### Swap price limits

When calling `poolManager.swap(...)` you must provide `sqrtPriceLimitX96` to cap how far the price can move. The contracts use the extreme safe limits:

```solidity
// Swap currency0 → currency1 (price goes DOWN):
sqrtPriceLimitX96 = MIN_SQRT_PRICE + 1   // allow price to fall as far as possible

// Swap currency1 → currency0 (price goes UP):
sqrtPriceLimitX96 = MAX_SQRT_PRICE - 1   // allow price to rise as far as possible
```

Using the min/max limits means "fill as much as possible at any price" — equivalent to setting no price limit. If you want to protect against excessive price impact, use a tighter limit.

### Ticks

A **tick** is a discrete price point. Tick `i` corresponds to price `1.0001^i`. The current tick is readable from `poolManager.getSlot0(poolId)`. Positive ticks = higher price.

---

## 9. Common Errors

| Error | Cause | Fix |
|---|---|---|
| `NotPoolManager` | `unlockCallback` called by someone other than the PoolManager | Do not call `unlockCallback` directly |
| `SwapFailed` | Output from swap is below `minAmountOut` | Increase slippage tolerance or reduce `minAmountOut` |
| `FlashLoanFailed` | Flash loan repayment failed | Ensure contract has enough tokens to repay |
| `InsufficientOutput` | Net output from `FlashLoanPosition` below `minNetOutput` | Reduce `minNetOutput` or adjust leverage |
| `InvalidTick` | Limit order tick is on wrong side of current price | Check current tick before placing; ensure tick > current for zeroForOne |
| ERC-20 `transferFrom` reverts | Missing token approval | Call `token.approve(contractAddress, amount)` before calling the function |

---

## 10. Tooling Prerequisites

### Deploying contracts

These contracts target **Solidity ^0.8.26**. Use one of:

- **Foundry** (recommended): `forge create` / `forge script`
- **Hardhat**: `npx hardhat deploy`
- **Remix IDE**: paste the `.sol` file and compile with optimizer enabled

### Interacting on-chain

- **Cast** (Foundry CLI): `cast send <contract> "functionName(args)" --rpc-url mainnet --private-key $PK`
- **Etherscan**: verify the contract, then use the "Write Contract" tab
- **ethers.js / viem / web3.js**: standard JS libraries

### Pre-flight checklist before every call

1. Contract is deployed and verified.
2. You have approved the contract to spend your input token (`token.approve(contract, amount)`).
3. You have a valid `PoolKey` for the pool you want to use.
4. You know the current tick (query `poolManager.getSlot0(poolId)`).
5. You are on **Ethereum mainnet** (chain ID `1`) — or have updated `POOL_MANAGER` for your network.
