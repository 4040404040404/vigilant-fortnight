# UniswapV4Swap — Code Explanation & Execution Guide

**Source file:** `1.sol`  
**Contract:** `UniswapV4Swap`

---

## Table of Contents

1. [What This Contract Does](#1-what-this-contract-does)
2. [Architecture Overview](#2-architecture-overview)
3. [Code Walkthrough — Line by Line](#3-code-walkthrough--line-by-line)
4. [Parameters Reference](#4-parameters-reference)
   - [Hardcoded Parameters](#hardcoded-parameters)
   - [Caller-Supplied Parameters](#caller-supplied-parameters)
5. [Step-by-Step Execution Guide](#5-step-by-step-execution-guide)
6. [Worked Example — Swap 1000 USDC for WETH](#6-worked-example--swap-1000-usdc-for-weth)
7. [Errors and Troubleshooting](#7-errors-and-troubleshooting)
8. [Limitations and Next Steps](#8-limitations-and-next-steps)

---

## 1. What This Contract Does

`UniswapV4Swap` lets you execute a **single exact-input swap** on any Uniswap V4 pool by calling the PoolManager directly (no Router involved). You specify:

- Which pool to swap in (`PoolKey`).
- How many input tokens to sell (`amountIn`).
- The minimum output you will accept (`minAmountOut`).

The trade direction is hardcoded to `zeroForOne = true` (always swaps `currency0 → currency1`). Output tokens are sent directly to the caller.

---

## 2. Architecture Overview

```
Caller
  │
  │ 1. approve(contract, amountIn)
  │ 2. swapExactInput(key, amountIn, minAmountOut)
  ▼
UniswapV4Swap
  │
  │ 3. poolManager.unlock(encoded data)
  ▼
PoolManager
  │
  │ 4. unlockCallback(encoded data)  ← calls back into UniswapV4Swap
  ▼
UniswapV4Swap.unlockCallback
  │
  ├─ 5. poolManager.swap(key, swapParams, "")   → BalanceDelta
  ├─ 6. check amountOut >= minAmountOut
  ├─ 7. IERC20(inputToken).transferFrom(caller → PoolManager, amountIn)
  ├─ 8. poolManager.settle(inputCurrency)         → clears input debt
  └─ 9. poolManager.take(outputCurrency, caller, amountOut) → sends output to caller
```

---

## 3. Code Walkthrough — Line by Line

### Constants (lines 5–7)

```solidity
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
```

Hard-coded Ethereum mainnet addresses. The contract will only work on mainnet unless these are changed.

### Constructor (lines 17–19)

```solidity
constructor() {
    poolManager = IPoolManager(POOL_MANAGER);
}
```

Sets the immutable `poolManager` reference at deployment. No arguments needed — the address is baked in.

### `swapExactInput` (lines 25–44)

```solidity
function swapExactInput(
    PoolKey calldata key,
    uint128 amountIn,
    uint128 minAmountOut
) external returns (uint256 amountOut)
```

This is the **only function callers need to call**. It:
1. Packs all parameters into a `SwapParams` struct and ABI-encodes it.
2. Calls `poolManager.unlock(data)` — this triggers `unlockCallback`.
3. Decodes the returned `amountOut` from the callback result.

> **Note:** `zeroForOne` is hardcoded to `true` inside `SwapParams`. This means the contract always swaps `currency0 → currency1`. If you need the reverse direction, you would need to modify the contract or pass `zeroForOne` as a parameter.

### `unlockCallback` (lines 48–101)

```solidity
function unlockCallback(bytes calldata data) external override returns (bytes memory)
```

Called automatically by the PoolManager during `unlock`. This is where the swap actually executes:

**Line 53** — Security check: only the PoolManager may call this.

**Lines 60–70** — Execute the swap:
```solidity
BalanceDelta delta = poolManager.swap(
    params.key,
    IPoolManager.SwapParams({
        zeroForOne: params.zeroForOne,
        amountSpecified: -int256(uint256(params.amountIn)), // negative = exact input
        sqrtPriceLimitX96: MIN_SQRT_PRICE + 1              // no price cap
    }),
    bytes("")  // no hook data
);
```
`amountSpecified` is **negative** for exact-input swaps. A positive value means exact-output.

**Lines 75–77** — Extract output amount from delta:
```solidity
uint256 amountOut = params.zeroForOne
    ? uint256(int256(delta.amount1()))  // currency0→currency1: amount1 is positive (received)
    : uint256(int256(delta.amount0())); // currency1→currency0: amount0 is positive
```

**Line 79** — Slippage check: revert if output is too low.

**Lines 86–91** — Pay the input token debt:
```solidity
IERC20(Currency.unwrap(inputCurrency)).transferFrom(
    params.sender,          // pull from the original caller
    address(poolManager),   // send to the PoolManager
    params.amountIn
);
poolManager.settle(inputCurrency); // tell PoolManager the debt is paid
```

**Line 98** — Collect output tokens and send to caller:
```solidity
poolManager.take(outputCurrency, params.sender, amountOut);
```

---

## 4. Parameters Reference

### Hardcoded Parameters

| Parameter | Value | Where set | How to change |
|---|---|---|---|
| `POOL_MANAGER` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Top of file, line 5 | Change the constant before compiling |
| `zeroForOne` | `true` | Inside `swapExactInput`, line 36 | Change to `false` or pass as argument to support both directions |
| `sqrtPriceLimitX96` | `MIN_SQRT_PRICE + 1` | Inside `unlockCallback`, line 66 | Set a specific value to limit price impact |
| `hookData` | `bytes("")` (empty) | Inside `unlockCallback`, line 69 | Pass non-empty bytes if the pool has a hook that requires data |

### Caller-Supplied Parameters

#### `PoolKey key`

The pool to swap in. All five fields must match a real deployed pool exactly.

| Field | Type | Description | Example (USDC/WETH 0.3%) |
|---|---|---|---|
| `currency0` | `Currency` | Lower-address token | `Currency.wrap(USDC)` = `0xA0b8...` |
| `currency1` | `Currency` | Higher-address token | `Currency.wrap(WETH)` = `0xC02a...` |
| `fee` | `uint24` | LP fee in bips×100 | `3000` (0.3%) |
| `tickSpacing` | `int24` | Tick granularity | `60` |
| `hooks` | `address` | Hook contract | `address(0)` (no hook) |

> **Important:** `currency0` must have a lower address than `currency1`. Swap them if necessary.

#### `uint128 amountIn`

Amount of `currency0` tokens to sell (if `zeroForOne = true`), in the token's smallest unit (wei for 18-decimal tokens, micro-USDC for USDC which has 6 decimals).

Examples:
- 1000 USDC → `1000 × 10^6` = `1_000_000_000`
- 1 WETH → `1 × 10^18` = `1_000_000_000_000_000_000`

#### `uint128 minAmountOut`

Minimum acceptable output. The transaction reverts with `SwapFailed` if the actual output is below this.

How to calculate:
1. Get a current price quote off-chain (e.g., from Uniswap SDK or a price oracle).
2. Apply your slippage tolerance (e.g., 0.5%) to get the floor: `minAmountOut = quote × (1 - slippage)`.

Example: expecting ~0.5 WETH output, with 1% slippage: `minAmountOut = 0.495 × 10^18`.

---

## 5. Step-by-Step Execution Guide

### Step 1 — Deploy the contract

```bash
# Using Foundry
forge create 1.sol:UniswapV4Swap \
  --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
  --private-key $PRIVATE_KEY
```

The contract takes no constructor arguments.

### Step 2 — Approve the contract to spend your input token

Before calling `swapExactInput`, you must give the contract an ERC-20 allowance for the input token:

```javascript
// ethers.js
const inputToken = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, signer);
await inputToken.approve(SWAP_CONTRACT_ADDRESS, amountIn);
```

```bash
# cast (Foundry)
cast send $USDC "approve(address,uint256)" $SWAP_CONTRACT 1000000000 \
  --rpc-url mainnet --private-key $PK
```

### Step 3 — Build the PoolKey

Find the pool parameters. For the USDC/WETH 0.3% V4 pool:

```solidity
PoolKey memory key = PoolKey({
    currency0: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
    currency1: Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH
    fee: 3000,
    tickSpacing: 60,
    hooks: address(0)
});
```

### Step 4 — Call `swapExactInput`

```javascript
// ethers.js
const swap = new ethers.Contract(SWAP_CONTRACT_ADDRESS, SWAP_ABI, signer);

const key = {
    currency0: USDC_ADDRESS,
    currency1: WETH_ADDRESS,
    fee: 3000,
    tickSpacing: 60,
    hooks: ethers.ZeroAddress
};

const tx = await swap.swapExactInput(
    key,
    1_000_000_000n,   // amountIn: 1000 USDC (6 decimals)
    495_000_000_000_000_000n  // minAmountOut: 0.495 WETH (18 decimals)
);
const receipt = await tx.wait();
```

```bash
# cast — ABI-encode the PoolKey tuple inline
cast send $SWAP_CONTRACT \
  "swapExactInput((address,address,uint24,int24,address),uint128,uint128)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  495000000000000000 \
  --rpc-url mainnet --private-key $PK
```

### Step 5 — Check the output

The function returns `amountOut` — the actual number of `currency1` tokens received. Monitor the `Transfer` event on the output token to confirm receipt.

---

## 6. Worked Example — Swap 1000 USDC for WETH

**Assumptions:**
- WETH price: ~$2,000 → 1000 USDC ≈ 0.5 WETH
- Slippage tolerance: 1%

| Parameter | Value |
|---|---|
| `key.currency0` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| `key.currency1` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (WETH) |
| `key.fee` | `3000` |
| `key.tickSpacing` | `60` |
| `key.hooks` | `address(0)` |
| `amountIn` | `1_000_000_000` (1000 × 10^6) |
| `minAmountOut` | `495_000_000_000_000_000` (0.495 × 10^18, i.e. 1% slippage) |

**Expected result:** Caller receives ~0.4985 WETH (after 0.3% LP fee) directly to their wallet.

---

## 7. Errors and Troubleshooting

| Error | Reason | Fix |
|---|---|---|
| `NotPoolManager` | Someone called `unlockCallback` directly | Never call `unlockCallback` manually |
| `SwapFailed` | `amountOut < minAmountOut` | Lower `minAmountOut` or reduce `amountIn` to avoid large price impact |
| `ERC20: insufficient allowance` | Missing or expired approval | Re-run `token.approve(contract, amountIn)` |
| `ERC20: transfer amount exceeds balance` | Wallet has less than `amountIn` | Reduce `amountIn` |
| Transaction reverts with no message | Pool does not exist or `PoolKey` mismatch | Verify all five `PoolKey` fields match an initialized pool |

---

## 8. Limitations and Next Steps

- **Direction is hardcoded** (`zeroForOne = true`). To support `currency1 → currency0`, make `zeroForOne` a parameter.
- **No multi-hop routing.** Each call does exactly one swap. For multi-hop, you would execute multiple swaps inside `unlockCallback`.
- **uint128 cap.** `amountIn` and `minAmountOut` are `uint128`, capping at ~3.4 × 10^38. This is sufficient for all practical token amounts.
- **No native ETH support.** The contract uses `transferFrom` which requires ERC-20 tokens. Native ETH handling would require a different settlement path.
