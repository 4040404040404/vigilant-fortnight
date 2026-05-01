# Full Execution Guide

> Step-by-step instructions for deploying `FlashExecutor.sol` and calling `execute()` to run a flash-loan-powered arbitrage on Uniswap V4 mainnet.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Tooling Setup (Foundry)](#2-tooling-setup-foundry)
3. [Compiling the Contract](#3-compiling-the-contract)
4. [Deploying to Mainnet / Testnet](#4-deploying-to-mainnet--testnet)
5. [Pre-Flight Checklist Before Calling execute()](#5-pre-flight-checklist-before-calling-execute)
6. [Calling execute() — Step by Step](#6-calling-execute--step-by-step)
7. [Calling via Foundry cast](#7-calling-via-foundry-cast)
8. [Calling via ethers.js / viem (JavaScript)](#8-calling-via-ethersjs--viem-javascript)
9. [Reading the Result and Verifying Profit](#9-reading-the-result-and-verifying-profit)
10. [Transaction Reverts – What They Mean](#10-transaction-reverts--what-they-mean)
11. [Gas Considerations](#11-gas-considerations)
12. [Testing on a Mainnet Fork](#12-testing-on-a-mainnet-fork)

---

## 1. Prerequisites

| Requirement | Details |
|-------------|---------|
| Solidity compiler | `^0.8.26` |
| Ethereum node / RPC | Mainnet RPC (e.g. Alchemy, Infura, your own node) |
| EOA with ETH | For gas fees. A small amount (0.01–0.05 ETH) is enough for deployment + calls |
| Knowledge of the target pools | You need the `PoolKey` for each pool you want to trade in |
| Foundry or Hardhat | For compiling, testing, deploying |

---

## 2. Tooling Setup (Foundry)

Foundry is recommended because it handles complex ABI encoding well.

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Initialise a project (if you don't have one)
mkdir my-executor && cd my-executor
forge init

# Copy FlashExecutor.sol into src/
cp /path/to/FlashExecutor.sol src/FlashExecutor.sol
```

No external dependencies are required — `FlashExecutor.sol` is fully self-contained.

---

## 3. Compiling the Contract

```bash
forge build --contracts src/FlashExecutor.sol
```

Expected output:

```
[⠒] Compiling...
[⠃] Compiling 1 files with 0.8.26
[⠊] Solc 0.8.26 finished in Xs
Compiler run successful!
```

If you see errors, ensure your Foundry solc version matches:

```bash
# Check / set solc version
forge config --evm-version cancun
```

---

## 4. Deploying to Mainnet / Testnet

### Using Foundry `forge create`

```bash
forge create src/FlashExecutor.sol:FlashExecutor \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

`FlashExecutor` has a zero-argument constructor — no constructor parameters are needed.

### What Happens at Deployment

The constructor runs:

```solidity
constructor() {
    poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
}
```

The PoolManager address is **hardcoded for Ethereum mainnet**. If you deploy to a testnet (e.g. Sepolia), you must update this constant first.

### Save the Deployed Address

```bash
# Example output after deployment:
# Deployed to: 0xYourFlashExecutorAddress
export FLASH_EXECUTOR=0xYourFlashExecutorAddress
```

---

## 5. Pre-Flight Checklist Before Calling execute()

Before calling `execute()`, verify each of the following:

- [ ] **Correct pool keys** — `currency0 < currency1` (by address value), fee and tickSpacing match a real deployed pool.
- [ ] **Token ordering** — Know which token is `currency0` and which is `currency1` for each pool in your path.
- [ ] **Sufficient liquidity** — The pools must have enough liquidity to fill your swap amounts.
- [ ] **The swap path is circular** — You borrow token A, the final swap output must also be token A (so you can repay).
- [ ] **`minProfit` is reasonable** — Set it to at least 1 wei (not 0) to avoid wasted gas on unprofitable calls. Set it to your actual profit target to auto-revert bad conditions.
- [ ] **`recipient` is correct** — The address that receives profit. Usually your own EOA.
- [ ] **No approval needed** — `FlashExecutor` uses flash accounting and its own token balance; it does **not** pull tokens from your wallet. You do not need to call `approve`.

---

## 6. Calling execute() — Step by Step

### Function Signature

```solidity
function execute(
    Currency   flashCurrency,   // token to borrow
    uint256    flashAmount,     // amount to borrow (in wei / base units)
    SwapStep[] calldata steps,  // array of swap hops
    uint256    minProfit,       // minimum profit in flashCurrency (in wei)
    address    recipient        // address to receive profit
) external nonReentrant
```

### `SwapStep` struct

```solidity
struct SwapStep {
    PoolKey key;          // identifies the pool
    bool    zeroForOne;   // true = sell currency0, false = sell currency1
    uint128 amountIn;     // exact input for this hop
    uint128 minAmountOut; // minimum acceptable output (slippage protection)
}
```

### `PoolKey` struct

```solidity
struct PoolKey {
    Currency currency0;   // lower address token
    Currency currency1;   // higher address token
    uint24   fee;         // e.g. 500, 3000, 10000
    int24    tickSpacing; // must match the fee tier
    address  hooks;       // address(0) if no hooks
}
```

### Example Scenario: USDC → WETH → USDC Arbitrage (2 hops)

You believe USDC is cheaper on Pool A than Pool B. You:
1. Borrow 10,000 USDC via flash loan.
2. Swap 10,000 USDC → WETH on Pool A (cheap USDC → WETH).
3. Swap all WETH → USDC on Pool B (expensive WETH → USDC).
4. Repay 10,000 USDC. Keep the profit.

**Token addresses (mainnet)**:
- USDC: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`

**Address ordering** (currency0 < currency1):
- USDC address `0xA0b8…` < WETH address `0xC02a…` → USDC = currency0, WETH = currency1

**Step 1 – USDC → WETH (Pool A, 0.05% fee)**
```
key.currency0 = USDC
key.currency1 = WETH
key.fee       = 500      (0.05%)
key.tickSpacing = 10
key.hooks     = address(0)
zeroForOne    = true     (sell currency0=USDC, receive currency1=WETH)
amountIn      = 10_000 * 1e6   (USDC has 6 decimals)
minAmountOut  = 2.9 WETH in wei (set to 95% of expected, as slippage tolerance)
```

**Step 2 – WETH → USDC (Pool B, 0.30% fee)**
```
key.currency0 = USDC (same ordering!)
key.currency1 = WETH
key.fee       = 3000     (0.30%)
key.tickSpacing = 60
key.hooks     = address(0)
zeroForOne    = false    (sell currency1=WETH, receive currency0=USDC)
amountIn      = <output from step 1>
minAmountOut  = 10_001 * 1e6   (must exceed the borrowed 10,000 + desired profit)
```

> **Critical:** The output of step 1 (WETH amount) is what you need to set as `amountIn` for step 2. You will need to estimate this off-chain before calling.

---

## 7. Calling via Foundry cast

```bash
# Variables
EXECUTOR=0xYourFlashExecutorAddress
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

# Encode a single SwapStep (tuple ABI encoding)
# (PoolKey(currency0, currency1, fee, tickSpacing, hooks), zeroForOne, amountIn, minAmountOut)

# Full call — two-hop example
cast send $EXECUTOR \
  "execute((address),(uint256),(((address,address,uint24,int24,address),bool,uint128,uint128)[]),(uint256),(address))" \
  "($USDC)" \
  "10000000000" \
  "[((($USDC,$WETH,500,10,0x0000000000000000000000000000000000000000),true,10000000000,2900000000000000000)),((($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000),false,2900000000000000000,10001000000))]" \
  "1000000" \
  "0xYourWallet" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

> For complex tuple arrays, it is easier to use a Foundry script (see below) or ethers.js.

### Using a Foundry Script (recommended for complex calls)

Create `script/RunExecutor.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/FlashExecutor.sol";

contract RunExecutor is Script {
    function run() external {
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

        FlashExecutor executor = FlashExecutor(payable(0xYourExecutorAddress));

        // Build swap steps
        FlashExecutor.SwapStep[] memory steps = new FlashExecutor.SwapStep[](2);

        // Step 1: USDC → WETH on Pool A (0.05% fee)
        steps[0] = FlashExecutor.SwapStep({
            key: PoolKey({
                currency0: Currency.wrap(USDC),
                currency1: Currency.wrap(WETH),
                fee: 500,
                tickSpacing: 10,
                hooks: address(0)
            }),
            zeroForOne: true,
            amountIn: 10_000 * 1e6,          // 10,000 USDC
            minAmountOut: 2.9 ether           // at least 2.9 WETH
        });

        // Step 2: WETH → USDC on Pool B (0.30% fee)
        steps[1] = FlashExecutor.SwapStep({
            key: PoolKey({
                currency0: Currency.wrap(USDC),
                currency1: Currency.wrap(WETH),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            }),
            zeroForOne: false,               // sell WETH (currency1)
            amountIn: 2.9 ether,             // must match expected output of step 1
            minAmountOut: 10_001 * 1e6       // must exceed 10,000 USDC borrowed
        });

        vm.startBroadcast();
        executor.execute(
            Currency.wrap(USDC),  // borrow USDC
            10_000 * 1e6,         // borrow 10,000 USDC
            steps,
            1 * 1e6,              // require at least 1 USDC profit
            msg.sender            // send profit to the script caller
        );
        vm.stopBroadcast();
    }
}
```

Run it:

```bash
forge script script/RunExecutor.s.sol:RunExecutor \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

## 8. Calling via ethers.js / viem (JavaScript)

### ethers.js v6

```javascript
import { ethers } from "ethers";

const FLASH_EXECUTOR_ABI = [
  "function execute(address flashCurrency, uint256 flashAmount, tuple(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)[] steps, uint256 minProfit, address recipient) external"
];

const provider  = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet    = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
const executor  = new ethers.Contract(EXECUTOR_ADDRESS, FLASH_EXECUTOR_ABI, wallet);

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

const steps = [
  {
    key: { currency0: USDC, currency1: WETH, fee: 500, tickSpacing: 10, hooks: ZERO_ADDR },
    zeroForOne: true,
    amountIn:     10_000n * 1_000_000n,   // 10,000 USDC  (6 decimals)
    minAmountOut: 2_900_000_000_000_000_000n  // 2.9 WETH (18 decimals)
  },
  {
    key: { currency0: USDC, currency1: WETH, fee: 3000, tickSpacing: 60, hooks: ZERO_ADDR },
    zeroForOne: false,
    amountIn:     2_900_000_000_000_000_000n,
    minAmountOut: 10_001n * 1_000_000n    // 10,001 USDC
  }
];

const tx = await executor.execute(
  USDC,                          // flashCurrency
  10_000n * 1_000_000n,          // flashAmount
  steps,
  1n * 1_000_000n,               // minProfit: 1 USDC
  wallet.address                 // recipient
);

const receipt = await tx.wait();
console.log("Transaction hash:", receipt.hash);
console.log("Gas used:", receipt.gasUsed.toString());
```

### viem

```javascript
import { createWalletClient, http, parseUnits } from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

const account  = privateKeyToAccount(`0x${process.env.PRIVATE_KEY}`);
const client   = createWalletClient({ account, chain: mainnet, transport: http(process.env.RPC_URL) });

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const ZERO = "0x0000000000000000000000000000000000000000";

const steps = [
  {
    key: { currency0: USDC, currency1: WETH, fee: 500, tickSpacing: 10, hooks: ZERO },
    zeroForOne: true,
    amountIn:     parseUnits("10000", 6),
    minAmountOut: parseUnits("2.9", 18)
  },
  {
    key: { currency0: USDC, currency1: WETH, fee: 3000, tickSpacing: 60, hooks: ZERO },
    zeroForOne: false,
    amountIn:     parseUnits("2.9", 18),
    minAmountOut: parseUnits("10001", 6)
  }
];

const hash = await client.writeContract({
  address: EXECUTOR_ADDRESS,
  abi: FLASH_EXECUTOR_ABI,   // same ABI as above
  functionName: "execute",
  args: [USDC, parseUnits("10000", 6), steps, parseUnits("1", 6), account.address]
});
```

---

## 9. Reading the Result and Verifying Profit

`execute` does not return a value at the Solidity level (the ABI return is internal). To verify profit:

**Option A – Check recipient balance before and after**

```javascript
const before = await usdcContract.balanceOf(wallet.address);
await executor.execute(...);
const after  = await usdcContract.balanceOf(wallet.address);
console.log("Profit:", (after - before).toString(), "USDC wei");
```

**Option B – Use `eth_call` to simulate first**

```bash
# Foundry simulate (no broadcast)
forge script script/RunExecutor.s.sol:RunExecutor --rpc-url $RPC_URL
# (omit --broadcast to dry-run)
```

**Option C – Read emitted events / traces**

Use `cast run <txHash>` or Tenderly to trace the internal calls and see exactly how much was swept.

---

## 10. Transaction Reverts – What They Mean

| Revert Reason | Cause | Fix |
|--------------|-------|-----|
| `NotPoolManager()` | An external contract tried to call `unlockCallback` directly | Never call `unlockCallback` yourself |
| `InsufficientProfit(got, min)` | Swaps did not generate enough profit | Lower `minProfit`, widen spreads, or wait for better market conditions |
| `SwapOutputTooLow(step, got, min)` | A hop's `minAmountOut` was not met | Increase slippage tolerance (lower `minAmountOut`) or recalculate expected output |
| `TransferFailed()` | ERC-20 transfer returned false, or ETH send failed | Check the token contract; ensure executor has the tokens it needs |
| `ReentrancyGuard: reentrant call` | `recipient` contract tried to re-enter `execute` | Fix your recipient contract |
| `FlashExecutor: non-positive swap output` | A swap returned 0 or negative output | Check pool liquidity and token ordering |

---

## 11. Gas Considerations

| Operation | Approximate Gas |
|-----------|----------------|
| Contract deployment | ~400,000 gas |
| `execute` with 1 swap hop | ~150,000–200,000 gas |
| `execute` with 2 swap hops | ~250,000–350,000 gas |
| Each additional hop | +~80,000–120,000 gas |

**Rule of thumb:** Your profit must exceed `gasUsed × gasPrice`. At 10 gwei and 300,000 gas, the cost is 0.003 ETH (~$10). Ensure your `minProfit` accounts for gas cost (convert to the profit token).

---

## 12. Testing on a Mainnet Fork

**Always test on a fork before mainnet.** A fork uses real mainnet state (real pools, real balances) without spending real ETH.

```bash
# Start a fork (Foundry/Anvil)
anvil --fork-url $RPC_URL --fork-block-number latest

# In another terminal, run your script against the local fork
forge script script/RunExecutor.s.sol:RunExecutor \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

The default Anvil private key has 10,000 ETH on the fork. Pool state and token balances are exactly as on mainnet.
