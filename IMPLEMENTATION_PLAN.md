# Implementation Plan: Flash Loan Arbitrary Executor (Remix-first, no external ABI)

## Goal
Build a **single main Solidity executor contract** that combines:
- Flash-loan flow from `2.sol` (`unlock` + `unlockCallback` + `take/settle`)
- Optional swap capability pattern from `1.sol` (for repayment or strategy steps)
- Arbitrary on-chain call execution from inside the flash loan callback

The result should be deployable and usable directly in **Remix Deploy & Run Transactions**, without relying on external ABI files.

## Current-State Findings from Repository
- `2.sol` already shows flash borrowing and repayment lifecycle with `PoolManager`.
- `1.sol` already shows swap execution through `PoolManager.swap` and settlement mechanics.
- Both examples hardcode Ethereum mainnet `POOL_MANAGER`, and use a zero-argument constructor.
- No production-grade arbitrary call executor exists yet.

## Target Contract Shape
Create a new main contract (recommended name: `FlashExecutor.sol`) with:
1. **Entry function** to start flash loan with encoded execution plan.
2. **`unlockCallback`** that:
   - validates `msg.sender == poolManager`
   - borrows tokens using `take`
   - executes one or more arbitrary calls
   - enforces post-call balance/profit constraints
   - repays principal via `settle`
3. **Low-level call engine** (`target`, `value`, `callData`) supporting multiple steps.
4. **Safety controls** for Remix/manual use:
   - whitelist or owner-only execution
   - minimum expected ending balance / minimum profit check
   - revert bubbling for failed downstream calls
   - optional deadline/nonce guard
5. **Utility functions** for token approvals, withdrawals, ETH reception.

## Data Model Plan
Define a simple struct set for direct Remix interaction:
- `FlashRequest`
  - `Currency loanCurrency`
  - `uint256 loanAmount`
  - `Execution[] steps`
  - `uint256 minReturnOrProfit`
  - `address profitReceiver`
- `Execution`
  - `address target`
  - `uint256 value`
  - `bytes callData`

Keep structs in the same contract for ABI availability in Remix UI.

## Execution Flow Plan
1. User calls `executeFlash(FlashRequest request)`.
2. Contract encodes request and calls `poolManager.unlock(...)`.
3. In `unlockCallback`:
   - decode request
   - `take(loanCurrency, address(this), loanAmount)`
   - execute each step in order via low-level `.call`
   - verify contract now has enough to repay (+ optional profit threshold)
   - repay (`ERC20 transfer + settle` or native `settle{value: ...}`)
   - transfer realized profit to receiver
4. Return success bytes to `PoolManager`.

## Security & Correctness Plan
- Restrict executor entrypoint (`onlyOwner` or role) for initial version.
- Validate each step target is non-zero and not forbidden.
- Prevent accidental ETH loss (`value` checks and controlled receive path).
- Check ERC20 transfer return values.
- Revert with explicit errors on:
  - callback caller mismatch
  - insufficient repayment balance
  - arbitrary call failure
  - unmet min profit
- Optional reentrancy guard around public initiation function.

## Remix UX Plan (No External ABI)
- Keep all interfaces/types needed for calls inside contract file.
- Expose helper methods that reduce manual ABI encoding pain:
  - `buildStep(address target, uint256 value, bytes calldata callData)` (optional)
  - per-strategy convenience wrappers (optional, later)
- Provide docs with exact examples of:
  - currency addresses
  - amount units
  - bytes encoding via Remix

## Validation Plan
- Compile in Remix with Solidity `0.8.26`.
- Dry-run on testnet/fork with:
  1. Simple borrow+repay no-op cycle
  2. Single arbitrary call path
  3. Multi-step call path
  4. Failure cases (bad target, under-repayment, minProfit unmet)
- Confirm transaction is executable fully from Deploy & Run module.

## Documentation Deliverables Plan
- Explain current codebase behavior and limitations.
- Full execution instructions from deployment to flash run.
- Full parameter catalog with examples/how-to-specify.
- Clarifying decision checklist for unresolved strategy details.

## Clarifying Questions (Needed Before Final Contract Build)
1. Should first release be **owner-only** executor, or public with safeguards?
2. Do you want **single-call** arbitrary execution first, or full **multi-step** pipeline immediately?
3. Should profit check be in borrowed token only, or allow profit in another token?
4. Should we include built-in swap helper functions in executor, or keep only generic call engine?
5. Which network is primary for deployment/testing (mainnet fork, Sepolia, other)?
6. Do you want a strict target whitelist in contract, or fully flexible targets?
