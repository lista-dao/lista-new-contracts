// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Fork simulation of the SlisBNBProvider V2 cut-over (draft impl, not audited).
//   0. Manager Safe: SlisBNBxMinter.addModule(provider, {discount 0, feeRate 3%})       (same as Moolah slisBNB module)
//   1. TimeLock:     provider.upgradeToAndCall(V2, migrateFromCdp([Aster, Pendle, Sigma], [Aster, Pendle]))
// Then: balances moved, legacy clisBNB replaced by minter slisBNBx, integrator flows still work,
// CDP PROXY / migrator paths can no longer move funds, and flows still work with a stale CDP oracle.
// Run: BSC_RPC=<rpc> forge test --mc ProviderV2Migration -vv

import "forge-std/Test.sol";
import {SlisBNBProviderV2} from "../../src/cdp/SlisBNBProviderV2.sol";

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}
interface IVatM {
    function urns(bytes32, address) external view returns (uint256, uint256);
    function gem(bytes32, address) external view returns (uint256);
}
interface IInteractionM {
    function collaterals(address) external view returns (address, bytes32, uint32, address);
    function locked(address, address) external view returns (uint256);
    function migrator() external view returns (address);
}
struct ModuleConfig { uint24 discount; uint24 feeRate; address moduleAddress; }
interface IMinterM {
    function addModule(address, ModuleConfig calldata) external;
    function userModuleBalance(address, address) external view returns (uint256 userPart, uint256 feePart);
    function delegation(address) external view returns (address);
    function mpcWallets(uint256) external view returns (address, uint256, uint256);
}
interface IProvV1 {
    function upgradeToAndCall(address, bytes calldata) external payable;
    function userLp(address) external view returns (uint256);
    function userReservedLp(address) external view returns (uint256);
    function totalReservedLp() external view returns (uint256);
    function delegation(address) external view returns (address, uint256);
    function liquidation(address, uint256) external;
    function releaseFor(address, uint256) external returns (uint256);
    function release(address, uint256) external returns (uint256);
    function setDepositWhitelist(address[] calldata, bool) external;
}
interface IStakeManagerM { function convertSnBnbToBnb(uint256) external view returns (uint256); }
interface IAsBnbMinterM {
    function asBnb() external view returns (address);
    function mintAsBnb(uint256) external returns (uint256);
    function burnAsBnb(uint256) external returns (uint256);
}
interface ISYM {
    function deposit(address, address, uint256, uint256) external payable returns (uint256);
    function redeem(address, uint256, address, uint256, bool) external returns (uint256);
}

