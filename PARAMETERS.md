# Parameters Reference

> Every parameter used across `1.sol`, `2.sol`, and `FlashExecutor.sol` — what it is, its type, its constraints, and whether it is hardcoded or caller-supplied.

---

## Table of Contents

1. [Hardcoded Constants (no action needed)](#1-hardcoded-constants-no-action-needed)
2. [FlashExecutor.execute() Parameters](#2-flashexecutorexecute-parameters)
3. [SwapStep Struct Parameters](#3-swapstep-struct-parameters)
4. [PoolKey Struct Parameters](#4-poolkey-struct-parameters)
5. [UniswapV4Swap.swapExactInput() Parameters (1.sol)](#5-uniswapv4swapswapexactinput-parameters-1sol)
6. [UniswapV4Flash.flash() Parameters (2.sol)](#6-uniswapv4flashflash-parameters-2sol)
7. [Internal / Derived Parameters (auto-set by contracts)](#7-internal--derived-parameters-auto-set-by-contracts)
8. [Parameter Quick-Reference Table](#8-parameter-quick-reference-table)

---

## 1. Hardcoded Constants (no action needed)

These values are baked into the contract source. You do **not** pass them as arguments.

### `POOL_MANAGER`

| Property | Value |
|----------|-------|
| Type | `address` (constant) |
| Value | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Network | Ethereum mainnet |
| Who sets it | Developer (at compile time) |

The Uniswap V4 singleton PoolManager. All swaps, borrows, and repayments go through this address. If you deploy to a different network, you must change this constant before compiling.

> **Testnet addresses:** Check the [Uniswap V4 deployment docs](https://docs.uniswap.org/contracts/v4/deployments) for the correct address on Sepolia or other testnets.

---

### `MIN_SQRT_PRICE` and `MAX_SQRT_PRICE`

| Property | Value |
|----------|-------|
| `MIN_SQRT_PRICE` | `4295128739` |
| `MAX_SQRT_PRICE` | `1461446703485210103287273052203988822378723970342` |
| Type | `uint160` |
| Who sets it | Developer (at compile time) |

These represent the absolute price floor and ceiling for V4 pools (Q64.96 fixed-point format). The contract passes `MIN_SQRT_PRICE + 1` (for `zeroForOne = true`) or `MAX_SQRT_PRICE - 1` (for `zeroForOne = false`) to mean "no price limit — fill as much as possible."

You never pass these as parameters. They are used internally whenever a swap step runs.

---

## 2. `FlashExecutor.execute()` Parameters

These are the five arguments you pass when calling the main entry point.

---

### `flashCurrency` — *Token to borrow*

| Property | Details |
|----------|---------|
| Type | `Currency` (which is `address`) |
| Who supplies | Caller |
| Required | Yes |
| Special value | `address(0)` = native ETH |

The token you want to borrow from the Uniswap V4 pool. This is also the token you must end up with (in excess) to repay the loan. Your swap path must be **circular** — it must start with this token and end with it.

**Examples:**
```
USDC  → 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH  → 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
ETH   → 0x0000000000000000000000000000000000000000
DAI   → 0x6B175474E89094C44Da98b954EedeAC495271d0F
WBTC  → 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
```

---

### `flashAmount` — *Amount to borrow*

| Property | Details |
|----------|---------|
| Type | `uint256` |
| Who supplies | Caller |
| Units | Wei (smallest unit of the token) |
| Required | Yes |
| Constraints | Must be > 0; pool must have this much liquidity |

The raw token amount to borrow, in the token's base unit (wei).

**Conversion examples:**

| Token | Decimals | To borrow 1 unit | `flashAmount` value |
|-------|----------|-----------------|---------------------|
| ETH / WETH | 18 | 1 ETH | `1_000_000_000_000_000_000` (1e18) |
| USDC | 6 | 1 USDC | `1_000_000` (1e6) |
| WBTC | 8 | 1 WBTC | `100_000_000` (1e8) |
| DAI | 18 | 1 DAI | `1_000_000_000_000_000_000` (1e18) |

**How to choose the amount:**
- Larger borrows amplify both profit and risk.
- Must not exceed the pool's available liquidity (check on-chain before calling).
- The V4 pool can lend any amount up to its total token balance.

---

### `steps` — *Array of swap hops*

| Property | Details |
|----------|---------|
| Type | `SwapStep[]` (dynamic array of structs) |
| Who supplies | Caller |
| Required | Yes |
| Minimum length | 1 |
| Maximum length | No hard limit; gas limits apply in practice |

An ordered list of swap instructions. Each element describes one V4 pool swap. They execute **sequentially** — the output of one hop is available as token balance for the next hop.

See [Section 3](#3-swapstep-struct-parameters) for the full breakdown of each field inside `SwapStep`.

**Important:** You are responsible for making sure `amountIn` of each step matches the expected output of the previous step. The contract does not automatically chain amounts — it executes the amounts you specify.

---

### `minProfit` — *Minimum profit threshold*

| Property | Details |
|----------|---------|
| Type | `uint256` |
| Who supplies | Caller |
| Units | Wei (in `flashCurrency`) |
| Required | Yes |
| Special value | `0` = accept any result (even zero profit), not recommended |

After repaying the flash loan, if the remaining balance in `flashCurrency` is less than `minProfit`, the entire transaction reverts with `InsufficientProfit(got, minimum)`.

**Practical guidance:**
- Set to at least `1` to avoid free execution.
- Set to your **actual profit target** so the transaction auto-aborts if market conditions have moved.
- Should also account for gas costs (convert gas × gasPrice to the profit token).

**Example:** If you want at least $5 USDC profit: `minProfit = 5_000_000` (5 × 1e6).

---

### `recipient` — *Profit destination address*

| Property | Details |
|----------|---------|
| Type | `address` |
| Who supplies | Caller |
| Required | Yes |
| Constraints | Must not be `address(0)` (ETH send to zero address would fail) |

The address that receives the profit tokens after the loan is repaid. This is typically:
- Your own EOA (externally owned account / wallet address).
- A treasury / multisig contract.
- Any address you trust.

**Note:** The `execute` caller and `recipient` can be different addresses. You could call from a hot wallet but send profit to a cold wallet.

---

## 3. `SwapStep` Struct Parameters

Every element in the `steps[]` array is a `SwapStep`. Each `SwapStep` has four fields.

---

### `key` — *Pool identifier*

Type: `PoolKey` struct. See [Section 4](#4-poolkey-struct-parameters) for full details.

---

### `zeroForOne` — *Swap direction*

| Property | Details |
|----------|---------|
| Type | `bool` |
| Who supplies | Caller |
| Required | Yes |

Controls which token you sell and which you receive in this hop.

| Value | You sell | You receive |
|-------|---------|------------|
| `true` | `currency0` (lower address) | `currency1` (higher address) |
| `false` | `currency1` (higher address) | `currency0` (lower address) |

**How to determine:**
- Identify the two tokens in the pool (`currency0` and `currency1`).
- If you want to sell `currency0` → set `zeroForOne = true`.
- If you want to sell `currency1` → set `zeroForOne = false`.

**Example with USDC/WETH pool:**
- USDC < WETH by address → USDC = currency0, WETH = currency1.
- To sell USDC and get WETH: `zeroForOne = true`.
- To sell WETH and get USDC: `zeroForOne = false`.

---

### `amountIn` — *Exact input amount for this hop*

| Property | Details |
|----------|---------|
| Type | `uint128` |
| Who supplies | Caller |
| Units | Wei (in the input token) |
| Required | Yes |
| Max value | `2^128 - 1` ≈ 3.4 × 10^38 |

The exact amount of input tokens to swap in this hop.

- For the **first hop**: typically equal to `flashAmount` (you're spending what you borrowed).
- For **subsequent hops**: must match the expected output of the previous hop.

**Calculating inter-hop amounts off-chain:**
Use the Uniswap V4 quoter contract or the SDK to simulate swap output before submitting. The amount you set here is binding — if the pool can't fill it, the transaction reverts.

---

### `minAmountOut` — *Slippage protection per hop*

| Property | Details |
|----------|---------|
| Type | `uint128` |
| Who supplies | Caller |
| Units | Wei (in the output token) |
| Required | Yes |
| Special value | `0` = no slippage protection (dangerous) |

The minimum amount of output tokens acceptable for this swap hop. If the actual output is less, the transaction reverts with `SwapOutputTooLow(stepIndex, got, minimum)`.

**How to set it:**
1. Simulate the swap off-chain to get the expected output.
2. Apply your slippage tolerance (e.g. 0.5%, 1%).
3. `minAmountOut = expectedOutput × (1 - slippageTolerance)`.

**Example (0.5% slippage on 3.0 WETH expected):**
```
expectedOutput = 3.0 WETH = 3_000_000_000_000_000_000
slippage = 0.5% = 0.005
minAmountOut = 3_000_000_000_000_000_000 × 0.995 = 2_985_000_000_000_000_000
```

**For the final hop:** `minAmountOut` must be at least `flashAmount + minProfit` (in `flashCurrency` units) to ensure the loan can be repaid with profit left over.

---

## 4. `PoolKey` Struct Parameters

A `PoolKey` uniquely identifies a single Uniswap V4 pool. All five fields are required.

---

### `currency0` — *Lower-address token*

| Property | Details |
|----------|---------|
| Type | `Currency` (= `address`) |
| Constraint | **Must be the token with the lower address value** |

V4 requires that `currency0 < currency1` (numerically by address). If you get this backwards, the pool will not exist and the transaction will revert.

**Checking address order:**
```javascript
// JavaScript
const isCorrectOrder = BigInt(tokenA) < BigInt(tokenB);
const currency0 = isCorrectOrder ? tokenA : tokenB;
const currency1 = isCorrectOrder ? tokenB : tokenA;
```

**ETH note:** `address(0)` = 0, which is smaller than every token address. So if the pool is ETH/TOKEN, ETH is always `currency0`.

---

### `currency1` — *Higher-address token*

| Property | Details |
|----------|---------|
| Type | `Currency` (= `address`) |
| Constraint | **Must be the token with the higher address value** |

The complement of `currency0`. Always the token with the larger numeric address.

---

### `fee` — *Pool fee tier*

| Property | Details |
|----------|---------|
| Type | `uint24` |
| Units | Hundredths of a basis point (1 bip = 0.01%) |
| Common values | `100`, `500`, `3000`, `10000` |

| `fee` value | Percentage | Typical use |
|------------|-----------|------------|
| `100` | 0.01% | Stablecoins (USDC/DAI, etc.) |
| `500` | 0.05% | Major pairs with tight spreads |
| `3000` | 0.30% | Standard pairs |
| `10000` | 1.00% | Exotic / high-volatility pairs |

You must use the exact fee tier of the pool you want to trade in. A pool with the same tokens but a different fee is a different pool.

---

### `tickSpacing` — *Tick spacing matching the fee tier*

| Property | Details |
|----------|---------|
| Type | `int24` |
| Values | Must match the fee tier |

| `fee` | `tickSpacing` |
|-------|--------------|
| `100` | `1` |
| `500` | `10` |
| `3000` | `60` |
| `10000` | `200` |

`tickSpacing` and `fee` must be consistent. V4 uses tick spacing to define the granularity of price ranges. Using the wrong `tickSpacing` will reference a non-existent pool.

---

### `hooks` — *Hook contract address*

| Property | Details |
|----------|---------|
| Type | `address` |
| Default | `address(0)` (no hooks) |

Most standard Uniswap V4 pools have no hooks. Use `address(0)` unless you are specifically targeting a pool that was deployed with a hook contract.

If you are unsure whether a pool has hooks, look up the pool creation transaction on a V4 explorer or query the PoolManager.

---

## 5. `UniswapV4Swap.swapExactInput()` Parameters (1.sol)

This function is in the standalone swap example (`1.sol`), not in `FlashExecutor`.

```solidity
function swapExactInput(
    PoolKey calldata key,
    uint128 amountIn,
    uint128 minAmountOut
) external returns (uint256 amountOut)
```

| Parameter | Type | Description |
|-----------|------|------------|
| `key` | `PoolKey` | The pool to swap in. See Section 4. |
| `amountIn` | `uint128` | Exact input amount (in `currency0` wei, since direction is hardcoded `zeroForOne = true`). |
| `minAmountOut` | `uint128` | Minimum acceptable output in `currency1` wei. |

**Hardcoded behavior:** `zeroForOne` is always `true` in `1.sol`. This means it always sells `currency0` for `currency1`. If you need the reverse direction, you must modify the code.

**Pre-requisite:** The caller must have called `IERC20(currency0).approve(address(UniswapV4Swap), amountIn)` before calling `swapExactInput`.

---

## 6. `UniswapV4Flash.flash()` Parameters (2.sol)

```solidity
function flash(
    Currency currency,
    uint256  amount,
    bytes calldata data
) external
```

| Parameter | Type | Description |
|-----------|------|------------|
| `currency` | `Currency` (address) | Token to borrow. `address(0)` for ETH. |
| `amount` | `uint256` | Amount to borrow in wei. |
| `data` | `bytes` | Arbitrary bytes passed to `_executeFlashLoanLogic`. You can encode anything here. |

This is a **template contract** — `_executeFlashLoanLogic` does nothing by default. You subclass `UniswapV4Flash` and override that function with your actual logic.

**Important:** The caller must ensure the borrowed tokens are returned to PoolManager (via `transfer` + `settle`) inside the callback. If the delta is non-zero at the end, V4 reverts the transaction.

---

## 7. Internal / Derived Parameters (auto-set by contracts)

These are set automatically by the contracts. You do not supply them.

| Parameter | Set by | Value | Description |
|-----------|--------|-------|-------------|
| `amountSpecified` | `_executeSwapStep` | `-int256(amountIn)` | Negative = exact input mode |
| `sqrtPriceLimitX96` | `_executeSwapStep` | `MIN_SQRT_PRICE + 1` or `MAX_SQRT_PRICE - 1` | No price cap — fill fully |
| `hookData` | `_executeSwapStep` | `bytes("")` | Empty (no hook data) |
| `sender` | `unlockCallback` | `address(this)` | The executor holds tokens itself |
| `poolManager` | constructor | `IPoolManager(POOL_MANAGER)` | Hardcoded singleton |

---

## 8. Parameter Quick-Reference Table

| Parameter | Contract | Type | Hardcoded? | Who sets it | Example |
|-----------|---------|------|-----------|-------------|---------|
| `POOL_MANAGER` | All | `address` | ✅ Yes | Developer | `0x00000…4c5dc7` |
| `MIN_SQRT_PRICE` | All | `uint160` | ✅ Yes | Developer | `4295128739` |
| `MAX_SQRT_PRICE` | All | `uint160` | ✅ Yes | Developer | `14614467…342` |
| `flashCurrency` | FlashExecutor | `Currency` | ❌ Caller | Caller | USDC address |
| `flashAmount` | FlashExecutor | `uint256` | ❌ Caller | Caller | `10_000e6` |
| `steps[]` | FlashExecutor | `SwapStep[]` | ❌ Caller | Caller | See Section 3 |
| `minProfit` | FlashExecutor | `uint256` | ❌ Caller | Caller | `1e6` (1 USDC) |
| `recipient` | FlashExecutor | `address` | ❌ Caller | Caller | Your wallet |
| `steps[i].key` | FlashExecutor | `PoolKey` | ❌ Caller | Caller | See Section 4 |
| `steps[i].zeroForOne` | FlashExecutor | `bool` | ❌ Caller | Caller | `true` |
| `steps[i].amountIn` | FlashExecutor | `uint128` | ❌ Caller | Caller | `10_000e6` |
| `steps[i].minAmountOut` | FlashExecutor | `uint128` | ❌ Caller | Caller | `2_985e15` |
| `key.currency0` | All | `Currency` | ❌ Caller | Caller | USDC (lower addr) |
| `key.currency1` | All | `Currency` | ❌ Caller | Caller | WETH (higher addr) |
| `key.fee` | All | `uint24` | ❌ Caller | Caller | `3000` |
| `key.tickSpacing` | All | `int24` | ❌ Caller | Caller | `60` |
| `key.hooks` | All | `address` | ❌ Caller | Caller | `address(0)` |
| `amountSpecified` | FlashExecutor | `int256` | ✅ Auto | `_executeSwapStep` | `-amountIn` |
| `sqrtPriceLimitX96` | FlashExecutor | `uint160` | ✅ Auto | `_executeSwapStep` | MIN or MAX |
