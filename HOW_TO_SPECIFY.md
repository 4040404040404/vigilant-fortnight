# How to Specify Parameters

> Concrete, step-by-step instructions for determining and encoding every caller-supplied parameter for `FlashExecutor.execute()`.

---

## Table of Contents

1. [Overview – What You Need to Know Before Calling](#1-overview--what-you-need-to-know-before-calling)
2. [Step 1: Choose flashCurrency](#step-1-choose-flashcurrency)
3. [Step 2: Choose flashAmount](#step-2-choose-flashamount)
4. [Step 3: Build Each PoolKey](#step-3-build-each-poolkey)
5. [Step 4: Determine zeroForOne for Each Hop](#step-4-determine-zeroforone-for-each-hop)
6. [Step 5: Calculate amountIn for Each Hop](#step-5-calculate-amountin-for-each-hop)
7. [Step 6: Calculate minAmountOut for Each Hop](#step-6-calculate-minamountout-for-each-hop)
8. [Step 7: Set minProfit](#step-7-set-minprofit)
9. [Step 8: Set recipient](#step-8-set-recipient)
10. [Full Worked Example: 2-Hop USDC Arbitrage](#full-worked-example-2-hop-usdc-arbitrage)
11. [Full Worked Example: 3-Hop Triangular Arbitrage (ETH → USDC → DAI → ETH)](#full-worked-example-3-hop-triangular-arbitrage)
12. [Tools for Off-Chain Simulation](#tools-for-off-chain-simulation)
13. [Common Mistakes and How to Avoid Them](#common-mistakes-and-how-to-avoid-them)

---

## 1. Overview – What You Need to Know Before Calling

Before you can fill in any parameter, you need three pieces of on-chain knowledge:

| What you need | Where to get it |
|--------------|----------------|
| Token contract addresses | Etherscan, CoinGecko, Uniswap app |
| Token decimals | ERC-20 `decimals()` function, or Etherscan |
| Pool fee tier and tick spacing | Uniswap V4 pool explorer or the pool creation event |
| Expected swap output at current price | V4 Quoter contract, Uniswap SDK, or off-chain simulation |

The function signature you're filling is:

```solidity
execute(
    Currency   flashCurrency,   // ← Step 1
    uint256    flashAmount,     // ← Step 2
    SwapStep[] calldata steps,  // ← Steps 3–6 (one SwapStep per hop)
    uint256    minProfit,       // ← Step 7
    address    recipient        // ← Step 8
)
```

---

## Step 1: Choose `flashCurrency`

**What it is:** The ERC-20 token address (or `address(0)` for ETH) you want to borrow.

**Rule:** Your swap path must be circular. Whatever you borrow is what you must end up with to repay.

**How to specify:**

```solidity
// Borrow USDC
Currency flashCurrency = Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

// Borrow WETH
Currency flashCurrency = Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

// Borrow native ETH
Currency flashCurrency = Currency.wrap(address(0));
```

In JavaScript/TypeScript (ethers.js or cast):
```javascript
// Just pass the address string directly — ABI encoding handles the rest
const flashCurrency = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";  // USDC
```

---

## Step 2: Choose `flashAmount`

**What it is:** How many tokens (in wei) you want to borrow.

**How to convert human-readable to wei:**

```
wei_amount = human_amount × 10^decimals
```

| Token | Decimals | 10,000 tokens in wei |
|-------|----------|---------------------|
| USDC | 6 | `10_000 × 10^6 = 10_000_000_000` |
| WETH | 18 | `10_000 × 10^18 = 10_000_000_000_000_000_000_000` |
| DAI | 18 | same as WETH |
| WBTC | 8 | `10_000 × 10^8 = 1_000_000_000_000` |

**In Solidity:**
```solidity
uint256 flashAmount = 10_000 * 1e6;       // 10,000 USDC
uint256 flashAmount = 5 * 1e18;           // 5 WETH
uint256 flashAmount = 1 * 1e8;            // 1 WBTC
```

**In JavaScript:**
```javascript
import { parseUnits } from "ethers";
const flashAmount = parseUnits("10000", 6);    // 10,000 USDC
const flashAmount = parseUnits("5", 18);       // 5 WETH
```

**In Foundry cast:**
```bash
cast --to-wei 10000 6    # 10,000 USDC → 10000000000
```

**Practical guidance:**
- Larger borrows = more profit per opportunity, but more gas risk.
- The pool must have at least `flashAmount` in reserve.
- Start with smaller amounts while testing (e.g. 100 USDC).

---

## Step 3: Build Each `PoolKey`

A `PoolKey` identifies a specific V4 pool. You need one for every hop.

### 3a. Find the token addresses

Look up both tokens on Etherscan or Uniswap. Note their addresses exactly.

**Common mainnet addresses:**

| Token | Address |
|-------|---------|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| ETH (native) | `0x0000000000000000000000000000000000000000` |

### 3b. Order the tokens (critical!)

`currency0` **must** have a lower numeric address than `currency1`.

```javascript
// JavaScript: sort two token addresses
function sortTokens(tokenA, tokenB) {
    return BigInt(tokenA) < BigInt(tokenB)
        ? { currency0: tokenA, currency1: tokenB }
        : { currency0: tokenB, currency1: tokenA };
}

const { currency0, currency1 } = sortTokens(
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",  // USDC
    "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"   // WETH
);
// → currency0 = USDC (0xA0b8... < 0xC02a...)
// → currency1 = WETH
```

```solidity
// Solidity: confirm ordering at runtime (optional defensive check)
require(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1), "Wrong token order");
```

### 3c. Choose fee tier and tick spacing

Find the fee tier of the specific pool you want to use. A USDC/WETH pool can exist at 0.05%, 0.30%, and 1.00% simultaneously — they are separate pools.

| Fee value | Fee % | `tickSpacing` | Best for |
|-----------|-------|---------------|---------|
| `100` | 0.01% | `1` | Stablecoin pairs |
| `500` | 0.05% | `10` | Major tokens (BTC, ETH) |
| `3000` | 0.30% | `60` | General pairs |
| `10000` | 1.00% | `200` | Exotic tokens |

**To verify a pool exists:** Query the PoolManager or use the Uniswap V4 analytics page for your token pair.

### 3d. Set hooks

Most pools: `address(0)` (no hooks).

```solidity
PoolKey memory key = PoolKey({
    currency0:   Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
    currency1:   Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // WETH
    fee:         500,
    tickSpacing: 10,
    hooks:       address(0)
});
```

---

## Step 4: Determine `zeroForOne` for Each Hop

**Rule:**
- If you want to sell `currency0` (lower address token) → `zeroForOne = true`
- If you want to sell `currency1` (higher address token) → `zeroForOne = false`

**Practical cheat sheet for USDC/WETH pool (USDC = currency0, WETH = currency1):**

| You want to... | `zeroForOne` |
|----------------|-------------|
| Sell USDC, get WETH | `true` |
| Sell WETH, get USDC | `false` |

**For a multi-hop circular path (borrow USDC → path → repay USDC):**

```
Hop 1: USDC → WETH   →  zeroForOne = true   (sell USDC=currency0)
Hop 2: WETH → USDC   →  zeroForOne = false  (sell WETH=currency1, in USDC/WETH pool)
```

---

## Step 5: Calculate `amountIn` for Each Hop

**Hop 1:** Set `amountIn = flashAmount`.

```solidity
steps[0].amountIn = uint128(flashAmount);  // spend all borrowed tokens in hop 1
```

**Hop 2+:** Set `amountIn` to the **expected output** of the previous hop.

You must simulate this off-chain before submitting. Use the V4 quoter:

```javascript
// Pseudo-code using Uniswap V4 Quoter
const { amountOut: hop1Output } = await quoter.quoteExactInputSingle({
    tokenIn:  USDC,
    tokenOut: WETH,
    fee:      500,
    amountIn: flashAmount,
    sqrtPriceLimitX96: 0
});

// Use hop1Output as amountIn for hop 2
steps[1].amountIn = hop1Output;
```

> **Important:** `amountIn` is `uint128`, max value `2^128 - 1 ≈ 3.4 × 10^38`. For all practical token amounts this is never a problem.

---

## Step 6: Calculate `minAmountOut` for Each Hop

**Purpose:** Slippage protection. The transaction reverts if actual output < `minAmountOut`.

**Formula:**
```
minAmountOut = expectedOutput × (1 - slippageTolerance)
```

**Example with 0.5% slippage:**

```javascript
const expectedOutput = await quoteSwap(hop1Input);        // simulate off-chain
const slippage = 0.005;                                   // 0.5%
const minAmountOut = expectedOutput * (1n - BigInt(Math.floor(slippage * 1000)) / 1000n);
// Or more simply:
const minAmountOut = expectedOutput * 995n / 1000n;       // 99.5% of expected
```

**For the last hop (which must repay the loan):**

The final hop's output must be at least `flashAmount + minProfit`.

```solidity
// If flashAmount = 10,000 USDC = 10_000e6, minProfit = 10 USDC = 10e6:
steps[lastIndex].minAmountOut = uint128(flashAmount + minProfit);
// = 10_010_000_000
```

> **Why this matters:** If the final hop returns exactly `flashAmount`, you repay the loan but get $0 profit. `minAmountOut` on the last hop is your strongest profit guarantee.

---

## Step 7: Set `minProfit`

**What it is:** After repaying the loan, the executor checks its remaining balance. If it's less than `minProfit`, the transaction reverts.

**How to set it:**

```solidity
// Option A: Minimum viable (1 token unit)
uint256 minProfit = 1;  // 1 wei — just ensure you don't lose money

// Option B: Dollar-based (e.g. at least $5 USDC)
uint256 minProfit = 5 * 1e6;  // 5 USDC

// Option C: Percentage of flashAmount (e.g. 0.1%)
uint256 minProfit = flashAmount / 1000;  // 0.1% of borrowed amount
```

**Accounting for gas:** Convert gas cost to token units:

```javascript
const gasPrice   = 10n * 10n**9n;    // 10 gwei
const gasLimit   = 300_000n;
const ethCostWei = gasPrice * gasLimit;  // 0.003 ETH

// Convert to USDC (approximate, needs ETH/USDC price)
const ethPriceInUsdc = 3000n;             // $3000/ETH
const gasCostUsdc = ethCostWei * ethPriceInUsdc / 10n**18n * 10n**6n;
// ≈ 9 USDC

// Set minProfit to at least cover gas
const minProfit = gasCostUsdc + 1_000_000n;  // gas cost + 1 USDC target profit
```

---

## Step 8: Set `recipient`

**What it is:** The address that receives the profit.

**Usually:** Your own wallet address.

```solidity
address recipient = msg.sender;          // profit goes back to the caller
address recipient = 0xYourWalletAddress; // or any specific address
```

In a Foundry script:
```solidity
address recipient = vm.envAddress("RECIPIENT");  // read from env var
```

In JavaScript:
```javascript
const recipient = await wallet.getAddress();  // your own wallet
```

---

## Full Worked Example: 2-Hop USDC Arbitrage

**Scenario:** You see that USDC is overpriced on Pool A (USDC/WETH 0.05%) and underpriced on Pool B (USDC/WETH 0.30%).

- Borrow 10,000 USDC.
- Buy WETH cheaply on Pool A (sell USDC → get WETH).
- Sell WETH expensively on Pool B (sell WETH → get USDC).
- Repay 10,000 USDC. Keep the surplus.

**Off-chain simulation results:**
- 10,000 USDC → ~3.1 WETH on Pool A (price: ~$3,226/ETH)
- 3.1 WETH → ~10,050 USDC on Pool B (price: ~$3,242/ETH)
- Expected profit: ~50 USDC

### Solidity Parameters

```solidity
// ── flashCurrency ──────────────────────────────────────────────────────────
Currency flashCurrency = Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
// USDC address

// ── flashAmount ────────────────────────────────────────────────────────────
uint256 flashAmount = 10_000 * 1e6;  // 10,000 USDC (6 decimals)

// ── steps ──────────────────────────────────────────────────────────────────
FlashExecutor.SwapStep[] memory steps = new FlashExecutor.SwapStep[](2);

// Hop 1: Sell 10,000 USDC → get WETH on Pool A (fee=500)
steps[0] = FlashExecutor.SwapStep({
    key: PoolKey({
        currency0: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),  // USDC
        currency1: Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),  // WETH
        fee:         500,
        tickSpacing: 10,
        hooks:       address(0)
    }),
    zeroForOne:   true,                         // sell USDC (currency0)
    amountIn:     uint128(10_000 * 1e6),        // 10,000 USDC
    minAmountOut: uint128(3.08 ether)           // expect ~3.1 WETH, 99.4% floor
});

// Hop 2: Sell WETH → get USDC on Pool B (fee=3000)
steps[1] = FlashExecutor.SwapStep({
    key: PoolKey({
        currency0: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),  // USDC
        currency1: Currency.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),  // WETH
        fee:         3000,
        tickSpacing: 60,
        hooks:       address(0)
    }),
    zeroForOne:   false,                        // sell WETH (currency1)
    amountIn:     uint128(3.08 ether),          // use the min output of hop 1
    minAmountOut: uint128(10_010 * 1e6)         // need at least 10,010 USDC (loan + $10 profit)
});

// ── minProfit ──────────────────────────────────────────────────────────────
uint256 minProfit = 10 * 1e6;   // at least 10 USDC profit

// ── recipient ──────────────────────────────────────────────────────────────
address recipient = msg.sender;  // your wallet
```

### JavaScript (ethers.js) Parameters

```javascript
const USDC      = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH      = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
const { parseUnits, parseEther } = ethers;

const flashCurrency = USDC;
const flashAmount   = parseUnits("10000", 6);    // 10,000 USDC

const steps = [
    {
        key: {
            currency0:   USDC,
            currency1:   WETH,
            fee:         500,
            tickSpacing: 10,
            hooks:       ZERO_ADDR
        },
        zeroForOne:   true,
        amountIn:     parseUnits("10000", 6),    // 10,000 USDC
        minAmountOut: parseEther("3.08")         // 3.08 WETH minimum
    },
    {
        key: {
            currency0:   USDC,
            currency1:   WETH,
            fee:         3000,
            tickSpacing: 60,
            hooks:       ZERO_ADDR
        },
        zeroForOne:   false,
        amountIn:     parseEther("3.08"),        // matches hop 1 minAmountOut
        minAmountOut: parseUnits("10010", 6)     // 10,010 USDC minimum
    }
];

const minProfit = parseUnits("10", 6);           // 10 USDC
const recipient = await wallet.getAddress();

await executor.execute(flashCurrency, flashAmount, steps, minProfit, recipient);
```

---

## Full Worked Example: 3-Hop Triangular Arbitrage

**Scenario:** ETH → USDC → DAI → ETH price discrepancy across three pools.

**Token addresses:**
- ETH (native): `0x0000000000000000000000000000000000000000`
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- DAI: `0x6B175474E89094C44Da98b954EedeAC495271d0F`

**Address ordering:**
- ETH (0x0000…) < DAI (0x6B17…) < USDC (0xA0b8…)

**Pools:**
- ETH/USDC: currency0=ETH, currency1=USDC, fee=500
- USDC/DAI: currency0=DAI, currency1=USDC (DAI < USDC), fee=100
- ETH/DAI: currency0=ETH, currency1=DAI, fee=500

```solidity
FlashExecutor.SwapStep[] memory steps = new FlashExecutor.SwapStep[](3);

// Borrow: 1 ETH = 1e18 wei

// Hop 1: ETH → USDC (sell ETH, buy USDC on ETH/USDC pool)
steps[0] = FlashExecutor.SwapStep({
    key: PoolKey({
        currency0: Currency.wrap(address(0)),            // ETH = currency0 (lowest)
        currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),  // USDC
        fee: 500, tickSpacing: 10, hooks: address(0)
    }),
    zeroForOne:   true,           // sell ETH (currency0)
    amountIn:     uint128(1e18),  // 1 ETH
    minAmountOut: uint128(3200 * 1e6)  // expect ~$3,200
});

// Hop 2: USDC → DAI (on USDC/DAI stable pool)
// currency0=DAI (0x6B17 < 0xA0b8), currency1=USDC
steps[1] = FlashExecutor.SwapStep({
    key: PoolKey({
        currency0: Currency.wrap(0x6B175474E89094C44Da98b954EedeAC495271d0F),  // DAI
        currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),  // USDC
        fee: 100, tickSpacing: 1, hooks: address(0)
    }),
    zeroForOne:   false,           // sell USDC (currency1), receive DAI (currency0)
    amountIn:     uint128(3200 * 1e6),    // 3,200 USDC from hop 1
    minAmountOut: uint128(3200 * 1e18)    // ~3,200 DAI (1:1 stable swap minus fee)
});

// Hop 3: DAI → ETH (on ETH/DAI pool)
// currency0=ETH (0x0000 < 0x6B17), currency1=DAI
steps[2] = FlashExecutor.SwapStep({
    key: PoolKey({
        currency0: Currency.wrap(address(0)),            // ETH
        currency1: Currency.wrap(0x6B175474E89094C44Da98b954EedeAC495271d0F),  // DAI
        fee: 500, tickSpacing: 10, hooks: address(0)
    }),
    zeroForOne:   false,           // sell DAI (currency1), receive ETH (currency0)
    amountIn:     uint128(3200 * 1e18),   // 3,200 DAI from hop 2
    minAmountOut: uint128(1.001 ether)    // need >1 ETH to repay + profit
});

// Call execute
executor.execute(
    Currency.wrap(address(0)),  // borrow ETH
    1e18,                       // 1 ETH
    steps,
    0.001 ether,                // min 0.001 ETH profit
    msg.sender
);
```

---

## Tools for Off-Chain Simulation

You must simulate swap outputs before submitting, or risk MEV-frontruns causing `SwapOutputTooLow` reverts.

### 1. Uniswap V4 Quoter Contract

Query the quoter to get exact output estimates:

```javascript
const quoterAddress = "0x...";  // V4 Quoter on mainnet (check Uniswap docs)
const quoter = new ethers.Contract(quoterAddress, QUOTER_ABI, provider);

const { amountOut } = await quoter.quoteExactInputSingle.staticCall({
    poolKey: { currency0: USDC, currency1: WETH, fee: 500, tickSpacing: 10, hooks: ZERO },
    zeroForOne: true,
    exactAmount: parseUnits("10000", 6),
    sqrtPriceLimitX96: 0
});
```

### 2. Foundry Mainnet Fork Simulation

```bash
forge script script/RunExecutor.s.sol --rpc-url $RPC_URL  # no --broadcast = dry run
```

The script output will show the actual profit if the transaction had been sent at the current block.

### 3. Tenderly

Simulate the exact calldata on Tenderly (free tier available) to see exactly what would happen, including all internal state changes.

### 4. Manual Price Calculation

```
expectedOutput ≈ amountIn × currentPrice × (1 - feeTier/1_000_000)
```

This is approximate. Use the quoter for accuracy.

---

## Common Mistakes and How to Avoid Them

| Mistake | Symptom | Fix |
|---------|---------|-----|
| `currency0 > currency1` | Transaction reverts immediately | Always sort: lower address = currency0 |
| Wrong fee / tickSpacing combo | Pool not found, revert | Match fee to tickSpacing exactly (see table in PARAMETERS.md) |
| `amountIn` of hop 2 > actual output of hop 1 | `TransferFailed` or `SwapOutputTooLow` | Use quoter to simulate hop 1 first |
| Non-circular swap path | `InsufficientProfit` or token mismatch | Ensure final output token = `flashCurrency` |
| `minAmountOut` of final hop < `flashAmount` | `InsufficientProfit` | Set final hop `minAmountOut` ≥ `flashAmount + minProfit` |
| Forgetting that USDC has 6 decimals | Off-by-10^12 errors | Always check `decimals()` and use `parseUnits` |
| `minProfit = 0` | Transaction succeeds with zero profit (wasted gas) | Always set `minProfit > 0` |
| Using `1.sol` or `2.sol` instead of `FlashExecutor.sol` | Incomplete logic | Only `FlashExecutor.sol` is the production contract |
| Not accounting for gas in profit calculation | Winning on paper, losing in ETH | Compute gas cost and add to `minProfit` equivalent |
