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
    adapter.initialize(
      admin,
      manager,
      bot,
      address(slisXAUE),
      address(fundToken),
      address(oracle),
      feeReceiver,
      FEE_RATE
    );
    vm.prank(manager);
    adapter.setStaking(address(staking));

    vm.prank(manager);
    staking.setMinDeposit(MIN_DEPOSIT);

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

  function test_deposit_shares_input_rounds_charged_amount_up() public {
    // LDS-05: when the user specifies `shares`, the charged XAUT must round UP so the depositor
    // never pays less than the fair value of the minted shares (rounding favours the pool).
    _deposit(alice, 100e6); // 100 XAUT -> 100e18 shares, userTotalAssetsScaled = 100e18

    // Push 3 XAUT interest so the share price becomes inexact (uta=103e18, supply=100e18).
    vm.prank(address(adapter));
    staking.increaseTotalAssets(3e6);

    uint256 wantShares = 1e18;
    uint256 floored = staking.convertToAssets(wantShares); // what the un-rounded (floor) charge would be
    // Precondition: at this rate the floored charge under-prices the shares, so the guard must fire.
    assertLt(staking.convertToShares(floored), wantShares, "precondition: floored charge under-prices shares");

    uint256 bobBefore = xaut.balanceOf(bob);
    vm.startPrank(bob);
    xaut.approve(address(staking), type(uint256).max);
    staking.deposit(0, wantShares, bob);
    vm.stopPrank();

    uint256 charged = bobBefore - xaut.balanceOf(bob);
    assertEq(charged, floored + 1, "charged amount must be rounded up by 1 wei");
    assertEq(slisXAUE.balanceOf(bob), wantShares, "bob receives exactly the requested shares");
    // Pool is protected: the rounded-up charge is now worth at least the minted shares.
    assertGe(staking.convertToShares(charged), wantShares, "rounded-up charge covers the shares");
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
    staking.claimWithdraw(0);

    // Run the full XAUE redemption flow (depositToVault → requestRedemption → approve → finish)
    _runRedemption(30e6);

    // Batch should now be confirmed; alice can claim
    uint256 balBefore = xaut.balanceOf(alice);
    vm.prank(alice);
    staking.claimWithdraw(0);
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

    // Adapter redeems 20 XAUT — not enough to cover batch 1 (30), so neither confirms
    _runRedemption(20e6);

    vm.prank(alice);
    vm.expectRevert(bytes("not claimable yet"));
    staking.claimWithdraw(0);

    // Top up to fully cover batch 1
    _runRedemption(10e6);

    // Alice can now claim (batch 1 confirmed)
    vm.prank(alice);
    staking.claimWithdraw(0);

    // Bob still cannot (batch 2 needs 20 but quota = 0 again after batch 1 consumed)
    vm.prank(bob);
    vm.expectRevert(bytes("not claimable yet"));
    staking.claimWithdraw(0);
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

  function test_depositToVault_below_xaue_minDeposit_reverts() public {
    // Mirror of the min-redeem pre-check: a sub-floor assetAmount must revert at the adapter
    // boundary with a local message, not deep inside XAUE.mint(). (Bailsec 25)
    uint256 floor = fundToken.minDepositAmount();
    vm.prank(bot);
    vm.expectRevert(bytes("below xaue minDeposit"));
    adapter.depositToVault(floor - 1);
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

  // ─── NAV decline impossible: loss path removed (Bailsec 03/04/28) ────────────────────────────

  function test_nav_decline_reverts_fail_closed() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // XAUE NAV cannot decrease in production (CoboFundOracle ratchets up). A drop is treated as an
    // oracle anomaly: the sync fails closed instead of socialising a phantom loss. (Bailsec 03/04/28)
    oracle.setPrice((INITIAL_NAV * 95) / 100);

    vm.prank(bot);
    vm.expectRevert(bytes("vault value decreased"));
    adapter.updateVaultAssets();
  }

  function test_nav_decline_reverts_even_after_gain() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Up 10% -> profit booked
    oracle.setPrice((INITIAL_NAV * 110) / 100);
    vm.prank(bot);
    adapter.updateVaultAssets();
    assertEq(adapter.fee(), 2e6, "fee = 20% of 10 XAUT gain");

    // Any subsequent decline (even back toward the entry NAV) fails closed -- fee is never clawed
    // back and no loss is propagated, because the product cannot incur a NAV loss.
    oracle.setPrice(INITIAL_NAV);
    vm.prank(bot);
    vm.expectRevert(bytes("vault value decreased"));
    adapter.updateVaultAssets();
  }

  function test_nav_decline_blocks_deposit_sync_fail_closed() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // A decline freezes user flows too, since deposit/requestWithdraw sync NAV first.
    oracle.setPrice((INITIAL_NAV * 95) / 100);

    address bob = makeAddr("bobDecline");
    xaut.mint(bob, 10e6);
    vm.startPrank(bob);
    xaut.approve(address(staking), 10e6);
    vm.expectRevert(bytes("vault value decreased"));
    staking.deposit(10e6, 0, bob);
    vm.stopPrank();
  }

  function test_setFeeRate_settles_pending_gain_at_old_rate() public {
    // Bailsec 15: changing feeRate must not retroactively tax the un-synced gain. setFeeRate syncs
    // at the OLD rate first, so the pending gain books at 20% and only future gain uses the new rate.
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    oracle.setPrice((INITIAL_NAV * 105) / 100); // +5% NAV, left UN-synced
    assertEq(adapter.fee(), 0, "no fee booked yet");

    vm.prank(manager);
    adapter.setFeeRate(0.3e18); // 20% -> 30%

    assertEq(adapter.fee(), 1e6, "pending 5 XAUT gain taxed at OLD 20% (no hindsight)");
    assertEq(adapter.feeRate(), 0.3e18, "new rate set");
    assertEq(adapter.lastVaultTotalAssets(), 105e6, "synced before switch");
  }

  function test_setMaxDeltaBps_lowering_settles_first_no_freeze() public {
    // Bailsec 18: lowering the cap below an un-synced in-cap delta must not freeze the next sync.
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    oracle.setPrice((INITIAL_NAV * 105) / 100); // +5% (within old 10% cap), un-synced

    vm.prank(manager);
    adapter.setMaxDeltaBps(100); // 10% -> 1%; settles the 5% under the old cap first
    assertEq(adapter.maxDeltaBps(), 100, "cap lowered");
    assertEq(adapter.lastVaultTotalAssets(), 105e6, "pending delta settled under old cap");

    adapter.updateVaultAssets(); // NAV unchanged -> no delta -> must NOT revert
    assertEq(adapter.lastVaultTotalAssets(), 105e6, "no freeze");
  }

  function test_setMaxDeltaBps_raising_does_not_settle_first_clears_backlog() public {
    // Bailsec 18 / decision A: RAISING must NOT sync first, so MANAGER can raise the cap to clear a
    // backlog whose delta exceeds the current cap (the 08/12 operational lever).
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    vm.prank(manager);
    adapter.setMaxDeltaBps(100); // tighten to 1% (NAV unchanged: settle is a no-op)

    oracle.setPrice((INITIAL_NAV * 102) / 100); // +2% > 1% cap -> backlog
    vm.expectRevert(bytes("delta exceeds max"));
    adapter.updateVaultAssets();

    vm.prank(manager);
    adapter.setMaxDeltaBps(1000); // raise to 10% WITHOUT a pre-sync (else it would deadlock)
    assertEq(adapter.maxDeltaBps(), 1000, "cap raised despite pending backlog");

    adapter.updateVaultAssets(); // now clears under the new cap
    assertEq(adapter.lastVaultTotalAssets(), 102e6, "backlog cleared");
  }

  function test_setXAUEOracle_rebaselines_no_misbooked_interest() public {
    // Bailsec 16: MANAGER can repoint the adapter's oracle (e.g. XAUE migrates its oracle). The swap
    // settles under the old oracle, then re-baselines against the new one, so a different pricing
    // basis is absorbed (not mis-booked as interest/loss); real post-swap gains still book normally.
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);
    uint256 feeBefore = adapter.fee();

    // New oracle reads a different NAV basis for the SAME shares.
    MockXAUEOracle newOracle = new MockXAUEOracle((INITIAL_NAV * 150) / 100);
    vm.prank(manager);
    adapter.setXAUEOracle(address(newOracle));

    assertEq(adapter.xaueOracle(), address(newOracle), "oracle repointed");
    assertEq(adapter.fee(), feeBefore, "cross-oracle basis NOT booked as interest/fee");
    assertEq(adapter.lastVaultTotalAssets(), adapter.getVaultTotalAssets(), "re-baselined to new oracle");
    assertEq(adapter.lastVaultTotalAssets(), 150e6, "= expectedShareBalance * newNav");

    // A real gain under the NEW oracle books normally.
    newOracle.setPrice((INITIAL_NAV * 153) / 100); // 150 -> 153 (+2% on the new basis)
    adapter.updateVaultAssets();
    assertGt(adapter.fee(), feeBefore, "real gain under new oracle books as interest");

    // Only MANAGER can repoint.
    vm.prank(bot);
    vm.expectRevert();
    adapter.setXAUEOracle(address(oracle));
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

  function test_nav_growth_exactly_at_cap_decline_path_removed() public {
    // The matching "decline exactly at cap succeeds" case is gone: declines now always revert
    // (loss path removed). The only at-cap behaviour that remains is the upside, covered above.
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    oracle.setPrice((INITIAL_NAV * 90) / 100); // -10%, in cap, but loss path is gone
    vm.prank(bot);
    vm.expectRevert(bytes("vault value decreased"));
    adapter.updateVaultAssets();
  }

  function test_getUserWithdrawalRequests_pagination() public {
    _deposit(alice, 100e6);
    vm.startPrank(alice);
    staking.requestWithdraw(10e6, 0, alice);
    staking.requestWithdraw(20e6, 0, alice);
    staking.requestWithdraw(30e6, 0, alice);
    vm.stopPrank();

    assertEq(staking.getUserWithdrawalRequestCount(alice), 3, "3 outstanding requests");
    assertEq(staking.getUserWithdrawalRequests(alice).length, 3, "full getter returns all");

    // Page [1, 3) -> indices 1 and 2.
    XAUTStaking.WithdrawalRequest[] memory page = staking.getUserWithdrawalRequests(alice, 1, 3);
    assertEq(page.length, 2, "page [1,3) has 2");
    assertEq(page[0].amount, 20e6, "page[0] == request #1");
    assertEq(page[1].amount, 30e6, "page[1] == request #2");

    // end clamped beyond length.
    XAUTStaking.WithdrawalRequest[] memory clamped = staking.getUserWithdrawalRequests(alice, 2, 999);
    assertEq(clamped.length, 1, "clamped to length");
    assertEq(clamped[0].amount, 30e6, "last entry");

    // start >= end -> empty.
    assertEq(staking.getUserWithdrawalRequests(alice, 3, 3).length, 0, "empty page");
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
    _runRedemption(30e6);

    vm.prank(pauser);
    staking.pause();

    vm.prank(alice);
    vm.expectRevert();
    staking.claimWithdraw(0);
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

  // ─── Reject handling + expectedShareBalance invariant ─────────────────────

  function test_expectedShareBalance_tracks_deposit_and_request() public {
    _deposit(alice, 100e6);

    // Before BOT acts: adapter holds idle XAUT, no XAUE shares; expectedShareBalance = 0
    assertEq(adapter.expectedShareBalance(), 0);

    vm.prank(bot);
    adapter.depositToVault(100e6);

    uint256 sharesHeld = fundToken.balanceOf(address(adapter));
    assertGt(sharesHeld, 0, "shares minted");
    assertEq(adapter.expectedShareBalance(), sharesHeld, "expected matches actual after deposit");

    // Initiate a redemption — expectedShareBalance drops by shareAmount; XAUE owns the per-request state
    uint256 reqId = fundToken.redemptionsLength();
    vm.prank(bot);
    adapter.requestWithdrawFromVault(30e6);
    (, , uint256 assetAmount, uint256 shareAmount, , ) = fundToken.redemptions(reqId);
    assertEq(adapter.expectedShareBalance(), fundToken.balanceOf(address(adapter)), "still matches after request");

    // Approve + forward
    fundToken.approveRedemption(reqId, address(adapter), assetAmount, shareAmount);
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(assetAmount);
    assertEq(xaut.balanceOf(address(staking)), assetAmount, "XAUT forwarded to staking");
  }

  function test_reject_does_not_block_paths_until_acknowledge() public {
    _deposit(alice, 100e6);
    (uint256 reqId, uint256 shareAmount, uint256 assetAmount) = _initiateRedemption(30e6);

    // XAUE rejects → shares come back to adapter, expectedShareBalance unchanged
    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, shareAmount);
    assertGt(fundToken.balanceOf(address(adapter)), adapter.expectedShareBalance(), "share balance drifted");

    // updateVaultAssets keeps working during the reject window (>= check tolerates extras)
    adapter.updateVaultAssets();

    // User paths also stay open
    vm.startPrank(bob);
    xaut.approve(address(staking), 10e6);
    staking.deposit(10e6, 0, bob);
    vm.stopPrank();

    // MANAGER acknowledges — extras absorbed into accounting at current NAV
    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
    assertEq(adapter.expectedShareBalance(), fundToken.balanceOf(address(adapter)));

    // Continues to pass
    adapter.updateVaultAssets();
  }

  function test_acknowledgeReject_pending_reqId_reverts() public {
    // Pending status (not yet approved or rejected) → status check fires first.
    _deposit(alice, 100e6);
    (uint256 reqId, , ) = _initiateRedemption(30e6);

    vm.prank(bot);
    vm.expectRevert(bytes("not rejected"));
    adapter.acknowledgeReject(reqId);
  }

  function test_acknowledgeReject_already_executed_reverts() public {
    // Executed status → status check fires.
    _deposit(alice, 100e6);
    (uint256 reqId, uint256 shareAmount, uint256 assetAmount) = _initiateRedemption(30e6);
    fundToken.approveRedemption(reqId, address(adapter), assetAmount, shareAmount);

    vm.prank(bot);
    vm.expectRevert(bytes("not rejected"));
    adapter.acknowledgeReject(reqId);
  }

  function test_acknowledgeReject_multiple_rejects_any_order() public {
    // Two pending redemptions, both rejected. MANAGER can ack them in any order; with the
    // relaxed >= balance check, updateVaultAssets keeps working throughout.
    _deposit(alice, 200e6);
    (uint256 reqId1, uint256 shareAmount1, uint256 assetAmount1) = _initiateRedemption(30e6);
    (uint256 reqId2, uint256 shareAmount2, uint256 assetAmount2) = _initiateRedemption(20e6);

    fundToken.rejectRedemption(reqId1, address(adapter), assetAmount1, shareAmount1);
    fundToken.rejectRedemption(reqId2, address(adapter), assetAmount2, shareAmount2);

    // Ack in reverse order: reqId2 first
    vm.prank(bot);
    adapter.acknowledgeReject(reqId2);
    // reqId1 still un-ack'd but updateVaultAssets still passes (extras tolerated)
    adapter.updateVaultAssets();

    // Ack reqId1 — full reconciliation
    vm.prank(bot);
    adapter.acknowledgeReject(reqId1);
    assertEq(adapter.expectedShareBalance(), fundToken.balanceOf(address(adapter)));
    adapter.updateVaultAssets();

    // Re-ack reqId1 fails via explicit dedup map.
    vm.prank(bot);
    vm.expectRevert(bytes("reqId already acknowledged"));
    adapter.acknowledgeReject(reqId1);
  }

  function test_acknowledgeReject_with_dust_tolerated() public {
    // ack tolerates dust on top of the reject, and residual dust no longer bricks
    // _updateVaultAssets (>= check). MANAGER can still sweep it via emergencyWithdraw if desired.
    _deposit(alice, 100e6);
    (uint256 reqId, uint256 shareAmount, uint256 assetAmount) = _initiateRedemption(30e6);
    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, shareAmount);

    address attacker = makeAddr("attacker");
    deal(address(fundToken), attacker, 1);
    vm.prank(attacker);
    fundToken.transfer(address(adapter), 1);

    vm.prank(bot);
    adapter.acknowledgeReject(reqId);

    // Dust extras don't block
    adapter.updateVaultAssets();

    // MANAGER can still sweep
    vm.prank(manager);
    adapter.emergencyWithdraw(address(fundToken), 1);
    adapter.updateVaultAssets();
  }

  function test_acknowledgeReject_defers_combined_interest_to_next_sync() public {
    // NAV +5% during reject window. ack itself pushes NOTHING — it just bumps share count and
    // adds lockedAssetAmount to lastVault. Combined active + in-flight delta surfaces on next
    // _updateVaultAssets via the standard fee + cap path.

    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    (uint256 reqId, uint256 burntShareAmount, uint256 assetAmount) = _initiateRedemption(30e6);
    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, burntShareAmount);

    uint256 navAtAck = (INITIAL_NAV * 105) / 100;
    oracle.setPrice(navAtAck);

    uint256 stakingBefore = staking.userTotalAssetsScaled();
    uint256 feeBefore = adapter.fee();

    vm.prank(bot);
    adapter.acknowledgeReject(reqId);

    // ack itself: NO fee / staking change
    assertEq(adapter.fee(), feeBefore, "ack pushes no fee");
    assertEq(staking.userTotalAssetsScaled(), stakingBefore, "ack pushes no staking interest");

    // Next sync: combined 5% gain on all 100 XAUT = 5 XAUT gross
    adapter.updateVaultAssets();
    uint256 totalGain = ((70e6 + 30e6) * 5) / 100; // 5e6
    uint256 totalFee = (totalGain * adapter.feeRate()) / 1e18; // 1e6
    uint256 totalNet = totalGain - totalFee; // 4e6
    assertEq(adapter.fee() - feeBefore, totalFee, "combined fee on next sync");
    assertEq(staking.userTotalAssetsScaled() - stakingBefore, totalNet * 1e12, "combined net interest on next sync");

    // lastVault = expected × navAtAck (clean)
    uint256 expectedLast = (adapter.expectedShareBalance() * navAtAck) / 1e30;
    assertEq(adapter.lastVaultTotalAssets(), expectedLast, "last reflects all 100 shares at navAtAck");
  }

  function test_acknowledgeReject_then_decline_sync_reverts() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    (uint256 reqId, uint256 burntShareAmount, uint256 assetAmount) = _initiateRedemption(30e6);
    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, burntShareAmount);

    // NAV ends below the request-time value the ack re-credits -> the next sync sees a net decline.
    // ack itself still pushes nothing; the sync then fails closed (loss path removed).
    uint256 navAtAck = (INITIAL_NAV * 95) / 100;
    oracle.setPrice(navAtAck);

    uint256 stakingBefore = staking.userTotalAssetsScaled();
    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
    assertEq(staking.userTotalAssetsScaled(), stakingBefore, "ack pushes nothing");

    vm.expectRevert(bytes("vault value decreased"));
    adapter.updateVaultAssets();
  }

  function test_acknowledgeReject_only_bot() public {
    _deposit(alice, 100e6);
    (uint256 reqId, uint256 shareAmount, uint256 assetAmount) = _initiateRedemption(30e6);
    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, shareAmount);

    // MANAGER cannot call — BOT-only
    vm.prank(manager);
    vm.expectRevert();
    adapter.acknowledgeReject(reqId);

    // BOT succeeds
    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
  }

  function test_finishEarnPoolWithdraw_zero_amount_ticks_batch_state() public {
    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(0);
  }

  function test_acknowledgeReject_when_no_slisXAUE_holders_routes_inflight_gain_to_fee() public {
    // Full-exit + reject + NAV change scenario: in-flight interest has nobody to absorb
    // (totalSupply == 0 at ack time). acknowledgeReject itself only bumps accounting and
    // never pushes to staking; the in-flight gain surfaces on the next _updateVaultAssets
    // and `_pushInterest` routes the FULL amount to `fee` when totalSupply == 0. No orphan
    // is created and the next deposit is still priced 1:1.

    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    vm.prank(alice);
    staking.requestWithdraw(100e6, 0, alice);
    assertEq(slisXAUE.totalSupply(), 0);

    uint256 reqId = fundToken.redemptionsLength();
    vm.prank(bot);
    adapter.requestWithdrawFromVault(100e6);
    (, , uint256 assetAmount, uint256 shareAmount, , ) = fundToken.redemptions(reqId);

    fundToken.rejectRedemption(reqId, address(adapter), assetAmount, shareAmount);
    oracle.setPrice((INITIAL_NAV * 105) / 100);

    uint256 feeBefore = adapter.fee();
    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
    // ack itself doesn't push -- fee is still untouched
    assertEq(adapter.fee(), feeBefore, "ack does not push");

    // Next sync routes the in-flight gain entirely to fee
    adapter.updateVaultAssets();
    assertGt(adapter.fee(), feeBefore, "in-flight gain captured as fee");

    // Subsequent deposit still prices 1:1 — no orphan
    address newUser = makeAddr("newUser");
    xaut.mint(newUser, 100e6);
    vm.startPrank(newUser);
    xaut.approve(address(staking), 100e6);
    staking.deposit(100e6, 0, newUser);
    vm.stopPrank();
    assertEq(slisXAUE.balanceOf(newUser), 100e18, "next user gets 100 slisXAUE 1:1");
  }

  function test_limbo_gain_routes_full_amount_to_fee() public {
    // Limbo: A fully exited (totalSupply == 0) but BOT hasn't redeemed yet.
    // NAV grows on adapter's still-held shares → _pushInterest should route the entire
    // gain to fee (not just feeRate × gain), since there are no holders entitled to the rest.

    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    vm.prank(alice);
    staking.requestWithdraw(100e6, 0, alice);
    assertEq(slisXAUE.totalSupply(), 0);
    uint256 feeBefore = adapter.fee();

    // NAV +5% while limbo
    oracle.setPrice((INITIAL_NAV * 105) / 100);
    uint256 expectedGain = (100e6 * 5) / 100; // 5 XAUT on 100 XAUT base

    adapter.updateVaultAssets();

    // 100% of gain → fee (not feeRate × gain)
    assertEq(adapter.fee() - feeBefore, expectedGain, "full gain routed to fee");
    // uta still 0 (no orphan)
    assertEq(staking.userTotalAssetsScaled(), 0, "no orphan uta during limbo");

    // Next deposit still 1:1
    address newUser = makeAddr("newUser");
    xaut.mint(newUser, 100e6);
    vm.startPrank(newUser);
    xaut.approve(address(staking), 100e6);
    staking.deposit(100e6, 0, newUser);
    vm.stopPrank();
    assertEq(slisXAUE.balanceOf(newUser), 100e18, "next user gets 100 slisXAUE 1:1");
  }

  function test_limbo_decline_reverts_fail_closed() public {
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Alice exits at the original NAV (clean rounding) -> limbo state (totalSupply == 0)
    vm.prank(alice);
    staking.requestWithdraw(100e6, 0, alice);
    assertEq(slisXAUE.totalSupply(), 0);
    assertEq(adapter.fee(), 0);

    // NAV +5% during limbo -> entire gain routed to fee (gain path still works)
    oracle.setPrice((INITIAL_NAV * 105) / 100);
    adapter.updateVaultAssets();
    assertGt(adapter.fee(), 0, "fee accumulated during limbo gain");

    // A subsequent decline (even in limbo) fails closed -- with the loss path removed `fee` no
    // longer acts as a loss buffer. (Bailsec 06 -- claimFee-bypass precondition eliminated.)
    uint256 navAtLoss = (oracle.getLatestPrice() * 98) / 100;
    oracle.setPrice(navAtLoss);
    vm.expectRevert(bytes("vault value decreased"));
    adapter.updateVaultAssets();
  }

  function test_zero_base_gain_does_not_brick_after_dust_residual() public {
    // Bailsec 05/10: reach the broken state expectedShareBalance > 0 with lastVaultTotalAssets == 0
    // (a sub-1-XAUT dust residual left after a full redemption), then prove the next NAV increase
    // syncs instead of reverting "delta exceeds max". Loss-path removal does NOT fix this; the
    // baseValue == 0 guard in _pushInterest does. Before the fix updateVaultAssets() reverted here.

    // Non-round NAV so the getVaultTotalAssets floor vs requestWithdrawFromVault ceil leave a residual.
    uint256 nav0 = 1e15 + 7;
    oracle.setPrice(nav0);

    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // Alice fully exits -> totalSupply == 0 (the fee-only regime in the finding).
    vm.prank(alice);
    staking.requestWithdraw(100e6, 0, alice);
    assertEq(slisXAUE.totalSupply(), 0);

    // BOT redeems the full rounded vault value; ceil-vs-floor leaves a dust residual whose XAUT
    // value floors to 0 -> lastVaultTotalAssets becomes 0 while expectedShareBalance is still > 0.
    uint256 fullValue = adapter.getVaultTotalAssets();
    vm.prank(bot);
    adapter.requestWithdrawFromVault(fullValue);

    uint256 residual = adapter.expectedShareBalance();
    assertGt(residual, 0, "precondition: dust residual remains");
    assertEq(adapter.lastVaultTotalAssets(), 0, "precondition: lastVault floored to 0");

    // NAV rises enough that the residual is worth >= 1 XAUT raw unit again (0 -> positive base).
    uint256 navUp = (1e30 / residual) + 1;
    oracle.setPrice(navUp);
    assertGt(adapter.getVaultTotalAssets(), 0, "residual now worth >= 1");

    // Must NOT revert (cap skipped against the zero base); the dust gain is routed to fee.
    uint256 feeBefore = adapter.fee();
    adapter.updateVaultAssets();
    assertGt(adapter.lastVaultTotalAssets(), 0, "base re-established after sync");
    assertGt(adapter.fee(), feeBefore, "dust gain routed to fee (totalSupply == 0)");
  }

  function test_dust_attack_tolerated_and_sweepable() public {
    // Dust attacks no longer brick the adapter (>= check). Math is unaffected because
    // getVaultTotalAssets uses expectedShareBalance, not raw balance. MANAGER can sweep.
    _deposit(alice, 100e6);
    vm.prank(bot);
    adapter.depositToVault(100e6);
    uint256 expectedBefore = adapter.expectedShareBalance();

    address attacker = makeAddr("attacker");
    deal(address(fundToken), attacker, 1);
    vm.prank(attacker);
    fundToken.transfer(address(adapter), 1);

    // No brick
    adapter.updateVaultAssets();

    // MANAGER sweeps dust
    vm.prank(manager);
    adapter.emergencyWithdraw(address(fundToken), 1);
    assertEq(fundToken.balanceOf(address(adapter)), expectedBefore);

    adapter.updateVaultAssets();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  function _deposit(address user, uint256 amount) internal {
    vm.startPrank(user);
    xaut.approve(address(staking), amount);
    staking.deposit(amount, 0, user);
    vm.stopPrank();
  }

  /// @dev Full XAUE redemption: adapter pushes any idle XAUT into XAUE, requests a redemption for
  ///      `xautToFinish` XAUT-equivalent shares, XAUE approves, BOT forwards to staking.
  function _runRedemption(uint256 xautToFinish) internal returns (uint256 reqId) {
    uint256 idle = xaut.balanceOf(address(adapter));
    vm.startPrank(bot);
    if (idle > 0) adapter.depositToVault(idle);
    reqId = fundToken.redemptionsLength();
    adapter.requestWithdrawFromVault(xautToFinish);
    vm.stopPrank();

    (, address reqUser, uint256 assetAmount, uint256 shareAmount, , ) = fundToken.redemptions(reqId);
    fundToken.approveRedemption(reqId, reqUser, assetAmount, shareAmount);

    vm.prank(bot);
    adapter.finishEarnPoolWithdraw(assetAmount);
  }

  /// @dev Initiate but DO NOT approve a redemption. Returns reqId + the locked (shareAmount, assetAmount).
  ///      Caller decides whether to approve or reject.
  function _initiateRedemption(
    uint256 xautToFinish
  ) internal returns (uint256 reqId, uint256 shareAmount, uint256 assetAmount) {
    uint256 idle = xaut.balanceOf(address(adapter));
    vm.startPrank(bot);
    if (idle > 0) adapter.depositToVault(idle);
    reqId = fundToken.redemptionsLength();
    adapter.requestWithdrawFromVault(xautToFinish);
    vm.stopPrank();
    (, , assetAmount, shareAmount, , ) = fundToken.redemptions(reqId);
  }
}
