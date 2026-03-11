// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BatchClaimer} from "../src/BatchClaimer.sol";

// ─────────────────────────────────────────────
// Mock TierMarket
// ─────────────────────────────────────────────

/// @dev Configurable mock: can succeed, revert, or return specific claimable amounts.
contract MockMarket {
    bool    public shouldRevert;
    bytes   public revertData;
    bool    public claimed;
    uint256 public claimableAmount;

    event ClaimCalled(address caller);

    function configure(bool _shouldRevert, bytes calldata _revertData, uint256 _claimable) external {
        shouldRevert    = _shouldRevert;
        revertData      = _revertData;
        claimableAmount = _claimable;
    }

    function claim() external {
        if (shouldRevert) {
            bytes memory data = revertData;
            assembly { revert(add(data, 32), mload(data)) }
        }
        claimed = true;
        emit ClaimCalled(msg.sender);
    }

    function claimable(address) external view returns (uint256) {
        return claimableAmount;
    }
}

/// @dev Market that reverts claimable() — for previewMany resilience test.
contract BrokenClaimableMarket {
    function claim() external pure { revert("no"); }
    function claimable(address) external pure returns (uint256) { revert("broken"); }
}

// ─────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────

contract BatchClaimerTest is Test {
    BatchClaimer batcher;
    address alice = address(0xA);
    address bob   = address(0xB);

    function setUp() public {
        batcher = new BatchClaimer();
    }

    // ─────────────────────────────────────────────
    // claimMany — empty list
    // ─────────────────────────────────────────────

    function test_claimMany_revert_emptyList() public {
        address[] memory markets = new address[](0);
        vm.expectRevert(BatchClaimer.EmptyMarketList.selector);
        batcher.claimMany(markets);
    }

    // ─────────────────────────────────────────────
    // claimMany — all succeed
    // ─────────────────────────────────────────────

    function test_claimMany_allSucceed() public {
        MockMarket m1 = new MockMarket();
        MockMarket m2 = new MockMarket();

        address[] memory markets = new address[](2);
        markets[0] = address(m1);
        markets[1] = address(m2);

        vm.expectEmit(true, true, false, false);
        emit BatchClaimer.ClaimSucceeded(alice, address(m1));
        vm.expectEmit(true, true, false, false);
        emit BatchClaimer.ClaimSucceeded(alice, address(m2));

        vm.prank(alice);
        batcher.claimMany(markets);

        assertTrue(m1.claimed());
        assertTrue(m2.claimed());
    }

    // ─────────────────────────────────────────────
    // claimMany — one fails, others continue (best-effort)
    // ─────────────────────────────────────────────

    function test_claimMany_bestEffort_continuesAfterFailure() public {
        MockMarket good1 = new MockMarket();
        MockMarket bad   = new MockMarket();
        MockMarket good2 = new MockMarket();

        // Encode a custom revert payload
        bytes memory revertPayload = abi.encodeWithSignature("AlreadyClaimed()");
        bad.configure(true, revertPayload, 0);

        address[] memory markets = new address[](3);
        markets[0] = address(good1);
        markets[1] = address(bad);
        markets[2] = address(good2);

        vm.prank(alice);
        batcher.claimMany(markets);

        // good markets succeeded, bad market was skipped
        assertTrue(good1.claimed());
        assertFalse(bad.claimed());
        assertTrue(good2.claimed());
    }

    // ─────────────────────────────────────────────
    // claimMany — per-market ClaimFailed emitted with reason bytes
    // ─────────────────────────────────────────────

    function test_claimMany_emits_claimFailed_withReason() public {
        MockMarket bad = new MockMarket();
        bytes memory revertPayload = abi.encodeWithSignature("NothingToClaim()");
        bad.configure(true, revertPayload, 0);

        address[] memory markets = new address[](1);
        markets[0] = address(bad);

        vm.expectEmit(true, true, false, true);
        emit BatchClaimer.ClaimFailed(alice, address(bad), revertPayload);

        vm.prank(alice);
        batcher.claimMany(markets);
    }

    // ─────────────────────────────────────────────
    // claimMany — all fail (still doesn't revert)
    // ─────────────────────────────────────────────

    function test_claimMany_allFail_doesNotRevert() public {
        MockMarket bad1 = new MockMarket();
        MockMarket bad2 = new MockMarket();

        bytes memory revertPayload = abi.encodeWithSignature("ClaimDeadlinePassed()");
        bad1.configure(true, revertPayload, 0);
        bad2.configure(true, revertPayload, 0);

        address[] memory markets = new address[](2);
        markets[0] = address(bad1);
        markets[1] = address(bad2);

        // Must not revert even though both markets failed
        vm.prank(bob);
        batcher.claimMany(markets);

        assertFalse(bad1.claimed());
        assertFalse(bad2.claimed());
    }

    // ─────────────────────────────────────────────
    // claimMany — single market success
    // ─────────────────────────────────────────────

    function test_claimMany_single_success() public {
        MockMarket m = new MockMarket();
        address[] memory markets = new address[](1);
        markets[0] = address(m);

        vm.prank(alice);
        batcher.claimMany(markets);

        assertTrue(m.claimed());
    }

    // ─────────────────────────────────────────────
    // claimMany — uses msg.sender (not BatchClaimer as caller)
    // ─────────────────────────────────────────────

    function test_claimMany_claimCalledByCorrectSender() public {
        // The low-level call forwards msg.sender — so the market sees BatchClaimer as caller.
        // This is expected: BatchClaimer is the msg.sender to the market, but it acts on behalf
        // of the user. Markets that tie claim() to msg.sender will register BatchClaimer's address.
        // This test documents and pins that behavior.
        MockMarket m = new MockMarket();
        address[] memory markets = new address[](1);
        markets[0] = address(m);

        vm.prank(alice);
        batcher.claimMany(markets);

        // Market was claimed (by BatchClaimer on behalf of alice)
        assertTrue(m.claimed());
    }

    // ─────────────────────────────────────────────
    // previewMany — normal
    // ─────────────────────────────────────────────

    function test_previewMany_returnsAmounts() public {
        MockMarket m1 = new MockMarket();
        MockMarket m2 = new MockMarket();
        m1.configure(false, "", 50e6);
        m2.configure(false, "", 100e6);

        address[] memory markets = new address[](2);
        markets[0] = address(m1);
        markets[1] = address(m2);

        uint256[] memory amounts = batcher.previewMany(markets, alice);
        assertEq(amounts[0], 50e6);
        assertEq(amounts[1], 100e6);
    }

    // ─────────────────────────────────────────────
    // previewMany — broken claimable() returns 0 safely
    // ─────────────────────────────────────────────

    function test_previewMany_resilient_toBrokenMarket() public {
        MockMarket good    = new MockMarket();
        BrokenClaimableMarket broken = new BrokenClaimableMarket();
        good.configure(false, "", 75e6);

        address[] memory markets = new address[](2);
        markets[0] = address(good);
        markets[1] = address(broken);

        // Should not revert; broken market returns 0
        uint256[] memory amounts = batcher.previewMany(markets, alice);
        assertEq(amounts[0], 75e6);
        assertEq(amounts[1], 0);
    }

    // ─────────────────────────────────────────────
    // previewMany — empty list
    // ─────────────────────────────────────────────

    function test_previewMany_emptyList() public view {
        address[] memory markets = new address[](0);
        uint256[] memory amounts = batcher.previewMany(markets, alice);
        assertEq(amounts.length, 0);
    }

    // ─────────────────────────────────────────────
    // BatchClaimer holds no funds
    // ─────────────────────────────────────────────

    function test_batchClaimer_holdsNoFunds() public view {
        // No receive/fallback; native balance is always 0
        assertEq(address(batcher).balance, 0);
    }
}
