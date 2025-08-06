// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IERC20
 * @dev Interface for the ERC20 standard.
 */
interface IERC20 {
    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     * @param to The address of the recipient.
     * @param amount The amount of tokens to transfer.
     * @return A boolean value indicating whether the operation succeeded.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     * @param from The address of the source account.
     * @param to The address of the recipient.
     * @param amount The amount of tokens to transfer.
     * @return A boolean value indicating whether the operation succeeded.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     * @param account The address of the account to query.
     * @return The balance of the account.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through `transferFrom`.
     * @param owner The address of the account that owns the tokens.
     * @param spender The address of the account that will spend the tokens.
     * @return The amount of tokens still available for the spender.
     */
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}