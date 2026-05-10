# Full Execution Guide (Remix Deploy & Run)

This guide explains full execution flow for the planned flash-loan executor pattern using current repository contracts as base.

## 1) Environment Setup

1. Open Remix IDE.
2. Load contract file(s) from this repo.
3. Select Solidity compiler version `0.8.26`.
4. Compile contract.
5. In **Deploy & Run Transactions**:
   - choose correct network/provider
   - verify account has gas funds

## 2) Deploy

For current examples (`1.sol`, `2.sol`):
- Constructors are zero-argument, so click **Deploy** directly.

For planned `FlashExecutor.sol`:
- Also recommended as zero-argument if keeping hardcoded PoolManager.

## 3) Pre-Execution Prerequisites

Before flash execution:
- Confirm target token addresses are correct for selected chain.
- Confirm PoolKey and pool existence (if your strategy touches swaps).
- If flow requires token approvals to third-party protocols, set approvals first.
- If contract needs initial buffer for fees/slippage protection, fund it.

## 4) Execution Model You Will Use

Expected high-level runtime:
1. Call executor entrypoint (e.g., `executeFlash(...)`).
2. Contract calls `PoolManager.unlock(...)`.
3. `unlockCallback(...)` runs:
   - borrow using `take`
   - execute arbitrary call steps
   - repay via `settle`
4. If repay/profit checks pass, transaction finalizes.

## 5) Direct Interaction in Deploy & Run (No External ABI)

To avoid external ABI dependency:
- Keep all needed interfaces/structs in the same Solidity source file.
- Use Remix auto-generated function forms for struct/array inputs.
- Paste hex `bytes` callData directly into function argument fields.

## 6) Practical Execution Sequence

For each run:
1. Prepare strategy step data (target, value, calldata).
2. Prepare flash inputs (currency, amount).
3. Set minimum return/profit threshold.
4. Execute transaction from Deploy & Run module.
5. Check transaction status and emitted events.

## 7) Failure Handling Checklist

If transaction reverts:
- Validate callback caller gating logic is correct.
- Validate borrowed token amount is fully repayable in same transaction.
- Check target calls did not revert.
- Check `minProfit/minReturn` threshold is realistic.
- Check token approvals/balances for all called protocols.

## 8) Safety Recommendations for First Production Iteration

- Start with owner-only executor access.
- Add explicit events for step success/failure context.
- Use strict minimum output/profit constraints.
- Prefer small notional testing first.
- Test on fork/testnet before any mainnet value flow.

## 9) What You Need Next to Execute End-to-End

You still need a dedicated `FlashExecutor.sol` implementation (planned in `IMPLEMENTATION_PLAN.md`) that adds:
- Arbitrary call step execution
- Repayment/profit safeguards
- Operational helper functions for Remix usage
