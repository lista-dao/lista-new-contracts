// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/slisXAUE/SlisXAUE.sol";
import "../../src/slisXAUE/XAUTStaking.sol";
import "../../src/slisXAUE/XAUEAdapter.sol";

import "./mocks/MockXAUT.sol";
import "./mocks/MockXAUEOracle.sol";
import "./mocks/MockXAUEFundToken.sol";

contract SlisXAUETest is Test {
  // System under test
  SlisXAUE slisXAUE;
  XAUTStaking staking;
  XAUEAdapter adapter;

  // External mocks
  MockXAUT xaut;
  MockXAUEOracle oracle;
  MockXAUEFundToken fundToken;

  // Actors
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address feeReceiver = makeAddr("feeReceiver");
  address alice = makeAddr("alice");
  address bob = makeAddr("bob");

  // Constants
  uint256 constant INITIAL_NAV = 1e15; // baseNetValue from XAUE: 1 XAUE ≈ 0.001 XAUT
  uint256 constant MINT_CAP = 15_000 * 1e18;
  uint256 constant FEE_RATE = 0.2e18; // 20%
  uint256 constant MIN_DEPOSIT = 1000;

  function setUp() public {
    // External XAUE Protocol mocks
    xaut = new MockXAUT();
    oracle = new MockXAUEOracle(INITIAL_NAV);
    fundToken = new MockXAUEFundToken(address(xaut), address(oracle));

    // Lista contracts
    SlisXAUE slisImpl = new SlisXAUE();
    XAUTStaking stakingImpl = new XAUTStaking();
    XAUEAdapter adapterImpl = new XAUEAdapter(address(xaut));

    slisXAUE = SlisXAUE(address(new ERC1967Proxy(address(slisImpl), "")));
    staking = XAUTStaking(address(new ERC1967Proxy(address(stakingImpl), "")));
    adapter = XAUEAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    slisXAUE.initialize(admin, address(staking), "Lista Staked XAUE", "slisXAUE");
    staking.initialize(admin, manager, pauser, address(xaut), address(slisXAUE), address(adapter), MINT_CAP);
    adapter.initialize(admin, manager, bot, address(staking), address(fundToken), address(oracle));

    // Adapter parameters
    vm.startPrank(manager);
    adapter.setFeeReceiver(feeReceiver);
    adapter.setFeeRate(FEE_RATE);
    staking.setMinDeposit(MIN_DEPOSIT);
    vm.stopPrank();

    // Whitelist adapter on XAUE
    fundToken.addToWhitelist(address(adapter));

    // Fund users with XAUT
    xaut.mint(alice, 1_000_000e6); // 1M XAUT
    xaut.mint(bob, 1_000_000e6);
  }

  // ─── Deposit ──────────────────────────────────────────────────────────────

  function test_deposit_first_uses_scale_ratio() public {
    // First deposit: 100 XAUT to 100 slisXAUE (1:1 human, ×1e12 wei)
    uint256 amount = 100e6; // 100 XAUT
    vm.startPrank(alice);
    xaut.approve(address(staking), amount);
    staking.deposit(amount, 0, alice);
    vm.stopPrank();

    assertEq(slisXAUE.balanceOf(alice), 100e18, "alice should hold 100 slisXAUE");
    assertEq(xaut.balanceOf(address(adapter)), amount, "XAUT should land on adapter");
  }

  function test_deposit_zero_amount_via_shares_path_reverts() public {
    // Audit finding C: with minDeposit=0 (default), an attacker passing (amount=0, shares=1)
    // and convertToAssets(1) flooring to 0 used to bypass min checks. Must now revert.
    vm.prank(manager);
    staking.setMinDeposit(0); // explicit: simulate the worst case

    vm.startPrank(alice);
    xaut.approve(address(staking), type(uint256).max);
    vm.expectRevert(bytes("amount is zero"));
    staking.deposit(0, 1, alice); // amount=0, shares=1 → converted amount = 0 → revert
    vm.stopPrank();
  }

  function test_requestWithdraw_zero_amount_via_shares_path_reverts() public {
    _deposit(alice, 100e6);

    // minWithdraw is 0 by default; even so, amount=0 must revert
    vm.prank(alice);
    vm.expectRevert(bytes("amount is zero"));
    staking.requestWithdraw(0, 1, alice); // shares=1 → convertToAssets→0 → revert
  }

  function test_deposit_below_min_reverts() public {
    vm.startPrank(alice);
    xaut.approve(address(staking), 999);
    vm.expectRevert(bytes("below min deposit"));
    staking.deposit(999, 0, alice);
    vm.stopPrank();
  }

  function test_deposit_exceeds_mintCap_reverts() public {
    // Set mintCap to 10 slisXAUE = 10e18 to at first deposit, 10 XAUT mints 10 slisXAUE
    vm.prank(manager);
    staking.setMintCap(10e18);

    vm.startPrank(alice);
    xaut.approve(address(staking), 11e6);
    vm.expectRevert(bytes("exceeds mint cap"));
    staking.deposit(11e6, 0, alice);
    vm.stopPrank();
  }

  // ─── convertToShares / convertToAssets ────────────────────────────────────

  function test_convert_round_trip_at_bootstrap() public view {
    uint256 amount = 50e6;
    uint256 shares = staking.convertToShares(amount);
    assertEq(shares, 50e18, "50 XAUT to 50 slisXAUE at bootstrap");
    assertEq(staking.convertToAssets(shares), amount, "round trip back to 50 XAUT");
  }

  function test_first_deposit_donation_attack_mitigated() public {
    // Attacker tries to inflate the price by depositing 1 wei XAUT + donating large XAUT.
    // With +1, +1 virtual shares/assets, the attack is blunted: the donation doesn't proportionally
    // shift the conversion rate for subsequent depositors.
    address attacker = makeAddr("attacker");
    xaut.mint(attacker, 1_000_000e6);

    // Bypass minDeposit gate so we can test the conversion math at low amounts
    vm.prank(manager);
    staking.setMinDeposit(0);

    vm.startPrank(attacker);
    xaut.approve(address(staking), 1);
    staking.deposit(1, 0, attacker); // attacker mints 1 wei XAUT = 1e12 wei slisXAUE
    // Donate 100k XAUT straight to adapter (try to manipulate rate)
    xaut.transfer(address(adapter), 100_000e6);
    vm.stopPrank();

    // Subsequent depositer (alice) should still get ~1 share per ~1 XAUT human, NOT lose to attacker
    // The +1, +1 means: shares = amount × 1e12 × (1e12 + 1) / (1 × 1e12 + 1) ≈ amount × 1e12
    // (The 100k donation went to adapter, not into userTotalAssetsScaled; it doesn't affect rate.)
    vm.startPrank(alice);
    xaut.approve(address(staking), 100e6);
    staking.deposit(100e6, 0, alice);
    vm.stopPrank();

    // Alice should hold close to 100 slisXAUE (not orders of magnitude less)
    assertGt(slisXAUE.balanceOf(alice), 99e18, "alice should still get ~100 slisXAUE");
  }

  // ─── requestWithdraw burns shares immediately ─────────────────────────────

  function test_requestWithdraw_below_minWithdraw_reverts() public {
    _deposit(alice, 100e6);

    vm.prank(manager);
    staking.setMinWithdraw(10e6); // 10 XAUT minimum

    vm.prank(alice);
    vm.expectRevert(bytes("below min withdraw"));
    staking.requestWithdraw(5e6, 0, alice); // 5 XAUT < 10 XAUT min
  }

  function test_requestWithdraw_burns_shares() public {
    _deposit(alice, 100e6);
    assertEq(slisXAUE.balanceOf(alice), 100e18);

    vm.prank(alice);
    staking.requestWithdraw(50e6, 0, alice);

    // shares burned at request
    assertEq(slisXAUE.balanceOf(alice), 50e18, "half shares burned");
    assertEq(slisXAUE.balanceOf(address(staking)), 0, "no shares parked at staking");

    XAUTStaking.WithdrawalRequest[] memory reqs = staking.getUserWithdrawalRequests(alice);
    assertEq(reqs.length, 1);
    assertEq(reqs[0].amount, 50e6);
  }

  // ─── Batch FIFO flow ──────────────────────────────────────────────────────

  function test_full_flow_deposit_request_finishWithdraw_claim() public {
    // Alice deposits 100 XAUT, requests 30 XAUT back
    _deposit(alice, 100e6);

    vm.prank(alice);
    staking.requestWithdraw(30e6, 0, alice);

    // Pre-claim: not yet claimable
    vm.prank(alice);
    vm.expectRevert(bytes("not claimable yet"));
    staking.claimWithdraw(alice, 0);

    // Simulate adapter delivering XAUT back (bypass actual XAUE flow — just push asset)
    // Mint XAUT to adapter and let it call finishEarnPoolWithdraw
    xaut.mint(address(adapter), 30e6);
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(30e6);

    // Batch should now be confirmed; alice can claim
    uint256 balBefore = xaut.balanceOf(alice);
    vm.prank(alice);
    staking.claimWithdraw(alice, 0);
    assertEq(xaut.balanceOf(alice) - balBefore, 30e6, "alice received 30 XAUT");

    // Request popped
    assertEq(staking.getUserWithdrawalRequests(alice).length, 0);
  }

  function test_batch_FIFO_partial_funding() public {
    // Alice requests 30 in batch 1; advance day; Bob requests 20 in batch 2.
    _deposit(alice, 100e6);
    _deposit(bob, 100e6);

    vm.prank(alice);
    staking.requestWithdraw(30e6, 0, alice);

    vm.warp(block.timestamp + 1 days);
    vm.prank(bob);
    staking.requestWithdraw(20e6, 0, bob);

    // Adapter delivers 20 XAUT — not enough to cover batch 1 (30), so neither confirms
    xaut.mint(address(adapter), 20e6);
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(20e6);

    vm.prank(alice);
    vm.expectRevert(bytes("not claimable yet"));
    staking.claimWithdraw(alice, 0);

    // Top up to fully cover batch 1
    xaut.mint(address(adapter), 10e6);
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(10e6);

    // Alice can now claim (batch 1 confirmed)
    vm.prank(alice);
    staking.claimWithdraw(alice, 0);

    // Bob still cannot (batch 2 needs 20 but quota = 0 again after batch 1 consumed)
    vm.prank(bob);
    vm.expectRevert(bytes("not claimable yet"));
    staking.claimWithdraw(bob, 0);
  }

  // ─── increaseTotalAssets jumps convertRate immediately ─────────────────────────────

  function test_increaseTotalAssets_jumps_rate() public {
    _deposit(alice, 100e6);
    uint256 rateBefore = staking.pricePerShare();

    // Simulate adapter pushing 10 XAUT of interest
    vm.prank(address(adapter));
    staking.increaseTotalAssets(10e6);

    uint256 rateAfter = staking.pricePerShare();
    assertGt(rateAfter, rateBefore, "rate should jump after increaseTotalAssets");

    // Alice's shares are now worth more XAUT
    uint256 aliceValue = staking.convertToAssets(slisXAUE.balanceOf(alice));
    assertApproxEqAbs(aliceValue, 110e6, 1, "alice's 100 slisXAUE now worth ~110 XAUT");
  }

  function test_increaseTotalAssets_only_adapter() public {
    vm.expectRevert(bytes("only adapter"));
    staking.increaseTotalAssets(10e6);
  }

  // ─── Adapter integration with mock XAUE ──────────────────────────────────

  function test_adapter_depositToVault_through_mockXAUE() public {
    _deposit(alice, 100e6);
    // Adapter now holds 100 XAUT from alice's deposit

    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Adapter should now hold XAUE shares (100 XAUT / NAV 1e15 = 1e5 XAUE)
    uint256 xaueShares = fundToken.balanceOf(address(adapter));
    assertEq(xaueShares, (100e6 * 1e30) / INITIAL_NAV, "adapter holds XAUE shares");
    assertEq(xaut.balanceOf(address(adapter)), 0, "all XAUT deposited");
  }

  function test_adapter_requestWithdrawFromVault_converts_xaut_to_shares() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Snapshot adapter's XAUE balance before request
    uint256 xaueBefore = fundToken.balanceOf(address(adapter));

    // Request 30 XAUT back. Adapter should convert via NAV: shares = ceil(30e6 × 1e30 / 1e15) = 30_000e18
    vm.prank(bot);
    adapter.requestWithdrawFromVault(30e6);

    // XAUE burns the shares immediately (adapter holds fewer now)
    uint256 xaueAfter = fundToken.balanceOf(address(adapter));
    uint256 expectedSharesBurned = (30e6 * 1e30) / INITIAL_NAV; // floor here because exactly divisible
    assertEq(xaueBefore - xaueAfter, expectedSharesBurned, "shares burned should match converted amount");
  }

  function test_adapter_requestWithdrawFromVault_zero_reverts() public {
    vm.prank(bot);
    vm.expectRevert(bytes("amount is zero"));
    adapter.requestWithdrawFromVault(0);
  }

  function test_adapter_requestWithdrawFromVault_below_xaue_minRedeem_reverts() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // At NAV=1e15, shareAmount = ceil(amount × 1e30 / 1e15) = amount × 1e15.
    // XAUE.minRedeemShares = 1e18 → assetAmount must produce >= 1e18 shares → assetAmount >= 1000 wei XAUT.
    // assetAmount = 999 → shareAmount = 999 × 1e15 < 1e18 → adapter's pre-check reverts.
    vm.prank(bot);
    vm.expectRevert(bytes("below xaue minRedeem"));
    adapter.requestWithdrawFromVault(999);
  }

  function test_adapter_profit_accrual_via_NAV_growth() public {
    _deposit(alice, 100e6);

    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Snapshot rate before NAV growth
    uint256 rateBefore = staking.pricePerShare();

    // NAV grows by 10% to adapter's XAUE shares now worth more XAUT
    oracle.setPrice((INITIAL_NAV * 110) / 100);

    // Trigger profit accrual
    vm.prank(bot);
    adapter.updateVaultAssets();

    // 80% of profit should be pushed to staking as interest (20% to fee)
    uint256 fee_accumulated = adapter.fee();
    uint256 expectedFee = (10e6 * FEE_RATE) / 1e18; // 20% of 10 XAUT = 2 XAUT
    assertEq(fee_accumulated, expectedFee, "fee = 20% of 10 XAUT profit");

    // Rate should have jumped (by ~80% of NAV growth)
    uint256 rateAfter = staking.pricePerShare();
    assertGt(rateAfter, rateBefore, "rate jumped");
  }

  // ─── B/H-01: deposit/requestWithdraw auto-sync NAV before pricing ─────────

  function test_deposit_auto_syncs_NAV_before_pricing() public {
    // Setup: alice already in the system, adapter has XAUE shares, NAV grew but BOT hasn't synced
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // NAV grows 5%; nobody has called updateVaultAssets yet → userTotalAssetsScaled is stale
    oracle.setPrice((INITIAL_NAV * 105) / 100);
    uint256 stalePricePerShare = staking.pricePerShare();

    // Mallory tries to front-run BOT by depositing 100 XAUT at stale rate
    address mallory = makeAddr("mallory");
    xaut.mint(mallory, 100e6);
    vm.startPrank(mallory);
    xaut.approve(address(staking), 100e6);
    staking.deposit(100e6, 0, mallory);
    vm.stopPrank();

    // After mallory's deposit, alice's value should reflect the FULL 5 XAUT profit (minus 20% fee)
    // — not be diluted by mallory. The sync triggered inside deposit() ran BEFORE convertToShares.
    uint256 aliceValueAfter = staking.convertToAssets(slisXAUE.balanceOf(alice));
    assertApproxEqAbs(
      aliceValueAfter,
      104e6, // 100 + 5 × 80% = 104
      10,
      "alice keeps her full upside; mallory could not front-run NAV sync"
    );

    // Mallory's deposit should be priced at the post-sync rate
    uint256 mallorySharesPerXAUT = (slisXAUE.balanceOf(mallory) * 1e6) / 100e6;
    uint256 staleSharesPerXAUT = (1e18 * 1e6) / stalePricePerShare;
    assertLt(mallorySharesPerXAUT, staleSharesPerXAUT, "mallory got fewer shares than the stale rate would have given");
  }

  function test_requestWithdraw_auto_syncs_NAV_before_pricing() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // NAV grows 5%, no manual sync
    oracle.setPrice((INITIAL_NAV * 105) / 100);

    // Alice immediately requests half her shares — should price at synced (current) rate, not stale
    vm.prank(alice);
    staking.requestWithdraw(0, 50e18, alice); // burn 50 slisXAUE

    // At synced rate: 50 slisXAUE × ~1.04 = ~52 XAUT locked
    XAUTStaking.WithdrawalRequest[] memory reqs = staking.getUserWithdrawalRequests(alice);
    assertEq(reqs.length, 1);
    assertApproxEqAbs(reqs[0].amount, 52e6, 10, "withdraw amount locked at synced (post-NAV-growth) rate");
  }

  function test_updateVaultAssets_now_permissionless() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    oracle.setPrice((INITIAL_NAV * 105) / 100);

    // Anyone can call (no role check) — it's idempotent and only updates state to current NAV
    address random = makeAddr("random");
    vm.prank(random);
    adapter.updateVaultAssets();

    assertGt(adapter.fee(), 0, "sync ran; fee accrued");
  }

  // ─── NAV decline: users bear the loss pro-rata ────────────────────────────

  function test_nav_decline_propagates_loss_to_users() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    uint256 rateBefore = staking.pricePerShare();

    // NAV drops 5% → adapter's XAUE worth ~95 XAUT instead of 100
    oracle.setPrice((INITIAL_NAV * 95) / 100);

    vm.prank(bot);
    adapter.updateVaultAssets();

    // No fee charged on loss (fee only on upside)
    assertEq(adapter.fee(), 0, "no fee on loss");

    // Rate dropped pro-rata
    uint256 rateAfter = staking.pricePerShare();
    assertLt(rateAfter, rateBefore, "rate decreased");

    // Alice's stake is now worth ~95 XAUT
    uint256 aliceValue = staking.convertToAssets(slisXAUE.balanceOf(alice));
    assertApproxEqAbs(aliceValue, 95e6, 1, "alice's stake worth ~95 XAUT after 5% NAV drop");
  }

  function test_nav_drop_then_recovery_users_bear_round_trip() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Up 10% → profit, fee charged
    oracle.setPrice((INITIAL_NAV * 110) / 100);
    vm.prank(bot);
    adapter.updateVaultAssets();
    uint256 feeAfterGain = adapter.fee();
    assertEq(feeAfterGain, 2e6, "fee = 20% of 10 XAUT gain");

    // Back down 10% → loss propagated to users; fee NOT clawed back
    oracle.setPrice(INITIAL_NAV);
    vm.prank(bot);
    adapter.updateVaultAssets();
    assertEq(adapter.fee(), feeAfterGain, "fee unchanged on loss");

    // Net effect: alice deposited 100, gained 8 (80% of 10), then lost 10 → 98 XAUT
    uint256 aliceValue = staking.convertToAssets(slisXAUE.balanceOf(alice));
    assertApproxEqAbs(aliceValue, 98e6, 1, "alice ends at ~98 XAUT (gain kept fee, loss fully borne)");
  }

  function test_nav_decline_above_max_delta_reverts() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // 11% NAV drop exceeds the 10% delta cap → revert (defends against oracle anomaly)
    oracle.setPrice((INITIAL_NAV * 89) / 100);

    vm.prank(bot);
    vm.expectRevert(bytes("delta exceeds max"));
    adapter.updateVaultAssets();
  }

  function test_nav_growth_above_max_delta_reverts() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // 11% NAV jump exceeds the 10% delta cap (symmetric upside protection)
    oracle.setPrice((INITIAL_NAV * 111) / 100);

    vm.prank(bot);
    vm.expectRevert(bytes("delta exceeds max"));
    adapter.updateVaultAssets();
  }

  function test_nav_growth_exactly_at_cap_succeeds() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // 10% growth — exactly at cap, should pass
    oracle.setPrice((INITIAL_NAV * 110) / 100);
    vm.prank(bot);
    adapter.updateVaultAssets();

    assertGt(adapter.fee(), 0, "fee accrued at exactly 10% growth");
  }

  function test_nav_decline_exactly_at_cap_succeeds() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // 10% drop — exactly at cap, should pass
    oracle.setPrice((INITIAL_NAV * 90) / 100);
    vm.prank(bot);
    adapter.updateVaultAssets();

    uint256 aliceValue = staking.convertToAssets(slisXAUE.balanceOf(alice));
    assertApproxEqAbs(aliceValue, 90e6, 1, "alice loses ~10% at exactly cap drop");
  }

  function test_decreaseTotalAssets_only_adapter() public {
    vm.expectRevert(bytes("only adapter"));
    staking.decreaseTotalAssets(1e6);
  }

  // ─── Pause behavior ───────────────────────────────────────────────────────

  function test_pause_blocks_deposit_and_request() public {
    vm.prank(pauser);
    staking.pause();

    vm.startPrank(alice);
    xaut.approve(address(staking), 100e6);
    vm.expectRevert();
    staking.deposit(100e6, 0, alice);
    vm.stopPrank();
  }

  function test_pause_blocks_claim() public {
    // RWAEarnPool behavior: claim is also paused (per design decision).
    _deposit(alice, 100e6);
    vm.prank(alice);
    staking.requestWithdraw(30e6, 0, alice);
    xaut.mint(address(adapter), 30e6);
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(30e6);

    vm.prank(pauser);
    staking.pause();

    vm.prank(alice);
    vm.expectRevert();
    staking.claimWithdraw(alice, 0);
  }

  // ─── SlisXAUE MINTER access control ──────────────────────────────────

  function test_only_minter_can_mint() public {
    vm.expectRevert();
    slisXAUE.mint(alice, 1e18);
  }

  function test_only_minter_can_burn() public {
    _deposit(alice, 100e6);
    vm.expectRevert();
    slisXAUE.burn(alice, 1e18);
  }

  function test_slisXAUE_transferable() public {
    _deposit(alice, 100e6);
    vm.prank(alice);
    slisXAUE.transfer(bob, 50e18);
    assertEq(slisXAUE.balanceOf(bob), 50e18);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  function _deposit(address user, uint256 amount) internal {
    vm.startPrank(user);
    xaut.approve(address(staking), amount);
    staking.deposit(amount, 0, user);
    vm.stopPrank();
  }
}
