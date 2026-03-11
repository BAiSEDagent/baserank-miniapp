// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for TierMarket consumed by BatchClaimer.
interface ITierMarket {
    function claim() external;
    function claimable(address user) external view returns (uint256);
}

/// @title BatchClaimer
/// @notice Stateless UX helper that iterates TierMarket.claim() for msg.sender.
///
/// @dev Design constraints:
///  - Holds NO funds; all USDC transfers happen inside each TierMarket.
///  - Best-effort: a failed claim on one market emits ClaimFailed and continues.
///  - Per-market success emits ClaimSucceeded so subgraphs/frontends see exact outcomes.
///  - Frontend SHOULD pre-filter markets using claimable() before calling claimMany().
///  - No state; no owner; no upgradability needed. Deploy once, use forever.
contract BatchClaimer {

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted for each market where claim() succeeded.
    event ClaimSucceeded(address indexed user, address indexed market);

    /// @notice Emitted for each market where claim() reverted.
    ///         `reason` is the raw revert bytes returned by the failed call.
    event ClaimFailed(address indexed user, address indexed market, bytes reason);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error EmptyMarketList();

    // -------------------------------------------------------------------------
    // Core
    // -------------------------------------------------------------------------

    /// @notice Attempt to claim on each market in the list on behalf of msg.sender.
    ///         Best-effort: individual failures do not revert the whole batch.
    ///         Emits ClaimSucceeded or ClaimFailed for every market in the list.
    ///
    /// @param markets  Array of TierMarket addresses to claim from.
    ///                 Frontend should pre-filter to markets where claimable(user) > 0
    ///                 to avoid needless ClaimFailed events.
    function claimMany(address[] calldata markets) external {
        if (markets.length == 0) revert EmptyMarketList();

        for (uint256 i = 0; i < markets.length; ) {
            address market = markets[i];
            // Low-level call so a revert in one market doesn't bubble up
            (bool success, bytes memory returnData) = market.call(
                abi.encodeCall(ITierMarket.claim, ())
            );
            if (success) {
                emit ClaimSucceeded(msg.sender, market);
            } else {
                emit ClaimFailed(msg.sender, market, returnData);
            }
            unchecked { ++i; }
        }
    }

    // -------------------------------------------------------------------------
    // View helper — frontend pre-filter
    // -------------------------------------------------------------------------

    /// @notice Returns the claimable amount for `user` on each market.
    ///         Use this to filter `markets` before passing to claimMany().
    ///         Returns 0 for any market that reverts on claimable().
    function previewMany(address[] calldata markets, address user)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](markets.length);
        for (uint256 i = 0; i < markets.length; ) {
            (bool ok, bytes memory data) = markets[i].staticcall(
                abi.encodeCall(ITierMarket.claimable, (user))
            );
            if (ok && data.length == 32) {
                amounts[i] = abi.decode(data, (uint256));
            }
            // if call fails, amounts[i] stays 0 (safe default)
            unchecked { ++i; }
        }
    }
}
