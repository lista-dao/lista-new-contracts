// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../src/slisXAUE/SlisXAUE.sol";
import "../../src/slisXAUE/XAUTStaking.sol";
import "../../src/slisXAUE/XAUEAdapter.sol";
import { IXAUEOracle } from "../../src/slisXAUE/interface/IXAUEOracle.sol";
import { IXAUEFundToken } from "../../src/slisXAUE/interface/IXAUEFundToken.sol";

/**
 * @notice ETH mainnet fork test against the live XAUE Protocol (FundToken + Oracle + Vault).
 *         Validates that our XAUEAdapter integration -- in particular the `acknowledgeReject`
 *         accounting fix -- works against the real bytecode and storage layout, not just our
 *         in-tree mocks.
 *
 *         The live XAUE `rejectRedemption` selector lives behind a Safe multisig, so we forge the
 *         "Rejected" state via `vm.store` rather than calling the real reject path. This still
 *         exercises everything our adapter actually depends on: the `redemptions(reqId)` getter
 *         tuple, the shares being held by the adapter, and the real Oracle NAV.
 *
 *         Run:
 *           forge test --match-path test/slisXAUE/XAUEForkTest.t.sol \
 *             --fork-url eth_mainnet --fork-block-number <pinned> -vv
 *
 *         If no fork URL is supplied, `setUp` skips. Block-pin is recommended for reproducibility.
 */