contract ProviderV2Migration is Test {
    address constant PROVIDER = 0xfD31e1C5e5571f8E7FE318f80888C1e6da97819b;
    address constant MINTER = 0x2959c423bfe5Cc6E41516599D982A29C0773F11a;
    address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant CLISBNB = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
    address constant STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
    address constant MANAGER_SAFE = 0x8d388136d578dCD791D081c6042284CED6d9B0c6;
    address constant CORE_ADMIN = 0xAca0ed4651ddA1F43f00363643CFa5EBF8774b37;
    IVatM constant VAT = IVatM(0x33A34eAB3ee892D40420507B820347b1cA2201c4);
    IInteractionM constant I = IInteractionM(0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4);
    address constant ASTER = 0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2;
    address constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address constant PENDLE = 0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa;
    address constant SIGMA = 0x8B98563d66B74e5a644BFf78fC72c86bbA847a29;
    address constant RESERVE = 0xD57E5321e67607Fab38347D96394e0E58509C506; // lpReserveAddress = minter MPC 0 = Aster delegatee

    bytes32 ilk;
    address gemJoin;
    address[3] users;
    uint256[3] locked0;
    address[3] dele;
    address user;

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_RPC"));
        (gemJoin, ilk,,) = I.collaterals(SLISBNB);
        users = [ASTER, PENDLE, SIGMA];
        for (uint256 i; i < 3; i++) {
            locked0[i] = I.locked(SLISBNB, users[i]);
            (dele[i],) = IProvV1(PROVIDER).delegation(users[i]);
        }
        user = makeAddr("user");
        deal(SLISBNB, user, 10 ether);
        console2.log("fork block", block.number);
    }

    function _cutover() internal {
        vm.prank(MANAGER_SAFE);
        IMinterM(MINTER).addModule(PROVIDER, ModuleConfig(0, 30000, PROVIDER));
        SlisBNBProviderV2 impl = new SlisBNBProviderV2(MINTER, STAKE_MANAGER);
        address[] memory acc = new address[](3);
        address[] memory wl = new address[](2);
        (acc[0], acc[1], acc[2]) = (ASTER, PENDLE, SIGMA);
        (wl[0], wl[1]) = (ASTER, PENDLE);
        vm.prank(TIMELOCK);
        IProvV1(PROVIDER).upgradeToAndCall(address(impl), abi.encodeCall(SlisBNBProviderV2.migrateFromCdp, (acc, wl)));
    }

    function _ink(address a) internal view returns (uint256 ink) { (ink,) = VAT.urns(ilk, a); }

    function test_cutoverMovesBalancesAndSlisBNBx() public {
        IERC20M clis = IERC20M(CLISBNB);
        uint256 gj0 = IERC20M(SLISBNB).balanceOf(gemJoin);
        uint256 resLegacy;
        uint256[3] memory deleBal0;
        uint256[3] memory deleAmt0;
        for (uint256 i; i < 3; i++) {
            resLegacy += IProvV1(PROVIDER).userReservedLp(users[i]);
            deleBal0[i] = clis.balanceOf(dele[i]);
            (, deleAmt0[i]) = IProvV1(PROVIDER).delegation(users[i]);
            emit log_named_decimal_uint("CDP locked slisBNB", locked0[i], 18);
            emit log_named_decimal_uint("  legacy clisBNB (user part)", IProvV1(PROVIDER).userLp(users[i]), 18);
        }
        uint256 res0 = clis.balanceOf(RESERVE);
        uint256 sup0 = clis.totalSupply();
        uint256 totalReserved0 = IProvV1(PROVIDER).totalReservedLp();

        _cutover();
        SlisBNBProviderV2 p = SlisBNBProviderV2(PROVIDER);

        uint256 total;
        uint256 newUser;
        uint256 newFee;
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            total += locked0[i];
            assertEq(_ink(u), 0, "CDP urn emptied");
            assertEq(I.locked(SLISBNB, u), 0, "CDP locked");
            assertEq(p.userBalance(u), locked0[i], "balance credited");
            assertEq(IProvV1(PROVIDER).userLp(u), 0, "legacy userLp");
            assertEq(IProvV1(PROVIDER).userReservedLp(u), 0, "legacy reserve");
            (address d, uint256 da) = IProvV1(PROVIDER).delegation(u);
            assertEq(d, address(0)); assertEq(da, 0);
            assertEq(IMinterM(MINTER).delegation(u), dele[i], "delegatee moved to minter");
            (uint256 up, uint256 fp) = IMinterM(MINTER).userModuleBalance(u, PROVIDER);
            uint256 bnb = IStakeManagerM(STAKE_MANAGER).convertSnBnbToBnb(locked0[i]);
            assertEq(up + fp, bnb, "slisBNBx = BNB value");
            assertEq(fp, (bnb * 30000 + 999_999) / 1_000_000, "3% fee rounded up");
            newUser += up; newFee += fp;
            emit log_named_decimal_uint("  new slisBNBx (user part)", up, 18);
        }
        assertEq(IERC20M(SLISBNB).balanceOf(PROVIDER), total, "provider holds slisBNB");
        assertEq(p.totalBalance(), total, "totalBalance");
        assertEq(gj0 - IERC20M(SLISBNB).balanceOf(gemJoin), total, "left GemJoin");
        assertEq(totalReserved0 - IProvV1(PROVIDER).totalReservedLp(), resLegacy, "legacy reserve accounting");
        // Pendle / Sigma delegatees: legacy delegated clisBNB replaced by the new user part
        for (uint256 i = 1; i < 3; i++) {
            (uint256 up,) = IMinterM(MINTER).userModuleBalance(users[i], PROVIDER);
            assertEq(clis.balanceOf(dele[i]), deleBal0[i] - deleAmt0[i] + up, "delegatee clisBNB");
        }
        // Aster delegatee = lpReserve = MPC0: minus Aster legacy delegated, minus legacy reserve of all 3, plus Aster user part, plus fees
        {
            (uint256 aUp,) = IMinterM(MINTER).userModuleBalance(ASTER, PROVIDER);
            assertEq(clis.balanceOf(RESERVE), res0 - deleAmt0[0] - resLegacy + aUp + newFee, "reserve/MPC0 clisBNB");
        }
        emit log_named_decimal_uint("slisBNB moved out of CDP", total, 18);
        emit log_named_decimal_uint("slisBNBx user part minted", newUser, 18);
        emit log_named_decimal_uint("slisBNBx fee to MPCs", newFee, 18);
        emit log_named_decimal_uint("lpReserve/MPC0 clisBNB before", res0, 18);
        emit log_named_decimal_uint("lpReserve/MPC0 clisBNB after", clis.balanceOf(RESERVE), 18);
        emit log_named_decimal_uint("clisBNB supply before", sup0, 18);
        emit log_named_decimal_uint("clisBNB supply after", clis.totalSupply(), 18);
    }

    function test_asterMintBurnAfterCutover() public {
        _cutover();
        IAsBnbMinterM m = IAsBnbMinterM(ASBNB_MINTER);
        address asBnb = m.asBnb();
        uint256 b0 = SlisBNBProviderV2(PROVIDER).userBalance(ASTER);
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(ASBNB_MINTER, 1 ether);
        uint256 got = m.mintAsBnb(1 ether);
        assertEq(SlisBNBProviderV2(PROVIDER).userBalance(ASTER), b0 + 1 ether, "Aster +1");
        uint256 s0 = IERC20M(SLISBNB).balanceOf(user);
        IERC20M(asBnb).approve(ASBNB_MINTER, got);
        m.burnAsBnb(got);
        vm.stopPrank();
        uint256 back = IERC20M(SLISBNB).balanceOf(user) - s0;
        assertGt(back, 0);
        assertEq(SlisBNBProviderV2(PROVIDER).userBalance(ASTER), b0 + 1 ether - back, "Aster -back");
        assertEq(_ink(ASTER), 0, "nothing back in CDP");
        emit log_named_decimal_uint("asBNB minted", got, 18);
        emit log_named_decimal_uint("slisBNB back", back, 18);
    }

    function _syRoundTrip(address sy) internal {
        uint256 b0 = SlisBNBProviderV2(PROVIDER).userBalance(sy);
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(sy, 1 ether);
        uint256 sh = ISYM(sy).deposit(user, SLISBNB, 1 ether, 0);
        assertEq(SlisBNBProviderV2(PROVIDER).userBalance(sy), b0 + 1 ether, "deposit");
        uint256 out = ISYM(sy).redeem(user, sh, SLISBNB, 0, false);
        vm.stopPrank();
        assertEq(out, 1 ether, "1:1 out");
        assertEq(SlisBNBProviderV2(PROVIDER).userBalance(sy), b0, "redeem");
    }

    function test_pendleAfterCutover() public {
        _cutover();
        _syRoundTrip(PENDLE);
    }

    function test_sigmaWhitelistThenDeposit() public {
        _cutover();
        // existing holder can still redeem
        deal(SIGMA, user, 1 ether);
        vm.prank(user);
        assertEq(ISYM(SIGMA).redeem(user, 1 ether, SLISBNB, 0, false), 1 ether, "Sigma redeem");
        // deposit refused until MANAGER allows it (same outcome as the CDP whitelist today)
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(SIGMA, 1 ether);
        vm.expectRevert(bytes("not in deposit whitelist"));
        ISYM(SIGMA).deposit(user, SLISBNB, 1 ether, 0);
        vm.stopPrank();
        address[] memory a = new address[](1);
        a[0] = SIGMA;
        vm.prank(MANAGER_SAFE);
        IProvV1(PROVIDER).setDepositWhitelist(a, true);
        _syRoundTrip(SIGMA);
    }

    function test_cdpPathsCannotMoveFunds() public {
        _cutover();
        vm.prank(CORE_ADMIN);
        vm.expectRevert(bytes("V2: liquidation disabled"));
        IProvV1(PROVIDER).liquidation(CORE_ADMIN, 1 ether);
        vm.prank(address(I));
        vm.expectRevert(bytes("V2: liquidation disabled"));
        IProvV1(PROVIDER).liquidation(address(I), 1 ether);
        address mig = I.migrator();
        if (mig != address(0)) {
            vm.prank(mig);
            vm.expectRevert(bytes("V2: CDP withdraw disabled"));
            IProvV1(PROVIDER).releaseFor(PENDLE, 1 ether);
        }
        // someone else's balance cannot be released
        vm.prank(user);
        vm.expectRevert(bytes("insufficient balance"));
        IProvV1(PROVIDER).release(user, 1 ether);
    }

    // CDP no longer on the path: a week with no oracle updates (CDP poke would see a stale price) does not matter.
    function test_flowsIgnoreStaleCdpOracle() public {
        _cutover();
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 28800);
        _syRoundTrip(PENDLE);
        uint256 all = SlisBNBProviderV2(PROVIDER).userBalance(SIGMA);
        uint256 s0 = IERC20M(SLISBNB).balanceOf(SIGMA);
        vm.prank(SIGMA);
        IProvV1(PROVIDER).release(SIGMA, all);
        assertEq(IERC20M(SLISBNB).balanceOf(SIGMA) - s0, all, "Sigma full exit");
        (uint256 up, uint256 fp) = IMinterM(MINTER).userModuleBalance(SIGMA, PROVIDER);
        assertEq(up + fp, 0, "slisBNBx cleared on full exit");
    }

    // An integrator that fully exits during the TimeLock delay is skipped, not a revert.
    function test_cutoverSkipsEmptyAccount() public {
        vm.prank(MANAGER_SAFE);
        IMinterM(MINTER).addModule(PROVIDER, ModuleConfig(0, 30000, PROVIDER));
        SlisBNBProviderV2 impl = new SlisBNBProviderV2(MINTER, STAKE_MANAGER);
        address[] memory acc = new address[](4);
        address[] memory wl = new address[](0);
        (acc[0], acc[1], acc[2], acc[3]) = (ASTER, PENDLE, SIGMA, makeAddr("exited"));
        vm.prank(TIMELOCK);
        IProvV1(PROVIDER).upgradeToAndCall(address(impl), abi.encodeCall(SlisBNBProviderV2.migrateFromCdp, (acc, wl)));
        assertEq(SlisBNBProviderV2(PROVIDER).userBalance(acc[3]), 0, "empty account skipped");
        for (uint256 i; i < 3; i++) assertEq(SlisBNBProviderV2(PROVIDER).userBalance(users[i]), locked0[i], "others migrated");
    }

    // syncSlisBNBx must not touch a CDP dust account (its slisBNB is still in the CDP).
    function test_syncSlisBNBxRejectsCdpDust() public {
        address dust = 0x2b334c9207BbEf33aE4495d3F0f32751118202eA; // ~0.01 slisBNB still locked in the CDP
        require(I.locked(SLISBNB, dust) > 0, "dust account no longer in CDP; pick another");
        _cutover();
        uint256 lp0 = IProvV1(PROVIDER).userLp(dust);
        vm.expectRevert(bytes("no balance here"));
        SlisBNBProviderV2(PROVIDER).syncSlisBNBx(dust);
        assertEq(IProvV1(PROVIDER).userLp(dust), lp0, "legacy clisBNB untouched");
    }

    function test_cutoverOnlyOnce() public {
        _cutover();
        address[] memory acc = new address[](0);
        vm.prank(TIMELOCK);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        SlisBNBProviderV2(PROVIDER).migrateFromCdp(acc, acc);
    }
}
