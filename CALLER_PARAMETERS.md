# Caller Parameters (for `execute.js`)

This file lists every caller-configurable input needed by:
- `execute.js`
- `FlashExecutor.execute(...)`

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `RPC_URL` | Yes | JSON-RPC endpoint URL |
| `PRIVATE_KEY` | Yes | Signer private key used to send transaction |
| `EXECUTOR_ADDRESS` | Yes | Deployed `FlashExecutor` contract address |
| `EXECUTE_CONFIG_PATH` | Yes | Path to JSON config file for `execute()` parameters |
| `GAS_LIMIT` | No | Gas limit override |
| `VALUE` | No | Native ETH value (wei) sent with tx |
| `WAIT_CONFIRMATIONS` | No | Number of confirmations to wait (default: `1`) |

---

## `execute.config.json` schema

```json
{
  "flashCurrency": "0x...",
  "flashAmount": "0",
  "minProfit": "0",
  "recipient": "0x...",
  "steps": [
    {
      "key": {
        "currency0": "0x...",
        "currency1": "0x...",
        "fee": 500,
        "tickSpacing": 10,
        "hooks": "0x0000000000000000000000000000000000000000"
      },
      "zeroForOne": true,
      "amountIn": "0",
      "minAmountOut": "0"
    }
  ]
}
```

---

## Field-by-field requirements

### Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `flashCurrency` | `address` | Yes | Token to flash-borrow; can be zero address for native ETH |
| `flashAmount` | `uint256` string/integer | Yes | Amount to borrow in token base units |
| `minProfit` | `uint256` string/integer | Yes | Minimum profit threshold in `flashCurrency` units |
| `recipient` | `address` | Yes | Profit destination; must be valid non-zero address |
| `steps` | array | Yes | Ordered swap steps; must be non-empty |

### `steps[i]` fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | object | Yes | Uniswap V4 pool key |
| `zeroForOne` | `bool` | Yes | `true`: currency0→currency1, `false`: currency1→currency0 |
| `amountIn` | `uint128` string/integer | Yes | Exact input amount for this step |
| `minAmountOut` | `uint128` string/integer | Yes | Slippage floor for output |

### `steps[i].key` fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `currency0` | `address` | Yes | Lower-address token in pool |
| `currency1` | `address` | Yes | Higher-address token in pool |
| `fee` | `uint24` | Yes | Fee tier (e.g. 500, 3000, 10000) |
| `tickSpacing` | `int24` | Yes | Must match pool fee tier |
| `hooks` | `address` | Yes | Hook contract, or zero address if none |

---

## Caller responsibility checklist

- Provide a valid swap path that can repay the flash loan.
- Use raw integer amounts (no decimals/floats).
- Ensure each step’s `amountIn` and `minAmountOut` are precomputed off-chain.
- Set `minProfit` high enough to avoid non-profitable execution.
