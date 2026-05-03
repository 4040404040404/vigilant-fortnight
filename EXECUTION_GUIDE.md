# End-to-End Execution Guide

This guide walks you through **deploying and running every contract** in this repository from scratch — from installing tools to sending your first live transaction. All commands are copy-paste ready.

---

## Table of Contents

1. [Repository Map](#1-repository-map)
2. [Environment Setup](#2-environment-setup)
   - [Install Foundry](#install-foundry)
   - [Set Environment Variables](#set-environment-variables)
   - [Verify Connection](#verify-connection)
3. [Addresses & Constants Quick Reference](#3-addresses--constants-quick-reference)
4. [Contract 1 — UniswapV4Swap (`1.sol`)](#4-contract-1--uniswapv4swap-1sol)
   - [Deploy](#deploy-1)
   - [Pre-flight: Approve tokens](#pre-flight-approve-tokens)
   - [Execute: `swapExactInput`](#execute-swapexactinput)
   - [Read the result](#read-the-result-swap)
5. [Contract 2 — UniswapV4Flash (`2.sol`)](#5-contract-2--uniswapv4flash-2sol)
   - [Deploy](#deploy-2)
   - [Execute: `flash`](#execute-flash)
6. [Contract 3 — LimitOrderHook (`Limit.sol`)](#6-contract-3--limitorderhook-limitsol)
   - [Deploy](#deploy-3)
   - [Find the current tick](#find-the-current-tick)
   - [Execute: `placeLimitOrder`](#execute-placelimitorder)
   - [Execute: `cancelLimitOrder`](#execute-cancellimitorder)
   - [Read state](#read-state)
7. [Contract 4 — FlashLoanPosition (`FlashLoanPosition.sol`)](#7-contract-4--flashloanposition-flashloanpositionsol)
   - [Deploy](#deploy-4)
   - [Pre-flight: Approve tokens](#pre-flight-approve-tokens-1)
   - [Execute: `openLeveragedPosition`](#execute-openleveragedposition)
   - [Read the result](#read-the-result-position)
8. [Foundry Script — Run Everything in One Go](#8-foundry-script--run-everything-in-one-go)
9. [JavaScript / ethers.js Execution](#9-javascript--ethersjs-execution)
10. [Pre-flight Checklist](#10-pre-flight-checklist)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Repository Map

| File | Contract | Purpose |
|---|---|---|
| `1.sol` | `UniswapV4Swap` | Exact-input token swap via V4 PoolManager |
| `2.sol` | `UniswapV4Flash` | Zero-fee flash loan base contract |
| `Limit.sol` | `LimitOrderHook` | V4 hook that implements limit orders |
| `FlashLoanPosition.sol` | `FlashLoanPosition` | Flash-loan-funded leveraged position |
| `SHARED_CONCEPTS.md` | — | Background: V4 patterns, PoolKey, BalanceDelta |
| `UNISWAP_V4_SWAP.md` | — | Deep dive for `1.sol` |
| `FLASH_LOAN.md` | — | Deep dive for `2.sol` |
| `LIMIT_ORDER_HOOK.md` | — | Deep dive for `Limit.sol` |
| `FLASH_LOAN_POSITION.md` | — | Deep dive for `FlashLoanPosition.sol` |
| `EXECUTION_GUIDE.md` | — | **This file** |

---

## 2. Environment Setup

### Install Foundry

Foundry provides `forge` (compile & deploy) and `cast` (send transactions).

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify
forge --version   # forge 0.2.x
cast --version    # cast 0.2.x
```

### Set Environment Variables

Create a `.env` file in the project root (never commit this file):

```bash
# .env — do NOT commit to git
RPC_URL=https://mainnet.infura.io/v3/YOUR_INFURA_KEY
PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE
ETHERSCAN_KEY=YOUR_ETHERSCAN_API_KEY   # optional, for verification

# Token addresses (Ethereum mainnet — already hardcoded in contracts, provided here for cast calls)
POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
```

Load the variables into your shell:

```bash
source .env
```

> **Security:** Use a dedicated deployment wallet. Never expose your private key. Consider using a hardware wallet with `--ledger` flag or `cast wallet` keystore.

### Verify Connection

```bash
# Check you are on Ethereum mainnet (chain ID = 1)
cast chain-id --rpc-url $RPC_URL
# Expected output: 1

# Check your wallet address and ETH balance
cast wallet address --private-key $PRIVATE_KEY
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $RPC_URL --ether
```

---

## 3. Addresses & Constants Quick Reference

| Name | Address / Value |
|---|---|
| `POOL_MANAGER` (Ethereum mainnet) | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| `USDC` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| `MIN_SQRT_PRICE` | `4295128739` |
| `MAX_SQRT_PRICE` | `1461446703485210103287273052203988822378723970342` |
| USDC decimals | 6 |
| WETH decimals | 18 |
| USDC/WETH pool fee | `3000` (0.3%) |
| USDC/WETH tickSpacing | `60` |

**Token amount helpers:**

```bash
# 1000 USDC in wei (6 decimals)
cast to-wei 1000 6     # → 1000000000

# 1 WETH in wei (18 decimals)
cast to-wei 1 ether    # → 1000000000000000000
```

---

## 4. Contract 1 — UniswapV4Swap (`1.sol`)

Performs a single exact-input swap (always `currency0 → currency1`).  
Full details: [`UNISWAP_V4_SWAP.md`](UNISWAP_V4_SWAP.md)

### Deploy 1

```bash
forge create 1.sol:UniswapV4Swap \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# Save the deployed address
export SWAP_CONTRACT=<DeployedTo address from output>
```

Optional — verify on Etherscan:

```bash
forge verify-contract $SWAP_CONTRACT 1.sol:UniswapV4Swap \
  --chain-id 1 \
  --etherscan-api-key $ETHERSCAN_KEY
```

### Pre-flight: Approve Tokens

The contract pulls input tokens from your wallet using `transferFrom`, so you must approve it first.

**Approving USDC (for a USDC → WETH swap):**

```bash
# Approve the swap contract to spend 1000 USDC (1000 * 10^6 = 1000000000)
cast send $USDC \
  "approve(address,uint256)" \
  $SWAP_CONTRACT 1000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

Verify the allowance was set:

```bash
cast call $USDC \
  "allowance(address,address)(uint256)" \
  $(cast wallet address --private-key $PRIVATE_KEY) $SWAP_CONTRACT \
  --rpc-url $RPC_URL
# Should return 1000000000
```

### Execute: `swapExactInput`

**Function signature:**
```
swapExactInput(
    (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key,
    uint128 amountIn,
    uint128 minAmountOut
) → uint256 amountOut
```

**Parameters explained:**

| Parameter | Type | Value (USDC→WETH example) | Notes |
|---|---|---|---|
| `key.currency0` | `address` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDC (lower address) |
| `key.currency1` | `address` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | WETH (higher address) |
| `key.fee` | `uint24` | `3000` | 0.3% pool |
| `key.tickSpacing` | `int24` | `60` | Standard for 0.3% pools |
| `key.hooks` | `address` | `0x0000000000000000000000000000000000000000` | No hook |
| `amountIn` | `uint128` | `1000000000` | 1000 USDC |
| `minAmountOut` | `uint128` | `495000000000000000` | 0.495 WETH (1% slippage) |

**`cast` command:**

```bash
cast send $SWAP_CONTRACT \
  "swapExactInput((address,address,uint24,int24,address),uint128,uint128)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  495000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Read the Result (Swap)

`swapExactInput` returns `amountOut` in the transaction return data. Use `cast call` to simulate before sending:

```bash
cast call $SWAP_CONTRACT \
  "swapExactInput((address,address,uint24,int24,address),uint128,uint128)(uint256)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  495000000000000000 \
  --rpc-url $RPC_URL \
  --from $(cast wallet address --private-key $PRIVATE_KEY)
```

---

## 5. Contract 2 — UniswapV4Flash (`2.sol`)

Zero-fee flash loan base. Override `_executeFlashLoanLogic` in a subcontract for real use.  
Full details: [`FLASH_LOAN.md`](FLASH_LOAN.md)

### Deploy 2

```bash
forge create 2.sol:UniswapV4Flash \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

export FLASH_CONTRACT=<DeployedTo address from output>
```

> **Note:** `UniswapV4Flash` is a base contract. Deploying it as-is will execute a flash loan that borrows and immediately repays without doing anything — useful for testing the plumbing. For a real use case, create a subcontract that overrides `_executeFlashLoanLogic`.

### Execute: `flash`

**Function signature:**
```
flash(
    address currency,   // token to borrow (address(0) = native ETH)
    uint256 amount,     // how many tokens to borrow
    bytes data          // forwarded to _executeFlashLoanLogic
) → (no return value)
```

**Parameters explained:**

| Parameter | Type | Value (borrow WETH example) | Notes |
|---|---|---|---|
| `currency` | `address` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | WETH address |
| `amount` | `uint256` | `1000000000000000000` | 1 WETH (18 decimals) |
| `data` | `bytes` | `0x` | Empty for base contract; encode custom instructions for subcontracts |

**Borrow 1 WETH (base contract — borrow + immediate repay):**

```bash
cast send $FLASH_CONTRACT \
  "flash(address,uint256,bytes)" \
  $WETH \
  1000000000000000000 \
  "0x" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

**Borrow native ETH (use `address(0)`):**

```bash
cast send $FLASH_CONTRACT \
  "flash(address,uint256,bytes)" \
  0x0000000000000000000000000000000000000000 \
  1000000000000000000 \
  "0x" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

**Passing custom data to your logic (encode with `cast abi-encode`):**

```bash
# Encode two params: target DEX address + swap path bytes
ENCODED=$(cast abi-encode "f(address,bytes)" 0xTargetDex 0xSwapPath)

cast send $FLASH_CONTRACT \
  "flash(address,uint256,bytes)" \
  $WETH \
  1000000000000000000 \
  $ENCODED \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## 6. Contract 3 — LimitOrderHook (`Limit.sol`)

A Uniswap V4 hook that stores limit orders by price tick and auto-executes them when the price crosses.  
Full details: [`LIMIT_ORDER_HOOK.md`](LIMIT_ORDER_HOOK.md)

> **Important:** The hook contract must be deployed at an address where the lower bits match the required permissions. This requires a `CREATE2` deployment with a mined salt. See [Uniswap V4 hook deployment docs](https://github.com/Uniswap/v4-core/blob/main/docs/whitepaper-v4.pdf). For testing on a local fork, deploy normally.

### Deploy 3

`LimitOrderHook` takes the PoolManager address as a constructor argument (unlike the other contracts which hardcode it):

```bash
forge create Limit.sol:LimitOrderHook \
  --constructor-args $POOL_MANAGER \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

export HOOK_CONTRACT=<DeployedTo address from output>
```

### Find the Current Tick

Before placing a limit order, read the current tick so you know which side to place your order on:

```bash
# Compute the pool ID (keccak256 of the ABI-encoded PoolKey)
POOL_KEY_ENCODED=$(cast abi-encode \
  "(address,address,uint24,int24,address)" \
  $USDC $WETH 3000 60 $HOOK_CONTRACT)
POOL_ID=$(cast keccak $POOL_KEY_ENCODED)

# Read slot0: returns (sqrtPriceX96, currentTick, protocolFee, lpFee)
cast call $POOL_MANAGER \
  "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
  $POOL_ID \
  --rpc-url $RPC_URL
# Example output: 79228162514264337593543950336  76012  0  3000
#                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^  sqrtPrice  currentTick
```

### Execute: `placeLimitOrder`

**Function signature:**
```
placeLimitOrder(
    (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key,
    int24 tick,
    bool zeroForOne,
    uint256 amount
) → (no return value)
```

**Parameters explained:**

| Parameter | Type | Value (sell 1 WETH at tick 76980) | Notes |
|---|---|---|---|
| `key.currency0` | `address` | `0xA0b8...` (USDC) | Lower address token |
| `key.currency1` | `address` | `0xC02a...` (WETH) | Higher address token |
| `key.fee` | `uint24` | `3000` | Must match the initialized pool |
| `key.tickSpacing` | `int24` | `60` | Must match the initialized pool |
| `key.hooks` | `address` | `$HOOK_CONTRACT` | **Must be this hook's address** |
| `tick` | `int24` | `76980` | Target price tick; must be multiple of tickSpacing (60) |
| `zeroForOne` | `bool` | `false` | `false` = selling WETH (currency1) when price rises |
| `amount` | `uint256` | `1000000000000000000` | 1 WETH |

**Step 1 — Approve the hook to spend your tokens:**

```bash
# Approve 1 WETH (selling WETH, zeroForOne=false → currency1)
cast send $WETH \
  "approve(address,uint256)" \
  $HOOK_CONTRACT 1000000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

**Step 2 — Place the order:**

```bash
cast send $HOOK_CONTRACT \
  "placeLimitOrder((address,address,uint24,int24,address),int24,bool,uint256)" \
  "($USDC,$WETH,3000,60,$HOOK_CONTRACT)" \
  76980 \
  false \
  1000000000000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Execute: `cancelLimitOrder`

**Function signature:**
```
cancelLimitOrder(
    (address,address,uint24,int24,address) key,
    int24 tick,
    bool zeroForOne
) → (no return value)
```

Use the same `key`, `tick`, and `zeroForOne` you used when placing:

```bash
cast send $HOOK_CONTRACT \
  "cancelLimitOrder((address,address,uint24,int24,address),int24,bool)" \
  "($USDC,$WETH,3000,60,$HOOK_CONTRACT)" \
  76980 \
  false \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

Your WETH is returned to your wallet.

### Read State

```bash
MY_WALLET=$(cast wallet address --private-key $PRIVATE_KEY)

# Check your position size at a tick
cast call $HOOK_CONTRACT \
  "userPositions(bytes32,int24,bool,address)(uint256)" \
  $POOL_ID \
  76980 \
  false \
  $MY_WALLET \
  --rpc-url $RPC_URL

# Check total liquidity at a tick
cast call $HOOK_CONTRACT \
  "tickLiquidity(bytes32,int24,bool)(uint256)" \
  $POOL_ID \
  76980 \
  false \
  --rpc-url $RPC_URL
```

---

## 7. Contract 4 — FlashLoanPosition (`FlashLoanPosition.sol`)

Opens a leveraged position using a V4 flash loan in a single atomic transaction.  
Full details: [`FLASH_LOAN_POSITION.md`](FLASH_LOAN_POSITION.md)

### Deploy 4

```bash
forge create FlashLoanPosition.sol:FlashLoanPosition \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

export POSITION_CONTRACT=<DeployedTo address from output>
```

### Pre-flight: Approve Tokens 1

Only `userAmount` needs approval — the flash-borrowed portion comes from the pool:

```bash
# Example: approving 1000 USDC as margin (1000 * 10^6 = 1000000000)
cast send $USDC \
  "approve(address,uint256)" \
  $POSITION_CONTRACT 1000000000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Execute: `openLeveragedPosition`

**Function signature:**
```
openLeveragedPosition(
    (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key,
    uint256 userAmount,
    uint256 flashAmount,
    uint256 minNetOutput,
    bool zeroForOne
) → uint256 netOutput
```

**Parameters explained:**

| Parameter | Type | Value (5× USDC→WETH example) | Notes |
|---|---|---|---|
| `key.currency0` | `address` | `0xA0b8...` (USDC) | Lower-address token |
| `key.currency1` | `address` | `0xC02a...` (WETH) | Higher-address token |
| `key.fee` | `uint24` | `3000` | Pool fee tier |
| `key.tickSpacing` | `int24` | `60` | Pool tick spacing |
| `key.hooks` | `address` | `0x000...0` | No hook |
| `userAmount` | `uint256` | `1000000000` | Your 1000 USDC margin |
| `flashAmount` | `uint256` | `4000000000` | Flash-borrow 4000 USDC → 5× leverage |
| `minNetOutput` | `uint256` | `482000000000000000` | Minimum 0.482 WETH (≈1% slippage) |
| `zeroForOne` | `bool` | `true` | Buy WETH (currency1) with USDC (currency0) |

**Leverage formula:**
```
leverage = (userAmount + flashAmount) / userAmount
5× = (1000 + 4000) / 1000
```

**`cast` command:**

```bash
cast send $POSITION_CONTRACT \
  "openLeveragedPosition((address,address,uint24,int24,address),uint256,uint256,uint256,bool)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  4000000000 \
  482000000000000000 \
  true \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Read the Result (Position)

Simulate the call first to check the expected output without spending gas:

```bash
cast call $POSITION_CONTRACT \
  "openLeveragedPosition((address,address,uint24,int24,address),uint256,uint256,uint256,bool)(uint256)" \
  "($USDC,$WETH,3000,60,0x0000000000000000000000000000000000000000)" \
  1000000000 \
  4000000000 \
  0 \
  true \
  --rpc-url $RPC_URL \
  --from $(cast wallet address --private-key $PRIVATE_KEY)
# Returns netOutput in wei (divide by 10^18 for WETH)
```

Check your WETH balance after the transaction:

```bash
MY_WALLET=$(cast wallet address --private-key $PRIVATE_KEY)
cast call $WETH \
  "balanceOf(address)(uint256)" $MY_WALLET \
  --rpc-url $RPC_URL
```

---

## 8. Foundry Script — Run Everything in One Go

Save the following as `script/Execute.s.sol`, then run it with `forge script`:

```solidity
// script/Execute.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

// ── Minimal interfaces ────────────────────────────────────────────────────────
interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

interface IUniswapV4Swap {
    function swapExactInput(PoolKey calldata, uint128, uint128)
        external returns (uint256);
}

interface IFlashLoanPosition {
    function openLeveragedPosition(PoolKey calldata, uint256, uint256, uint256, bool)
        external returns (uint256);
}

// ── Script ────────────────────────────────────────────────────────────────────
contract Execute is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address swapContract     = vm.envAddress("SWAP_CONTRACT");
        address positionContract = vm.envAddress("POSITION_CONTRACT");

        PoolKey memory key = PoolKey({
            currency0:   USDC,
            currency1:   WETH,
            fee:         3000,
            tickSpacing: 60,
            hooks:       address(0)
        });

        vm.startBroadcast(pk);

        // ── 1. Swap 1000 USDC → WETH ─────────────────────────────────────────
        IERC20(USDC).approve(swapContract, 1_000_000_000);
        uint256 swapOut = IUniswapV4Swap(swapContract)
            .swapExactInput(key, 1_000_000_000, 495_000_000_000_000_000);
        console.log("Swap received WETH:", swapOut);

        // ── 2. Open 5x leveraged USDC→WETH position ──────────────────────────
        IERC20(USDC).approve(positionContract, 1_000_000_000);
        uint256 netOut = IFlashLoanPosition(positionContract)
            .openLeveragedPosition(key, 1_000_000_000, 4_000_000_000, 482_000_000_000_000_000, true);
        console.log("Leveraged position netOutput WETH:", netOut);

        vm.stopBroadcast();
    }
}
```

**Run the script (simulation — no real transaction):**

```bash
forge script script/Execute.s.sol:Execute \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

**Run with broadcast (real transactions):**

```bash
forge script script/Execute.s.sol:Execute \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

## 9. JavaScript / ethers.js Execution

Install dependencies:

```bash
npm install ethers
```

Save as `execute.js` and run with `node execute.js`:

```javascript
// execute.js
import { ethers } from "ethers";

const RPC_URL    = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const SWAP_CONTRACT     = process.env.SWAP_CONTRACT;
const POSITION_CONTRACT = process.env.POSITION_CONTRACT;

const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

const ERC20_ABI = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
];

const SWAP_ABI = [
    "function swapExactInput(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint128 amountIn, uint128 minAmountOut) returns (uint256 amountOut)",
];

const POSITION_ABI = [
    "function openLeveragedPosition(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 userAmount, uint256 flashAmount, uint256 minNetOutput, bool zeroForOne) returns (uint256 netOutput)",
];

const POOL_KEY = {
    currency0: USDC,
    currency1: WETH,
    fee: 3000,
    tickSpacing: 60,
    hooks: ethers.ZeroAddress,
};

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const signer   = new ethers.Wallet(PRIVATE_KEY, provider);

    const usdc     = new ethers.Contract(USDC, ERC20_ABI, signer);
    const weth     = new ethers.Contract(WETH, ERC20_ABI, signer);
    const swap     = new ethers.Contract(SWAP_CONTRACT, SWAP_ABI, signer);
    const position = new ethers.Contract(POSITION_CONTRACT, POSITION_ABI, signer);

    const amountIn     = 1_000_000_000n;             // 1000 USDC
    const minAmountOut = 495_000_000_000_000_000n;   // 0.495 WETH

    // ── 1. Swap ───────────────────────────────────────────────────────────────
    console.log("Approving USDC for swap...");
    await (await usdc.approve(SWAP_CONTRACT, amountIn)).wait();

    console.log("Executing swap...");
    const swapTx = await swap.swapExactInput(POOL_KEY, amountIn, minAmountOut);
    const swapReceipt = await swapTx.wait();
    console.log("Swap tx:", swapReceipt.hash);

    const wethAfterSwap = await weth.balanceOf(signer.address);
    console.log("WETH balance after swap:", ethers.formatEther(wethAfterSwap), "WETH");

    // ── 2. Leveraged position ─────────────────────────────────────────────────
    const userAmount    = 1_000_000_000n;             // 1000 USDC margin
    const flashAmount   = 4_000_000_000n;             // 4000 USDC borrowed → 5× leverage
    const minNetOutput  = 482_000_000_000_000_000n;   // 0.482 WETH minimum

    console.log("Approving USDC for position contract...");
    await (await usdc.approve(POSITION_CONTRACT, userAmount)).wait();

    console.log("Opening 5x leveraged position...");
    const posTx = await position.openLeveragedPosition(
        POOL_KEY, userAmount, flashAmount, minNetOutput, true
    );
    const posReceipt = await posTx.wait();
    console.log("Position tx:", posReceipt.hash);

    const wethAfterPosition = await weth.balanceOf(signer.address);
    console.log("WETH balance after position:", ethers.formatEther(wethAfterPosition), "WETH");
}

main().catch(console.error);
```

Run:

```bash
RPC_URL=$RPC_URL \
PRIVATE_KEY=$PRIVATE_KEY \
SWAP_CONTRACT=$SWAP_CONTRACT \
POSITION_CONTRACT=$POSITION_CONTRACT \
node execute.js
```

---

## 10. Pre-flight Checklist

Before every transaction, confirm:

- [ ] `source .env` — environment variables are loaded in your current shell
- [ ] `cast chain-id --rpc-url $RPC_URL` returns `1` (Ethereum mainnet)
- [ ] Your wallet has enough ETH for gas (check with `cast balance`)
- [ ] You have approved the contract for the correct token and amount
- [ ] The `PoolKey` you are using matches a real initialized V4 pool
  - `currency0` address < `currency1` address (numerically)
  - `fee` and `tickSpacing` match the pool's parameters
  - `hooks` matches the actual hook (or `address(0)` for no hook)
- [ ] For `LimitOrderHook`: the tick is on the correct side of the current price
  - `zeroForOne=true` → `tick > currentTick`
  - `zeroForOne=false` → `tick < currentTick`
- [ ] For `FlashLoanPosition`: `minNetOutput` is set (not `0` in production)
- [ ] Simulated the call with `cast call` first — no revert
- [ ] The contract is deployed and address is saved in your env

---

## 11. Troubleshooting

### Transaction reverts with no message

```bash
# Replay the failed transaction to get the revert reason
cast run <TX_HASH> --rpc-url $RPC_URL
```

Or simulate before sending:

```bash
cast call <CONTRACT> "<FUNCTION_SIG>" <ARGS> \
  --rpc-url $RPC_URL \
  --from <YOUR_WALLET>
```

### Common revert reasons

| Revert | Contract | Cause | Fix |
|---|---|---|---|
| `NotPoolManager` | All | `unlockCallback` called directly | Do not call it; only the PoolManager calls it |
| `SwapFailed` | `1.sol` | Output < `minAmountOut` | Raise slippage tolerance (lower `minAmountOut`) |
| `InsufficientOutput` | `FlashLoanPosition.sol` | `netOutput < minNetOutput` | Lower `minNetOutput` or reduce `flashAmount` |
| `InvalidTick` | `Limit.sol` | Tick on wrong side of current price | Read current tick first; ensure correct direction |
| `ERC-20 insufficient allowance` | All | Missing `approve` | Run `cast send $TOKEN "approve(...)"` |
| `ERC-20 transfer amount exceeds balance` | All | Not enough tokens in wallet | Top up or reduce amount |
| `"FlashLoanPosition: transferFrom failed"` | `FlashLoanPosition.sol` | `approve` not called or expired | Re-approve `userAmount` before calling |
| `"FlashLoanPosition: insufficient output to repay"` | `FlashLoanPosition.sol` | Repayment cost > gross output | Reduce `flashAmount`; increase `userAmount` |

### Get estimated gas before sending

```bash
cast estimate $CONTRACT \
  "<FUNCTION_SIG>" <ARGS> \
  --rpc-url $RPC_URL \
  --from $(cast wallet address --private-key $PRIVATE_KEY)
```

### Check if the V4 pool exists

```bash
# If getSlot0 returns all zeros, the pool is not initialized
cast call $POOL_MANAGER \
  "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
  $POOL_ID \
  --rpc-url $RPC_URL
# sqrtPriceX96 = 0 → pool does not exist
```

### Verify contract bytecode on Etherscan

```bash
forge verify-contract $CONTRACT_ADDRESS \
  <SOURCE_FILE>:<CONTRACT_NAME> \
  --chain-id 1 \
  --etherscan-api-key $ETHERSCAN_KEY
```
