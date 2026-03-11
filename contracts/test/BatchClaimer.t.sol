// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BatchClaimer} from "../src/BatchClaimer.sol";

// ─────────────────────────────────────────────
// Mock TierMarket
// ─────────────────────────────────────────────

/// @dev Configurable mock: enforces msg.sender-keyed stakes like the real TierMarket.
///      claim() is preserved for direct-call tests; claimFor() is the batch path.
contract MockMarket {
    bool    public shouldRevert;
    bytes   public revertData;
    mapping(address => bool) public claimed;
    mapping(address => uint256) public stakes; // user => claimable amount

    event ClaimCalled(address indexed user);

    function setStake(address user, uint256 amount) external { stakes[user] = amount; }
    function setShouldRevert(bool v, bytes calldata data) external { shouldRevert = v; revertData = data; }

    // Legacy configure for revert-only tests (no stake needed)
    function configure(bool _shouldRevert, bytes calldata _revertData, uint256) external {
        shouldRevert = _shouldRevert;
        revertData   = _revertData;
    }

    function _doClaimFor(address user) internal {
        if (shouldRevert) {
            bytes memory data = revertData;
            assembly { revert(add(data, 32), mload(data)) }
        }
        require(stakes[user] > 0, "NothingToClaim");
        require(!claimed[user],   "AlreadyClaimed");
        claimed[user] = true;
        emit ClaimCalled(user);
    }

    /// @notice Direct claim — user is msg.sender
    function claim() external { _doClaimFor(msg.sender); }

    /// @notice Delegated claim — user is explicit arg (BatchClaimer path)
    function claimFor(address user) external { _doClaimFor(user); }

    function claimable(address user) external view returns (uint256) { return stakes[user]; }
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
        // Give alice stakes so claimFor(alice) succeeds
        m1.setStake(alice, 100e6);
        m2.setStake(alice, 50e6);

        address[] memory markets = new address[](2);
        markets[0] = address(m1);
        markets[1] = address(m2);

        vm.expectEmit(true, true, false, false);
        emit BatchClaimer.ClaimSucceeded(alice, address(m1));
        vm.expectEmit(true, true, false, false);
        emit BatchClaimer.ClaimSucceeded(alice, address(m2));

        vm.prank(alice);
        batcher.claimMany(markets);

        assertTrue(m1.claimed(alice));
        assertTrue(m2.claimed(alice));
    }

    // ─────────────────────────────────────────────
    // claimMany — one fails, others continue (best-effort)
    // ─────────────────────────────────────────────

    function test_claimMany_bestEffort_continuesAfterFailure() public {
        MockMarket good1 = new MockMarket();
        MockMarket bad   = new MockMarket();
        MockMarket good2 = new MockMarket();

        good1.setStake(alice, 100e6);
        good2.setStake(alice, 80e6);
        // bad has no stake for alice → will revert NothingToClaim
        bytes memory revertPayload = abi.encodeWithSignature("AlreadyClaimed()");
        bad.configure(true, revertPayload, 0);

        address[] memory markets = new address[](3);
        markets[0] = address(good1);
        markets[1] = address(bad);
        markets[2] = address(good2);

        vm.prank(alice);
        batcher.claimMany(markets);

        // good markets succeeded, bad market was skipped
        assertTrue(good1.claimed(alice));
        assertFalse(bad.claimed(alice));
        assertTrue(good2.claimed(alice));
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

        assertFalse(bad1.claimed(bob));
        assertFalse(bad2.claimed(bob));
    }

    // ─────────────────────────────────────────────
    // claimMany — single market success
    // ─────────────────────────────────────────────

    function test_claimMany_single_success() public {
        MockMarket m = new MockMarket();
        m.setStake(alice, 100e6);
        address[] memory markets = new address[](1);
        markets[0] = address(m);

        vm.prank(alice);
        batcher.claimMany(markets);

        assertTrue(m.claimed(alice));
    }

    // ─────────────────────────────────────────────
    // claimMany — claimFor(user) so funds go to user not BatchClaimer
    // ─────────────────────────────────────────────

    function test_claimMany_claimsForUser_notBatchClaimer() public {
        // BatchClaimer calls claimFor(alice), not claim().
        // Inside the market, user = alice, so alice's stake is found and alice is credited.
        // BatchClaimer itself has no stake and would fail if claim() were called instead.
        MockMarket m = new MockMarket();
        m.setStake(alice, 100e6);
        // Deliberately do NOT give BatchClaimer any stake
        // so if claim() (msg.sender path) were used, it would revert

        address[] memory markets = new address[](1);
        markets[0] = address(m);

        vm.prank(alice);
        batcher.claimMany(markets);

        // alice's claim recorded — not BatchClaimer's
        assertTrue(m.claimed(alice));
        assertFalse(m.claimed(address(batcher)));
    }

    // ─────────────────────────────────────────────
    // previewMany — normal
    // ─────────────────────────────────────────────

    function test_previewMany_returnsAmounts() public {
        MockMarket m1 = new MockMarket();
        MockMarket m2 = new MockMarket();
        m1.setStake(alice, 50e6);
        m2.setStake(alice, 100e6);

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
        good.setStake(alice, 75e6);

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
    // FR-1: no-code address emits ClaimFailed, not ClaimSucceeded
    // ─────────────────────────────────────────────

    function test_claimMany_noCodeAddress_emitsClaimFailed() public {
        // An EOA or undeployed address has no code; should not emit ClaimSucceeded
        address ghost = address(0xDEAD);
        assertEq(ghost.code.length, 0);

        address[] memory markets = new address[](1);
        markets[0] = ghost;

        vm.expectEmit(true, true, false, false);
        emit BatchClaimer.ClaimFailed(alice, ghost, abi.encodePacked("NoCode"));

        vm.prank(alice);
        batcher.claimMany(markets);
    }

    // ─────────────────────────────────────────────
    // BatchClaimer holds no funds
    // ─────────────────────────────────────────────

    function test_batchClaimer_holdsNoFunds() public view {
        // No receive/fallback; native balance is always 0
        assertEq(address(batcher).balance, 0);
    }
}