contract XAUEForkTest is Test {
  // Live XAUE Protocol on Ethereum mainnet
  address constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
  address constant XAUE_FUND_TOKEN = 0xd5D6840ed95F58FAf537865DcA15D5f99195F87a;
  address constant XAUE_ORACLE = 0x0618BD112C396060d2b37B537b3d92e757644169;

  // Live AccessControl role holders on the FundToken (read on-chain via getRoleMember).
  address constant XAUE_MANAGER_HOLDER = 0x3dB9A4DD1BFF3494982D4A4b0191495E32DA5D30;

  // FundToken storage:
  //   slot 9        => redemptions.length
  //   keccak(9) + i*6 + 0..5 => struct fields for redemptions[i] (id/user/asset/share/at/status)
  uint256 constant FT_REDEMPTIONS_LEN_SLOT = 9;
  uint256 constant FT_REDEMPTION_STRUCT_SIZE = 6;

  // Lista contracts
  SlisXAUE slisXAUE;
  XAUTStaking staking;
  XAUEAdapter adapter;

  // Actors
  address admin = makeAddr("admin");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");
  address bot = makeAddr("bot");
  address feeReceiver = makeAddr("feeReceiver");
  address alice = makeAddr("alice");

  // Live params (read on chain in setUp for sanity)
  uint256 navAtSetup;
  uint256 currentAPR;

  bool forkActive;

  function setUp() public {
    // Skip if not running on a fork (block.chainid != 1 implies no ETH fork URL was passed)
    if (block.chainid != 1) {
      forkActive = false;
      return;
    }
    forkActive = true;

    // Sanity probes against the real contracts
    navAtSetup = IXAUEOracle(XAUE_ORACLE).getLatestPrice();
    require(navAtSetup > 0, "oracle unreachable -- check fork URL");
    require(IXAUEFundToken(XAUE_FUND_TOKEN).minRedeemShares() == 1e18, "unexpected minRedeem");

    // Deploy Lista stack pointing to real XAUE
    SlisXAUE slisImpl = new SlisXAUE();
    XAUTStaking stakingImpl = new XAUTStaking();
    XAUEAdapter adapterImpl = new XAUEAdapter(XAUT);

    slisXAUE = SlisXAUE(address(new ERC1967Proxy(address(slisImpl), "")));
    staking = XAUTStaking(address(new ERC1967Proxy(address(stakingImpl), "")));
    adapter = XAUEAdapter(address(new ERC1967Proxy(address(adapterImpl), "")));

    slisXAUE.initialize(admin, address(staking), "Lista Staked XAUE", "slisXAUE");
    staking.initialize(admin, manager, pauser, XAUT, address(slisXAUE), address(adapter), 15_000 * 1e18);
    adapter.initialize(admin, manager, bot, address(slisXAUE), XAUE_FUND_TOKEN, XAUE_ORACLE, feeReceiver, 0.2e18);
    vm.prank(manager);
    adapter.setStaking(address(staking));

    vm.startPrank(manager);
    staking.setMinDeposit(1000);
    staking.setMinWithdraw(1000);
    vm.stopPrank();

    // Whitelist adapter on the real XAUE FundToken (impersonate XAUE's MANAGER multisig)
    vm.prank(XAUE_MANAGER_HOLDER);
    XAUEFundTokenLike(XAUE_FUND_TOKEN).addToWhitelist(address(adapter));
    require(XAUEFundTokenLike(XAUE_FUND_TOKEN).whitelist(address(adapter)), "whitelist failed");

    // Fund alice with XAUt (overwrite balanceOf via deal)
    deal(XAUT, alice, 1_000_000e6); // 1M XAUt

    // bot needs XAUE staking address pre-approved? No — addresses are wired at init via proxies.
  }

  /// @dev End-to-end: real XAUE mint + Oracle NAV growth + forged reject + ack pushes missed interest.
  function test_acknowledgeReject_pushes_missed_interest_against_real_xaue() public {
    if (!forkActive) {
      emit log_string("skipped: fork not active (chainid != 1)");
      return;
    }

    // 1) alice deposits 100 XAUt → staking → adapter → real XAUE mint
    uint256 depositAmt = 100e6;
    vm.startPrank(alice);
    IERC20(XAUT).approve(address(staking), depositAmt);
    staking.deposit(depositAmt, 0, alice);
    vm.stopPrank();

    vm.prank(bot);
    adapter.depositToVault(depositAmt);

    // Sanity: expectedShareBalance now matches the real XAUE balance.
    uint256 expectedAfterMint = adapter.expectedShareBalance();
    assertGt(expectedAfterMint, 0, "no shares minted");
    assertEq(
      IERC20(XAUE_FUND_TOKEN).balanceOf(address(adapter)),
      expectedAfterMint,
      "real XAUE balance matches expected"
    );

    // 2) Time-warp 60 days — real Oracle NAV linearly grows by ~ currentAPR * 60/365.
    //    Real Oracle has currentAPR around 1.64% so NAV bumps ~0.27% over 60d.
    vm.warp(block.timestamp + 60 days);
    uint256 navAfterWarp = IXAUEOracle(XAUE_ORACLE).getLatestPrice();
    assertGt(navAfterWarp, navAtSetup, "real oracle NAV grew over time");

    // 3) Request a 30-XAUt redemption. Real XAUE burns shares from adapter and creates a
    //    redemption record.
    uint256 redemptionAmt = 30e6;
    // Read redemptions.length directly from slot 9 (FundToken doesn't expose a public getter).
    uint256 reqId = uint256(vm.load(XAUE_FUND_TOKEN, bytes32(FT_REDEMPTIONS_LEN_SLOT)));
    vm.prank(bot);
    adapter.requestWithdrawFromVault(redemptionAmt);

    uint256 expectedAfterRequest = adapter.expectedShareBalance();
    assertLt(expectedAfterRequest, expectedAfterMint, "expected decreased after burn");
    assertEq(
      IERC20(XAUE_FUND_TOKEN).balanceOf(address(adapter)),
      expectedAfterRequest,
      "real balance == expected post-request"
    );

    // 4) Forge "Rejected" state + re-mint burnt shares back to adapter. Real reject function lives
    //    behind XAUE's Safe multisig, so we write to storage directly — equivalent net effect.
    _forgeRejectAndMintBack(reqId);

    // 5) Time-warp another 60 days during the reject window. NAV grows further on the unrejected
    //    shares -- this is the gain that previously would have been swallowed by acknowledgeReject.
    vm.warp(block.timestamp + 60 days);
    uint256 navAtAck = IXAUEOracle(XAUE_ORACLE).getLatestPrice();
    assertGt(navAtAck, navAfterWarp, "NAV grew further during reject window");

    _assertInterestAck(reqId, navAtAck);

    // b) Expected restored
    assertEq(
      adapter.expectedShareBalance(),
      IERC20(XAUE_FUND_TOKEN).balanceOf(address(adapter)),
      "expected == real after ack"
    );

    // 7) Subsequent updateVaultAssets sees zero delta -- the seeded principal was NOT double-counted
    uint256 stakingFlat = staking.userTotalAssetsScaled();
    uint256 feeFlat = adapter.fee();
    adapter.updateVaultAssets();
    assertEq(staking.userTotalAssetsScaled(), stakingFlat, "no double-count on seed");
    assertEq(adapter.fee(), feeFlat, "no extra fee on seed");

    // 8) Re-ack is rejected by the dedup map
    vm.prank(bot);
    vm.expectRevert(bytes("reqId already acknowledged"));
    adapter.acknowledgeReject(reqId);
  }

  /// @dev Symmetric loss path: NAV drops during the reject window. The real Oracle never reports a
  ///      decline, so we mock `getLatestPrice` for the post-warp reads. Asserts the total loss
  ///      pushed to staking equals `(activeSlice + inFlightSlice)` — proving the in-flight loss is
  ///      included alongside the active slice's loss.
  function test_acknowledgeReject_pushes_missed_loss_against_real_xaue() public {
    if (!forkActive) {
      emit log_string("skipped: fork not active (chainid != 1)");
      return;
    }

    // 1) Deposit + push into XAUE at real NAV
    vm.startPrank(alice);
    IERC20(XAUT).approve(address(staking), 100e6);
    staking.deposit(100e6, 0, alice);
    vm.stopPrank();
    vm.prank(bot);
    adapter.depositToVault(100e6);

    // 2) Request 30-XAUt redemption at the real current NAV (no warp yet)
    uint256 navAtRequest = IXAUEOracle(XAUE_ORACLE).getLatestPrice();
    uint256 reqId = uint256(vm.load(XAUE_FUND_TOKEN, bytes32(FT_REDEMPTIONS_LEN_SLOT)));
    vm.prank(bot);
    adapter.requestWithdrawFromVault(30e6);

    // 3) Forge Rejected status + re-mint burnt shares
    _forgeRejectAndMintBack(reqId);

    // 4) Mock the oracle to report a 3% LOWER NAV at ack (real oracle never drops)
    uint256 navAtAck = (navAtRequest * 97) / 100;
    vm.mockCall(XAUE_ORACLE, abi.encodeWithSelector(IXAUEOracle.getLatestPrice.selector), abi.encode(navAtAck));

    _assertLossAck(reqId, navAtAck);
    vm.clearMockedCalls();
  }

  /// @dev Helper: flips XAUE.redemptions[reqId].status to Rejected and re-mints the burned shares
  ///      back to adapter (simulating XAUE's `_mintBypass` from rejectRedemption).
  function _forgeRejectAndMintBack(uint256 reqId) internal {
    (, , , uint256 reqShareAmt, , ) = IXAUEFundToken(XAUE_FUND_TOKEN).redemptions(reqId);
    bytes32 elementBase = keccak256(abi.encode(FT_REDEMPTIONS_LEN_SLOT));
    bytes32 statusSlot = bytes32(uint256(elementBase) + reqId * FT_REDEMPTION_STRUCT_SIZE + 5);
    vm.store(XAUE_FUND_TOKEN, statusSlot, bytes32(uint256(1)));
    deal(XAUE_FUND_TOKEN, address(adapter), IERC20(XAUE_FUND_TOKEN).balanceOf(address(adapter)) + reqShareAmt, true);
  }

  /// @dev Helper: ack pushes nothing; combined (active + in-flight) gain surfaces on next sync.
  function _assertInterestAck(uint256 reqId, uint256 navAtAck) internal {
    (uint256 activeSliceGain, uint256 inFlightSliceGain) = _computeGainSlices(reqId, navAtAck);
    assertGt(inFlightSliceGain, 0, "test setup: NAV must grow during reject window");

    uint256 stakingBefore = staking.userTotalAssetsScaled();
    uint256 feeBefore = adapter.fee();

    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
    assertEq(adapter.fee(), feeBefore, "ack pushes no fee");
    assertEq(staking.userTotalAssetsScaled(), stakingBefore, "ack pushes no staking interest");

    adapter.updateVaultAssets();
    uint256 totalGain = activeSliceGain + inFlightSliceGain;
    uint256 totalFee = (totalGain * adapter.feeRate()) / 1e18;
    assertApproxEqAbs(adapter.fee() - feeBefore, totalFee, 2, "combined fee on next sync");
    assertApproxEqAbs(
      staking.userTotalAssetsScaled() - stakingBefore,
      (totalGain - totalFee) * 1e12,
      2 * 1e12,
      "combined net interest on next sync"
    );

    assertApproxEqAbs(
      adapter.lastVaultTotalAssets(),
      (adapter.expectedShareBalance() * navAtAck) / 1e30,
      2,
      "last == expected * navAtAck"
    );
  }

  function _computeGainSlices(
    uint256 reqId,
    uint256 navAtAck
  ) internal view returns (uint256 active, uint256 inFlight) {
    uint256 expectedAfterRequest = adapter.expectedShareBalance();
    (, , uint256 reqAssetAmt, uint256 reqShareAmt, , ) = IXAUEFundToken(XAUE_FUND_TOKEN).redemptions(reqId);
    uint256 lastBeforeAck = adapter.lastVaultTotalAssets();
    active = (expectedAfterRequest * navAtAck) / 1e30 - lastBeforeAck;
    inFlight = (reqShareAmt * navAtAck) / 1e30 - reqAssetAmt;
  }

  /// @dev Helper: ack pushes nothing; combined (active + in-flight) loss surfaces on next sync.
  function _assertLossAck(uint256 reqId, uint256 navAtAck) internal {
    (uint256 activeSliceLoss, uint256 inFlightSliceLoss) = _computeLossSlices(reqId, navAtAck);
    assertGt(inFlightSliceLoss, 0, "test setup: NAV must drop during reject window");

    uint256 stakingBefore = staking.userTotalAssetsScaled();
    uint256 feeBefore = adapter.fee();

    vm.prank(bot);
    adapter.acknowledgeReject(reqId);
    assertEq(staking.userTotalAssetsScaled(), stakingBefore, "ack pushes no loss");
    assertEq(adapter.fee(), feeBefore, "fee unchanged on loss path");

    adapter.updateVaultAssets();
    uint256 totalLoss = activeSliceLoss + inFlightSliceLoss;
    assertApproxEqAbs(
      stakingBefore - staking.userTotalAssetsScaled(),
      totalLoss * 1e12,
      2 * 1e12,
      "combined loss on next sync"
    );
    assertApproxEqAbs(
      adapter.lastVaultTotalAssets(),
      (adapter.expectedShareBalance() * navAtAck) / 1e30,
      2,
      "last == expected * navAtAck"
    );
  }

  function _computeLossSlices(
    uint256 reqId,
    uint256 navAtAck
  ) internal view returns (uint256 active, uint256 inFlight) {
    uint256 expectedAfterRequest = adapter.expectedShareBalance();
    (, , uint256 reqAssetAmt, uint256 reqShareAmt, , ) = IXAUEFundToken(XAUE_FUND_TOKEN).redemptions(reqId);
    uint256 lastBeforeAck = adapter.lastVaultTotalAssets();
    active = lastBeforeAck - (expectedAfterRequest * navAtAck) / 1e30;
    inFlight = reqAssetAmt - (reqShareAmt * navAtAck) / 1e30;
  }
}

interface XAUEFundTokenLike {
  function addToWhitelist(address) external;
  function whitelist(address) external view returns (bool);
}
