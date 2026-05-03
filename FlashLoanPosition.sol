// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap V4 PoolManager on Ethereum mainnet
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Sqrt price limits for swaps (from 1.sol)
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE =
    1461446703485210103287273052203988822378723970342;

/// @notice Flash loan-funded leveraged position to capture positive slippage
/// @dev Executes atomically inside a single Uniswap V4 unlock callback:
///
///   1. Flash-borrow `flashAmount` of the input token (zero fee in V4).
///   2. Settle the flash loan + user margin into the PoolManager.
///   3. Open a leveraged position: swap `flashAmount + userAmount` input → output.
///      Any positive slippage (actual output > expected) is kept by the caller.
///   4. Repay the flash loan: reverse-swap exactly `flashAmount` of input back,
///      charging the minimum possible output tokens at current market price.
///   5. Deliver net output tokens (the leveraged position) to the caller.
///
/// All obligations are settled before unlockCallback returns, so the delta
/// is zero and the PoolManager accepts the transaction.
contract FlashLoanPosition is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error InsufficientOutput();

    constructor() {
        poolManager = IPoolManager(POOL_MANAGER);
    }

    /// @notice Open a leveraged position funded by a V4 flash loan
    /// @param key        Pool to trade in
    /// @param userAmount Caller's own input tokens (margin / collateral)
    /// @param flashAmount Additional input tokens to flash-borrow (sets leverage)
    /// @param minNetOutput Minimum net output the caller must receive (slippage guard)
    /// @param zeroForOne  Trade direction: true = currency0 → currency1
    /// @return netOutput  Output tokens delivered to the caller
    function openLeveragedPosition(
        PoolKey calldata key,
        uint256 userAmount,
        uint256 flashAmount,
        uint256 minNetOutput,
        bool zeroForOne
    ) external returns (uint256 netOutput) {
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        // Pull the caller's margin into this contract before entering the
        // unlock context so it is available for transfer inside the callback.
        bool pulled = IERC20(Currency.unwrap(inputCurrency)).transferFrom(
            msg.sender,
            address(this),
            userAmount
        );
        require(pulled, "FlashLoanPosition: transferFrom failed - check allowance and balance");

        bytes memory callbackData = abi.encode(
            PositionParams({
                key: key,
                userAmount: userAmount,
                flashAmount: flashAmount,
                minNetOutput: minNetOutput,
                zeroForOne: zeroForOne,
                sender: msg.sender
            })
        );

        bytes memory result = poolManager.unlock(callbackData);
        netOutput = abi.decode(result, (uint256));
    }

    /// @notice PoolManager callback — executes flash loan + swap + repayment atomically
    /// @dev Delta accounting summary (zeroForOne = true example):
    ///
    ///   take(currency0, flashAmount)               → owed[0] = +flashAmount
    ///   settle(currency0, flashAmount+userAmount)  → owed[0] = -userAmount   (credit)
    ///   swap fwd (currency0→currency1, -totalInput)→ owed[0] = +flashAmount, owed[1] = -amountOut
    ///   swap rev (currency1→currency0, +flashAmount) exact-out
    ///                                              → owed[0] = 0,            owed[1] = -amountOut+repayOutput
    ///   take(currency1, netOutput)                 → owed[0] = 0,            owed[1] = 0  ✓
    function unlockCallback(bytes calldata callbackData)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        PositionParams memory p = abi.decode(callbackData, (PositionParams));

        Currency inputCurrency  = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        Currency outputCurrency = p.zeroForOne ? p.key.currency1 : p.key.currency0;

        uint256 totalInput = p.flashAmount + p.userAmount;

        // ── 1. Flash-borrow input tokens (zero fee in V4) ────────────────────
        poolManager.take(inputCurrency, address(this), p.flashAmount);

        // ── 2. Settle totalInput to PoolManager ──────────────────────────────
        // Transfers the flash-borrowed tokens plus the user's margin in one step.
        // After settlement: delta[input] = -userAmount (credit carried forward).
        bool sent = IERC20(Currency.unwrap(inputCurrency)).transfer(
            address(poolManager),
            totalInput
        );
        require(sent, "FlashLoanPosition: transfer to PoolManager failed");
        poolManager.settle(inputCurrency);

        // ── 3. Open leveraged position: swap totalInput → output ─────────────
        // The forward swap creates delta[input] = +flashAmount (net flash-loan
        // debt still outstanding) and delta[output] = -amountOut (pool owes us).
        BalanceDelta openDelta = poolManager.swap(
            p.key,
            IPoolManager.SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(totalInput), // exact input
                sqrtPriceLimitX96: p.zeroForOne
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Gross output received from the forward swap.
        // Positive slippage → amountOut exceeds the "fair" quoted value.
        uint256 amountOut = p.zeroForOne
            ? uint256(int256(openDelta.amount1()))
            : uint256(int256(openDelta.amount0()));

        // ── 4. Repay flash loan via exact-output reverse swap ─────────────────
        // We buy back exactly flashAmount of input currency using output currency.
        // This zeroes delta[input] and charges only the minimum output required.
        BalanceDelta repayDelta = poolManager.swap(
            p.key,
            IPoolManager.SwapParams({
                zeroForOne: !p.zeroForOne,
                amountSpecified: int256(p.flashAmount), // exact output = flash loan amount
                sqrtPriceLimitX96: !p.zeroForOne
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Output tokens spent to recover exactly flashAmount of input.
        // (amount1 < 0 when !zeroForOne charges currency1; amount0 < 0 for zeroForOne)
        uint256 repayOutput = p.zeroForOne
            ? uint256(-int256(repayDelta.amount1()))
            : uint256(-int256(repayDelta.amount0()));

        // ── 5. Deliver net position to the caller ────────────────────────────
        // netOutput = gross output from the long swap minus repayment cost.
        // Positive slippage on the forward swap increases netOutput directly.
        // Guard against scenarios where repayment costs exceed gross output.
        require(amountOut >= repayOutput, "FlashLoanPosition: insufficient output to repay flash loan");
        uint256 netOutput = amountOut - repayOutput;
        if (netOutput < p.minNetOutput) revert InsufficientOutput();

        poolManager.take(outputCurrency, p.sender, netOutput);

        return abi.encode(netOutput);
    }

    struct PositionParams {
        PoolKey  key;
        uint256  userAmount;
        uint256  flashAmount;
        uint256  minNetOutput;
        bool     zeroForOne;
        address  sender;
    }
}

// ============ Types & Interfaces ============

// Currency is an address wrapper (address(0) = native ETH)
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}

using CurrencyLibrary for Currency;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24   fee;
    int24    tickSpacing;
    address  hooks;
}

/// @notice Balance delta returned from swap / modify-liquidity operations
/// @dev Upper 128 bits = amount0, lower 128 bits = amount1
///      Negative = caller owes pool, Positive = pool owes caller
type BalanceDelta is int256;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta) >> 128));
    }

    function amount1(BalanceDelta delta) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(delta)));
    }
}

using BalanceDeltaLibrary for BalanceDelta;

interface IPoolManager {
    struct SwapParams {
        bool    zeroForOne;
        int256  amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta);

    /// @dev settle() credits the PoolManager with any tokens transferred to it
    function settle(Currency currency) external payable returns (uint256);

    /// @dev take() sends `amount` of `currency` to `to` and records the debt
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount)
        external returns (bool);
    function transfer(address recipient, uint256 amount)
        external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}
