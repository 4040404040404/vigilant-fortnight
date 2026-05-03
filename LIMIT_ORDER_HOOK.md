# LimitOrderHook — Code Explanation & Execution Guide

**Source file:** `Limit.sol`  
**Contract:** `LimitOrderHook`

---

## Table of Contents

1. [What This Contract Does](#1-what-this-contract-does)
2. [How Uniswap V4 Hooks Work](#2-how-uniswap-v4-hooks-work)
3. [Architecture Overview](#3-architecture-overview)
4. [Code Walkthrough — Line by Line](#4-code-walkthrough--line-by-line)
5. [Parameters Reference](#5-parameters-reference)
   - [Constructor Parameters](#constructor-parameters)
   - [`placeLimitOrder` Parameters](#placelimitorder-parameters)
   - [`cancelLimitOrder` Parameters](#cancellimitorder-parameters)
6. [Step-by-Step Execution Guide](#6-step-by-step-execution-guide)
7. [Worked Example — Place a Limit Sell for WETH at $2,100](#7-worked-example--place-a-limit-sell-for-weth-at-2100)
8. [How Limit Orders Are Triggered](#8-how-limit-orders-are-triggered)
9. [Errors and Troubleshooting](#9-errors-and-troubleshooting)
10. [Limitations and Production Gaps](#10-limitations-and-production-gaps)

---

## 1. What This Contract Does

`LimitOrderHook` is a Uniswap V4 **hook contract** that implements limit orders. A limit order is an instruction to swap tokens automatically when the market price reaches a target level.

Users can:
- **Place** a limit order at a specific price tick (tokens are deposited into the hook).
- **Have the order auto-executed** when the pool price crosses that tick (triggered by another user's swap).
- **Cancel** an unfilled limit order and retrieve their tokens.

---

## 2. How Uniswap V4 Hooks Work

V4 hooks are contracts that the PoolManager calls **before or after** lifecycle events (swaps, liquidity changes, etc.). The hook contract must be set as `PoolKey.hooks` when the pool is initialized.

The PoolManager checks which hooks a contract wants by reading a bitmap encoded in the **hook contract's address** (the lower bits of the address). This means:
- Hooks must be deployed at a specific address matching their permissions.
- This contract declares it needs `afterSwap` (see `getHookPermissions()`).

When any swap executes in the pool that uses this hook, the PoolManager calls `afterSwap` on this contract. The hook then checks if the new price has crossed any limit order tick, and if so, triggers execution.

---

## 3. Architecture Overview

```
Deployment
  │
  └─ LimitOrderHook deployed at address with correct hook flags
     (the address encodes afterSwap=true in its lower bits)

Placing an Order
  │
  │ 1. token.approve(LimitOrderHook, amount)
  │ 2. placeLimitOrder(key, tick, zeroForOne, amount)
  ▼
LimitOrderHook
  ├─ Validates tick is on correct side of current price
  ├─ Pulls tokens from user
  └─ Records: tickLiquidity[poolId][tick][dir] += amount
              userPositions[poolId][tick][dir][user] += amount

Any User's Swap (in the same pool)
  │
  └─ PoolManager calls afterSwap on LimitOrderHook
       └─ Check: did price cross a limit order tick?
            └─ Yes → _executeLimitOrders(key, tick, dir, amount)
                      Clears tickLiquidity, emits LimitOrderFilled event

Cancellation
  │
  └─ cancelLimitOrder(key, tick, zeroForOne)
       └─ Returns user's tokens, reduces tickLiquidity
```

---

## 4. Code Walkthrough — Line by Line

### Constructor (lines 20–22)

```solidity
constructor(IPoolManager _poolManager) {
    poolManager = _poolManager;
}
```

Unlike the other contracts, `LimitOrderHook` takes `_poolManager` as a constructor argument. This is because hooks may be deployed on different networks or test environments, so the address is not hardcoded.

### State storage (lines 11–15)

```solidity
// Total tokens deposited at a given tick for a given direction in a pool
mapping(bytes32 => mapping(int24 => mapping(bool => uint256))) public tickLiquidity;

// Per-user breakdown of the above
mapping(bytes32 => mapping(int24 => mapping(bool => mapping(address => uint256))))
    public userPositions;
```

- `bytes32` key = `keccak256(abi.encode(PoolKey))` = the pool ID.
- `int24` key = the tick (price level) for the order.
- `bool` key = `true` for sell-currency0 orders, `false` for sell-currency1 orders.

### `placeLimitOrder` (lines 29–56)

```solidity
function placeLimitOrder(
    PoolKey calldata key,
    int24 tick,
    bool zeroForOne,
    uint256 amount
) external
```

1. **Reads current tick** from `poolManager.getSlot0(poolId)`.
2. **Validates** that the order tick is on the correct side of the current price:
   - `zeroForOne = true` (sell currency0 when price rises): `tick > currentTick`.
   - `zeroForOne = false` (sell currency1 when price falls): `tick < currentTick`.
3. **Transfers** `amount` tokens from the caller to the hook contract.
4. **Records** the order in both `tickLiquidity` and `userPositions`.

### `afterSwap` (lines 60–85)

```solidity
function afterSwap(
    address,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    BalanceDelta,
    bytes calldata
) external override returns (bytes4, int128)
```

Called by the PoolManager after **every swap** in this pool. It:
1. Checks security: only PoolManager may call.
2. Reads `currentTick` post-swap from `getSlot0`.
3. Determines which direction of limit orders to check:
   - A `zeroForOne` swap moves price DOWN → triggers orders waiting to sell token1.
   - A `!zeroForOne` swap moves price UP → triggers orders waiting to sell token0.
4. If `tickLiquidity[poolId][currentTick][direction] > 0`, calls `_executeLimitOrders`.

### `_executeLimitOrders` (lines 88–106)

```solidity
function _executeLimitOrders(
    PoolKey calldata key,
    int24 tick,
    bool zeroForOne,
    uint256 amount
) internal
```

In this simplified implementation:
- Clears the tick's liquidity (marks orders as filled).
- Emits `LimitOrderFilled` for off-chain indexers to track.

> **⚠️ Important:** The actual token swap and distribution to users is **not yet implemented** (see the TODO comment in the code). A production implementation would call `poolManager.swap(...)` and distribute output tokens to each order placer proportionally.

### `cancelLimitOrder` (lines 109–126)

```solidity
function cancelLimitOrder(PoolKey calldata key, int24 tick, bool zeroForOne) external
```

Allows a user to cancel an unfilled order:
1. Looks up `userPositions[poolId][tick][dir][msg.sender]`.
2. Clears their position and reduces `tickLiquidity`.
3. Transfers their tokens back.

### `getHookPermissions` (lines 129–146)

Declares which hook callbacks this contract uses. Only `afterSwap = true`. All others are `false`.

The PoolManager uses this to verify the hook contract at pool initialization.

---

## 5. Parameters Reference

### Constructor Parameters

| Parameter | Type | Description |
|---|---|---|
| `_poolManager` | `IPoolManager` | Address of the Uniswap V4 PoolManager |

On mainnet: `0x000000000004444c5dc75cB358380D2e3dE08A90`

### `placeLimitOrder` Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `key` | `PoolKey` | Yes | The pool to place the order in |
| `tick` | `int24` | Yes | Target price tick for execution |
| `zeroForOne` | `bool` | Yes | `true` = sell currency0 when price rises; `false` = sell currency1 when price falls |
| `amount` | `uint256` | Yes | Amount of tokens to sell, in token's smallest unit |

#### How to choose `tick`

A tick corresponds to a price: `price = 1.0001^tick`.

To find the tick for a target price:
```
tick = log(targetPrice) / log(1.0001)
tick = floor(ln(targetPrice) / 0.00009995)   [approximately]
```

Examples (USDC/WETH pool where price = WETH price in USDC):

| Target WETH Price | Approximate Tick |
|---|---|
| $2,000 | ~76,012 |
| $2,100 | ~76,972 |
| $2,500 | ~79,810 |
| $3,000 | ~83,030 |

The tick must also be a multiple of `tickSpacing` (e.g., 60 for 0.3% pools). Round to the nearest valid tick.

> Use the [Uniswap V3/V4 tick math tools](https://uniswapv3book.com/docs/introduction/uniswap-v3/) or the `TickMath` library to compute precise tick values.

#### Tick validity rules

| `zeroForOne` | Order type | Tick must be |
|---|---|---|
| `true` | Sell currency0 (price will rise to fill) | `tick > currentTick` |
| `false` | Sell currency1 (price will fall to fill) | `tick < currentTick` |

### `cancelLimitOrder` Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `key` | `PoolKey` | Yes | Same pool key used when placing the order |
| `tick` | `int24` | Yes | Same tick used when placing the order |
| `zeroForOne` | `bool` | Yes | Same direction used when placing the order |

---

## 6. Step-by-Step Execution Guide

### Prerequisites

1. The pool must have been initialized with this hook contract as `PoolKey.hooks`.
2. Hooks must be deployed at an address where the lower bits encode the correct permissions (`afterSwap = true`). This requires a special deployment process using `CREATE2` with a specific salt — see the [Uniswap V4 hook deployment guide](https://github.com/Uniswap/v4-core).

### Step 1 — Deploy the hook at a valid address

```bash
# The hook address must have the correct permission bits.
# Use Foundry's hook miner or a CREATE2 factory.
forge script script/DeployHook.s.sol \
  --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Step 2 — Initialize a pool with this hook

The pool's `PoolKey.hooks` must be set to the hook contract's address at pool initialization time. This is a one-time operation.

### Step 3 — Approve the hook to spend your tokens

```javascript
// ethers.js — approve WETH for selling
const weth = new ethers.Contract(WETH_ADDRESS, ERC20_ABI, signer);
await weth.approve(HOOK_ADDRESS, ethers.parseEther("1.0")); // 1 WETH
```

```bash
cast send $WETH "approve(address,uint256)" $HOOK 1000000000000000000 \
  --rpc-url mainnet --private-key $PK
```

### Step 4 — Place a limit order

```javascript
// ethers.js
const hook = new ethers.Contract(HOOK_ADDRESS, HOOK_ABI, signer);

const key = {
    currency0: USDC_ADDRESS,
    currency1: WETH_ADDRESS,
    fee: 3000,
    tickSpacing: 60,
    hooks: HOOK_ADDRESS
};

// Sell 1 WETH when price rises to ~$2,100 (tick ≈ 76,980, rounded to multiple of 60)
const tick = 76980;    // must be > current tick and divisible by tickSpacing
const zeroForOne = false; // selling currency1 (WETH) when price rises
const amount = ethers.parseEther("1.0"); // 1 WETH

const tx = await hook.placeLimitOrder(key, tick, zeroForOne, amount);
await tx.wait();
```

### Step 5 — Wait for execution

The order executes automatically when a swap in the same pool moves the price to `tick`. You will see a `LimitOrderFilled` event on-chain.

> **Note:** In the current simplified implementation, the filled event is emitted but tokens are NOT yet distributed. See [Limitations](#10-limitations-and-production-gaps).

### Step 6 — Cancel if needed

```javascript
const tx = await hook.cancelLimitOrder(key, tick, zeroForOne);
await tx.wait();
// Your WETH is returned to your wallet
```

---

## 7. Worked Example — Place a Limit Sell for WETH at $2,100

**Scenario:** Current WETH price is $2,000. You want to sell 1 WETH when price reaches $2,100.

| Parameter | Value |
|---|---|
| `key.currency0` | USDC (`0xA0b8...`) |
| `key.currency1` | WETH (`0xC02a...`) |
| `key.fee` | `3000` |
| `key.tickSpacing` | `60` |
| `key.hooks` | `<hook address>` |
| `tick` | `76980` (≈ $2,100, rounded to nearest 60-multiple) |
| `zeroForOne` | `false` (selling WETH = currency1) |
| `amount` | `1_000_000_000_000_000_000` (1 WETH) |

**Flow:**
1. You approve and call `placeLimitOrder` → 1 WETH transferred to hook.
2. Any trade that moves WETH price through tick 76980 triggers `afterSwap`.
3. `afterSwap` detects `tickLiquidity[poolId][76980][false] = 1e18 > 0`.
4. `_executeLimitOrders` clears the record and emits `LimitOrderFilled`.
5. (Production) Your WETH would be sold and USDC sent to you.

---

## 8. How Limit Orders Are Triggered

```
Price timeline:

  tick 76000 (current)
  ─────────────────────────────────────────────────────▶ time
                                  ↑
                           Another user swaps, moving price to tick 76980
                           PoolManager calls afterSwap
                           → LimitOrderHook sees liquidity at tick 76980
                           → _executeLimitOrders fires
                           → LimitOrderFilled event emitted
```

**Direction logic:**
- `zeroForOne` swaps push price **down** (currency0 becomes cheaper) → triggers `false` (sell-currency1) orders.
- `!zeroForOne` swaps push price **up** → triggers `true` (sell-currency0) orders.

---

## 9. Errors and Troubleshooting

| Error | Reason | Fix |
|---|---|---|
| `NotPoolManager` | `afterSwap` called by non-PoolManager | Never call `afterSwap` manually |
| `InvalidTick` | Tick is on wrong side of current price | Check current tick; ensure `tick > current` for zeroForOne orders |
| `No position` (on cancel) | No open order at that tick/direction | Check tick and direction match your original order |
| `ERC20: insufficient allowance` | Forgot to approve | Call `token.approve(hook, amount)` first |
| Order never fills | Price never reached the tick | The market did not move far enough; cancel if no longer wanted |
| Hook not triggered | Pool was initialized without this hook | The pool's `PoolKey.hooks` must point to this contract — cannot be changed after initialization |

---

## 10. Limitations and Production Gaps

This contract is a **simplified demonstration**. Before production use, the following gaps must be addressed:

1. **`_executeLimitOrders` does not actually swap.** It only clears state and emits an event. A production implementation must call `poolManager.swap(...)` inside the hook callback and distribute proceeds to each order placer.

2. **No per-user fill distribution.** Currently, `userPositions` is tracked but `_executeLimitOrders` does not iterate users and send them output tokens.

3. **Partial fills not supported.** If a swap moves price partially through a tick, only one tick is checked (the current tick post-swap). Orders at other ticks remain open.

4. **Hook address must encode permissions.** Deployment requires a `CREATE2` with a specific salt so the address lower bits match the required permissions. This is non-trivial and usually requires a miner script.

5. **No tick range orders.** Orders are at a single tick, not a range. For range orders (like V3 liquidity positions), a more complex implementation using `modifyLiquidity` is needed.
