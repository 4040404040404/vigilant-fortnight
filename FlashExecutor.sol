// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap V4 PoolManager on Ethereum mainnet
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

// Sqrt price limits used when no explicit limit is desired
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

// ---------------------------------------------------------------------------
// Types & libraries (inlined so the file is self-contained)
// ---------------------------------------------------------------------------

/// @dev address wrapper – address(0) represents native ETH
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency c) internal pure returns (address) {
        return Currency.unwrap(c);
    }

    function isNative(Currency c) internal pure returns (bool) {
        return Currency.unwrap(c) == address(0);
    }
}

using CurrencyLibrary for Currency;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Packed int256: high 128 bits = amount0, low 128 bits = amount1
type BalanceDelta is int256;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(d) >> 128));
    }

    function amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(BalanceDelta.unwrap(d));
    }
}

using BalanceDeltaLibrary for BalanceDelta;

// ---------------------------------------------------------------------------
// Interfaces
// ---------------------------------------------------------------------------

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta);
    function settle(Currency currency) external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

// ---------------------------------------------------------------------------
// Reentrancy guard (minimal, no external dependency)
// ---------------------------------------------------------------------------

abstract contract ReentrancyGuard {
    uint256 private _status = 1; // 1 = not entered

    modifier nonReentrant() {
        require(_status == 1, "ReentrancyGuard: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

// ---------------------------------------------------------------------------
// FlashExecutor
// ---------------------------------------------------------------------------

/// @title  FlashExecutor
/// @notice Combines Uniswap V4 flash loans (2.sol) with V4 swaps (1.sol) into
///         a single, caller-driven executor.
///
/// How it works
/// ─────────────
/// 1. The caller invokes `execute(...)` with:
///      • the token to flash-borrow and the amount
///      • an ordered list of `SwapStep` instructions
///      • a minimum profit expectation (in the borrowed currency)
///
/// 2. `execute` calls `poolManager.unlock`, which triggers `unlockCallback`.
///
/// 3. Inside the callback (all within one atomic transaction):
///      a. `take`  – borrow the requested amount from the pool (creates debt)
///      b. For each SwapStep, execute a V4 swap via `poolManager.swap`
///         – settle input & take output using flash accounting
///      c. After all swaps the executor holds the final output token in its
///         balance (inside the PoolManager's accounting).
///      d. `settle` – repay the original flash loan debt.
///      e. Any surplus above the loan amount is swept to `recipient`.
///
/// 4. If the final balance after repayment is less than `minProfit`, the whole
///    transaction reverts.
///
/// Notes
/// ─────
/// • V4 flash loans are fee-free (flash accounting).
/// • All swaps are exact-input (amountSpecified negative).
/// • The caller must ensure the swap path converts the borrowed token back to
///   the borrowed token (or that the intermediate outputs are sufficient to
///   settle the debt).
/// • No admin keys, no upgradability – pure executor.
contract FlashExecutor is IUnlockCallback, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotPoolManager();
    error InsufficientProfit(uint256 got, uint256 minimum);
    error SwapOutputTooLow(uint256 step, uint256 got, uint256 minimum);
    error TransferFailed();

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IPoolManager public immutable poolManager;

    // -----------------------------------------------------------------------
    // Data structures
    // -----------------------------------------------------------------------

    /// @notice A single swap hop inside the flash loan callback
    struct SwapStep {
        PoolKey key;          // which V4 pool to use
        bool    zeroForOne;   // swap direction
        uint128 amountIn;     // exact input amount for this hop
        uint128 minAmountOut; // revert if output falls below this
    }

    /// @dev Internal bundle passed through poolManager.unlock → unlockCallback
    struct CallbackParams {
        Currency    flashCurrency; // token to flash-borrow
        uint256     flashAmount;   // amount to borrow
        SwapStep[]  steps;         // ordered swap instructions
        uint256     minProfit;     // minimum profit (in flashCurrency) for caller
        address     recipient;     // where surplus is sent
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor() {
        poolManager = IPoolManager(POOL_MANAGER);
    }

    // -----------------------------------------------------------------------
    // External entry point
    // -----------------------------------------------------------------------

    /// @notice Execute a flash-loan-powered arbitrary swap sequence.
    /// @param flashCurrency  Token (or ETH) to borrow.  Use address(0) for ETH.
    /// @param flashAmount    Amount to borrow.
    /// @param steps          Ordered list of V4 swap hops to execute.
    /// @param minProfit      Minimum amount of `flashCurrency` profit required
    ///                       after repaying the loan.  Reverts if not met.
    /// @param recipient      Address that receives the profit.
    function execute(
        Currency   flashCurrency,
        uint256    flashAmount,
        SwapStep[] calldata steps,
        uint256    minProfit,
        address    recipient
    ) external nonReentrant {
        bytes memory data = abi.encode(
            CallbackParams({
                flashCurrency: flashCurrency,
                flashAmount:   flashAmount,
                steps:         steps,
                minProfit:     minProfit,
                recipient:     recipient
            })
        );

        poolManager.unlock(data);
    }

    // -----------------------------------------------------------------------
    // IUnlockCallback
    // -----------------------------------------------------------------------

    /// @notice Called by PoolManager inside the unlock context.
    /// @dev    All V4 operations (take / swap / settle) MUST happen here.
    function unlockCallback(bytes calldata rawData)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        CallbackParams memory p = abi.decode(rawData, (CallbackParams));

        // ── Step 1: Flash-borrow the requested tokens ─────────────────────
        // Creates a positive delta (pool owes us) that we must settle later.
        poolManager.take(p.flashCurrency, address(this), p.flashAmount);

        // ── Step 2: Execute each swap hop ─────────────────────────────────
        for (uint256 i = 0; i < p.steps.length; i++) {
            _executeSwapStep(p.steps[i], i);
        }

        // ── Step 3: Repay the flash loan ──────────────────────────────────
        // Transfer the borrowed amount back to PoolManager and settle the debt.
        _repay(p.flashCurrency, p.flashAmount);

        // ── Step 4: Sweep profit to recipient ─────────────────────────────
        uint256 profit = _sweep(p.flashCurrency, p.minProfit, p.recipient);

        return abi.encode(profit);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Execute one swap step using V4's poolManager.swap (from 1.sol).
    function _executeSwapStep(SwapStep memory step, uint256 stepIndex) internal {
        BalanceDelta delta = poolManager.swap(
            step.key,
            IPoolManager.SwapParams({
                zeroForOne:        step.zeroForOne,
                amountSpecified:   -int256(uint256(step.amountIn)),
                sqrtPriceLimitX96: step.zeroForOne
                    ? MIN_SQRT_PRICE + 1
                    : MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        // Settle input: pay the pool for the tokens it gave us
        Currency inputCurrency = step.zeroForOne
            ? step.key.currency0
            : step.key.currency1;

        _settleFromContract(inputCurrency, step.amountIn);

        // Take output: receive the tokens the pool owes us
        Currency outputCurrency = step.zeroForOne
            ? step.key.currency1
            : step.key.currency0;

        int128 rawOut = step.zeroForOne
            ? delta.amount1()
            : delta.amount0();

        // Output delta must be positive (pool owes us tokens)
        require(rawOut > 0, "FlashExecutor: non-positive swap output");
        uint256 amountOut = uint256(int256(rawOut));

        if (amountOut < step.minAmountOut) {
            revert SwapOutputTooLow(stepIndex, amountOut, step.minAmountOut);
        }

        poolManager.take(outputCurrency, address(this), amountOut);
    }

    /// @dev Transfer `amount` of `currency` to poolManager and call settle.
    function _settleFromContract(Currency currency, uint256 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}(currency);
        } else {
            bool ok = IERC20(currency.unwrap()).transfer(address(poolManager), amount);
            if (!ok) revert TransferFailed();
            poolManager.settle(currency);
        }
    }

    /// @dev Repay the original flash loan (exact amount borrowed).
    function _repay(Currency currency, uint256 amount) internal {
        _settleFromContract(currency, amount);
    }

    /// @dev After repayment, any remaining balance in this contract is profit.
    ///      Revert if profit < minProfit; otherwise transfer to recipient.
    function _sweep(
        Currency currency,
        uint256  minProfit,
        address  recipient
    ) internal returns (uint256 profit) {
        if (currency.isNative()) {
            profit = address(this).balance;
        } else {
            profit = IERC20(currency.unwrap()).balanceOf(address(this));
        }

        if (profit < minProfit) revert InsufficientProfit(profit, minProfit);

        if (profit > 0) {
            if (currency.isNative()) {
                // Reentrancy is already guarded by nonReentrant on execute()
                (bool sent,) = recipient.call{value: profit}("");
                if (!sent) revert TransferFailed();
            } else {
                bool ok = IERC20(currency.unwrap()).transfer(recipient, profit);
                if (!ok) revert TransferFailed();
            }
        }
    }

    // -----------------------------------------------------------------------
    // Receive ETH
    // -----------------------------------------------------------------------

    receive() external payable {}
}
