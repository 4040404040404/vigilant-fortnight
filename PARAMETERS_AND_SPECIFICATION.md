# Necessary Parameters: What Is Required, Already Specified, and How to Specify

## A. Already Specified in Current Contracts

From `1.sol` and `2.sol`:
1. `POOL_MANAGER` is hardcoded to Uniswap v4 mainnet singleton.
2. Constructors are zero-argument.
3. Callback model (`unlock` + `unlockCallback`) is already wired.

Implication:
- In Remix deployment, you do not need to provide PoolManager address unless contract is refactored.

## B. Parameters You Must Provide Per Execution

## 1) Flash Loan Inputs
- `currency` (`Currency` / address wrapper)
  - token to borrow (`address(0)` for native ETH path)
- `amount` (`uint256`)
  - amount to borrow in token base units

How to specify:
- Use real token address on selected chain.
- Convert human units to token decimals before input (e.g., 1 USDC = 1_000_000).

## 2) Arbitrary Execution Inputs (for planned executor)
Each step should include:
- `target` (`address`) — contract to call
- `value` (`uint256`) — ETH value sent in call
- `callData` (`bytes`) — ABI-encoded function payload

How to specify:
- `target`: pasted as checksum address.
- `value`: usually `0` for ERC20 interactions.
- `callData`: paste hex bytes (`0x...`) encoded for target function.

## 3) Risk/Outcome Constraints
Recommended required parameters:
- `minReturnOrProfit` (`uint256`)
- `profitReceiver` (`address`)
- optional `deadline` (`uint256`) / `nonce` for replay control

How to specify:
- Set minimum threshold based on conservative expected output.
- Use your own wallet or treasury address as receiver.

## C. Swap-Related Inputs (If Strategy Uses Swaps)
From `1.sol` pattern:
- `PoolKey key`
  - `currency0`
  - `currency1`
  - `fee`
  - `tickSpacing`
  - `hooks`
- `zeroForOne`
- `amountSpecified` semantics (negative exact input)
- `sqrtPriceLimitX96`

How to specify:
- Pull exact pool config from known deployed pool metadata.
- Match token ordering and fee tier exactly.
- Use safe sqrt price limits to avoid crossing invalid ranges.

## D. Token Approval/Balance Parameters
Needed depending on strategy step contracts:
- Approval amount per token/protocol
- Contract token balances before/after execution

How to specify:
- Pre-approve exact amount or bounded allowance.
- Confirm balance sufficient for repayment even under slippage.

## E. Parameters Commonly Forgotten
- Correct token decimals conversion.
- Chain mismatch (mainnet addresses on testnet).
- Native vs ERC20 repayment branch selection.
- Bytes encoding errors in `callData`.
- Min-profit threshold set too high causing false reverts.

## F. Parameter Input Style in Remix

For struct/array function inputs:
- Use Remix tuple formatting exactly as shown in generated UI.
- For `bytes`, always prefix with `0x`.
- For addresses, use full `0x` 20-byte address.
- For uint values, enter integer base units only.

## G. Minimum Parameter Set for First Working Executor Version

Required:
1. `loanCurrency`
2. `loanAmount`
3. `steps[]` (`target`, `value`, `callData`)
4. `minReturnOrProfit`
5. `profitReceiver`

Optional but recommended:
6. `deadline`
7. `executorNonce`
8. `allowedTargets` policy config
