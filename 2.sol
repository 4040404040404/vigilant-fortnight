// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap V4 PoolManager on Ethereum mainnet
address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

/// @notice Flash executor users can interact with directly after deployment
/// @dev V4 flash loans are fee-free; this contract executes optional arbitrary logic then repays
contract FlashExecutor is IUnlockCallback {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error InvalidNativeValue();
    error InsufficientRepayment();
    error ExternalCallFailed();
    error ERC20TransferFailed();

    constructor() {
        poolManager = IPoolManager(POOL_MANAGER);
    }

    /// @notice Execute a flash loan with optional arbitrary call during callback
    /// @param token Token to borrow (address(0) for native ETH)
    /// @param amount Amount to borrow
    /// @param target Optional contract to call during flash execution
    /// @param targetValue Native ETH value to pass to target call
    /// @param callData Calldata for the optional target call
    function executeFlashLoan(
        address token,
        uint256 amount,
        address target,
        uint256 targetValue,
        bytes calldata callData
    ) external payable {
        if (token != address(0) && msg.value != 0) revert InvalidNativeValue();

        Currency currency = Currency.wrap(token);
        bytes memory callbackData = abi.encode(
            FlashParams({
                currency: currency,
                amount: amount,
                sender: msg.sender,
                target: target,
                targetValue: targetValue,
                callData: callData
            })
        );

        poolManager.unlock(callbackData);
    }

    /// @notice Compatibility wrapper with previous interface
    function flash(Currency currency, uint256 amount, bytes calldata data) external {
        bytes memory callbackData = abi.encode(
            FlashParams({
                currency: currency,
                amount: amount,
                sender: msg.sender,
                target: address(0),
                targetValue: 0,
                callData: data
            })
        );
        poolManager.unlock(callbackData);
    }

    /// @notice Callback from PoolManager
    function unlockCallback(bytes calldata callbackData)
        external
        override
        returns (bytes memory)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        FlashParams memory params = abi.decode(callbackData, (FlashParams));

        // Take tokens from the pool (creates a debt)
        poolManager.take(params.currency, address(this), params.amount);

        if (params.target != address(0)) {
            (bool success,) = params.target.call{value: params.targetValue}(params.callData);
            if (!success) revert ExternalCallFailed();
        }

        // For ERC20: transfer tokens to PoolManager, then settle
        if (!isNative(params.currency)) {
            address token = Currency.unwrap(params.currency);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < params.amount) revert InsufficientRepayment();

            _safeTransfer(token, address(poolManager), params.amount);
            poolManager.settle(params.currency);

            uint256 profit = IERC20(token).balanceOf(address(this));
            if (profit > 0) _safeTransfer(token, params.sender, profit);
        } else {
            // For native ETH: settle with value
            if (address(this).balance < params.amount) revert InsufficientRepayment();
            poolManager.settle{value: params.amount}(params.currency);

            uint256 profitNative = address(this).balance;
            if (profitNative > 0) {
                (bool sent,) = payable(params.sender).call{value: profitNative}("");
                if (!sent) revert ExternalCallFailed();
            }
        }

        return bytes("");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory result) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert ERC20TransferFailed();
        }
    }

    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }

    // Allow receiving ETH
    receive() external payable {}

    struct FlashParams {
        Currency currency;
        uint256 amount;
        address sender;
        address target;
        uint256 targetValue;
        bytes callData;
    }
}

// Currency is an address wrapper (address(0) = native ETH)
type Currency is address;

library CurrencyLibrary {
    function unwrap(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }
}

using CurrencyLibrary for Currency;

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function settle(Currency currency) external payable returns (uint256);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IERC20 {
    function transfer(address recipient, uint256 amount)
        external
        returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
