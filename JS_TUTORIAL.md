# JavaScript Deployment + Execution Tutorial

This repository now includes:
- `deploy.js` (deploys `FlashExecutor`)
- `execute.js` (calls `execute()` with caller-provided config)

## 1) Prerequisites

- Node.js 18+
- An RPC endpoint
- Wallet private key with gas funds
- `ethers` package installed:

```bash
npm install ethers
```

## 2) Deploy `FlashExecutor.sol`

`FlashExecutor` has a zero-argument constructor.

### Option A: Deploy from artifact JSON
If you have an artifact with `abi` + `bytecode`:

```bash
export RPC_URL="https://your-rpc"
export PRIVATE_KEY="0x..."
export CONTRACT_ARTIFACT_PATH="./artifacts/FlashExecutor.json"
node /home/runner/work/vigilant-fortnight/vigilant-fortnight/deploy.js
```

### Option B: Deploy from ABI file + env bytecode

```bash
export RPC_URL="https://your-rpc"
export PRIVATE_KEY="0x..."
export FLASH_EXECUTOR_BYTECODE="0x6080..." # compiled bytecode
node /home/runner/work/vigilant-fortnight/vigilant-fortnight/deploy.js
```

Save the deployed address for execution:

```bash
export EXECUTOR_ADDRESS="0xYourDeployedExecutor"
```

## 3) Prepare execution config JSON

Create `execute.config.json`:

```json
{
  "flashCurrency": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  "flashAmount": "10000000000",
  "minProfit": "1000000",
  "recipient": "0xYourWalletAddress",
  "steps": [
    {
      "key": {
        "currency0": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "currency1": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "fee": 500,
        "tickSpacing": 10,
        "hooks": "0x0000000000000000000000000000000000000000"
      },
      "zeroForOne": true,
      "amountIn": "10000000000",
      "minAmountOut": "2900000000000000000"
    },
    {
      "key": {
        "currency0": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "currency1": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "fee": 3000,
        "tickSpacing": 60,
        "hooks": "0x0000000000000000000000000000000000000000"
      },
      "zeroForOne": false,
      "amountIn": "2900000000000000000",
      "minAmountOut": "10001000000"
    }
  ]
}
```

## 4) Execute (no bot, manual JS executor)

```bash
export RPC_URL="https://your-rpc"
export PRIVATE_KEY="0x..."
export EXECUTOR_ADDRESS="0xYourDeployedExecutor"
export EXECUTE_CONFIG_PATH="./execute.config.json"
node /home/runner/work/vigilant-fortnight/vigilant-fortnight/execute.js
```

Optional:
- `GAS_LIMIT` (integer)
- `VALUE` (wei, only if needed)
- `WAIT_CONFIRMATIONS` (default `1`)

## 5) Notes

- All amounts are raw token base units (wei-style integers).
- `steps` must be pre-computed off-chain by the caller.
- This setup is a one-shot executor script, not a bot.
