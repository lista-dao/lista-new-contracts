// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Fork simulation of the SlisBNBProvider CDP exit (draft impl, not audited).
//   TimeLock: provider.upgradeToAndCall(newImpl, migrateFromCdp())   (Aster / Pendle / Sigma hardcoded)
// Then: their slisBNB sits in the provider, clisBNB is untouched, integrator flows never touch the CDP,
// CDP PROXY / migrator paths cannot move funds, and CDP dust cannot be withdrawn here.
// Run: forge test --mc ProviderV2Migration -vv

import "forge-std/Test.sol";
import {SlisBNBProvider} from "../../src/cdp/ceros/provider/SlisBNBProvider.sol";

interface IERC20M {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
interface IVatM {
    function urns(bytes32, address) external view returns (uint256, uint256);
}
interface IInteractionM {
    function collaterals(address) external view returns (address, bytes32, uint32, address);
    function locked(address, address) external view returns (uint256);
    function free(address, address) external view returns (uint256);
    function migrator() external view returns (address);
}
interface IProv {
    function upgradeToAndCall(address, bytes calldata) external payable;
    function userLp(address) external view returns (uint256);
    function userReservedLp(address) external view returns (uint256);
    function totalReservedLp() external view returns (uint256);
    function delegation(address) external view returns (address, uint256);
    function isUserLpSynced(address) external view returns (bool);
    function liquidation(address, uint256) external;
    function liquidation(address, address, uint256, bytes memory, bool) external;
    function daoBurn(address, uint256) external;
    function releaseFor(address, uint256) external returns (uint256);
    function release(address, uint256) external returns (uint256);
    function delegateAllTo(address) external;
    function withdrawLeftover() external;
}
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
    address constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant CLISBNB = 0x4b30fcAA7945fE9fDEFD2895aae539ba102Ed6F6;
    address constant TIMELOCK = 0x07D274a68393E8b8a2CCf19A2ce4Ba3518735253;
    address constant CORE_ADMIN = 0xAca0ed4651ddA1F43f00363643CFa5EBF8774b37;
    IVatM constant VAT = IVatM(0x33A34eAB3ee892D40420507B820347b1cA2201c4);
    IInteractionM constant I = IInteractionM(0xB68443Ee3e828baD1526b3e0Bdf2Dfc6b1975ec4);
    address constant ASTER = 0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2;
    address constant ASBNB_MINTER = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address constant PENDLE = 0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa;
    address constant SIGMA = 0x8B98563d66B74e5a644BFf78fC72c86bbA847a29;
    address constant RESERVE = 0xD57E5321e67607Fab38347D96394e0E58509C506; // lpReserveAddress
    address constant DUST = 0x2b334c9207BbEf33aE4495d3F0f32751118202eA; // ~0.01 slisBNB still locked in the CDP

    bytes32 ilk;
    address gemJoin;
    address[3] users;
    uint256[3] locked0;
    address[3] dele;
    address user;
    SlisBNBProvider p = SlisBNBProvider(PROVIDER);

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");
        (gemJoin, ilk,,) = I.collaterals(SLISBNB);
        users = [ASTER, PENDLE, SIGMA];
        for (uint256 i; i < 3; i++) {
            locked0[i] = I.locked(SLISBNB, users[i]);
            (dele[i],) = IProv(PROVIDER).delegation(users[i]);
            require(locked0[i] > 0, "served account has nothing in the CDP");
        }
        user = makeAddr("user");
        deal(SLISBNB, user, 10 ether);
        console2.log("fork block", block.number);
    }

    function _cutover() internal {
        SlisBNBProvider impl = new SlisBNBProvider();
        vm.prank(TIMELOCK);
        IProv(PROVIDER).upgradeToAndCall(address(impl), abi.encodeCall(SlisBNBProvider.migrateFromCdp, ()));
    }

    // after the cut-over the served flows must not reach the CDP at all
    function _cdpOff() internal {
        vm.mockCallRevert(address(I), bytes(""), bytes("CDP touched"));
    }

    function _inv() internal view {
        assertGe(IERC20M(SLISBNB).balanceOf(PROVIDER), p.totalDeposit(), "balance >= totalDeposit");
    }

    function _ink(address a) internal view returns (uint256 ink) { (ink,) = VAT.urns(ilk, a); }

    function test_cutoverMovesSlisBNBOnly() public {
        IERC20M clis = IERC20M(CLISBNB);
        uint256 gj0 = IERC20M(SLISBNB).balanceOf(gemJoin);
        uint256 pb0 = IERC20M(SLISBNB).balanceOf(PROVIDER);
        assertGt(IERC20M(SLISBNB).allowance(PROVIDER, address(I)), 0, "v1 allowance to Interaction");
        uint256[3] memory bal0; uint256[3] memory dBal0; uint256[3] memory lp0; uint256[3] memory rlp0; bool[3] memory sync0;
        for (uint256 i; i < 3; i++) {
            bal0[i] = clis.balanceOf(users[i]);
            dBal0[i] = clis.balanceOf(dele[i]);
            lp0[i] = IProv(PROVIDER).userLp(users[i]);
            rlp0[i] = IProv(PROVIDER).userReservedLp(users[i]);
            sync0[i] = IProv(PROVIDER).isUserLpSynced(users[i]);
            emit log_named_decimal_uint("CDP locked slisBNB", locked0[i], 18);
        }
        uint256 res0 = clis.balanceOf(RESERVE);
        uint256 sup0 = clis.totalSupply();
        uint256 tr0 = IProv(PROVIDER).totalReservedLp();

        _cutover();

        uint256 total;
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            total += locked0[i];
            assertEq(_ink(u), 0, "CDP urn emptied");
            assertEq(I.locked(SLISBNB, u), 0, "CDP locked");
            assertEq(p.userDeposit(u), locked0[i], "deposit credited");
            // clisBNB untouched
            assertEq(clis.balanceOf(u), bal0[i], "user clisBNB");
            assertEq(clis.balanceOf(dele[i]), dBal0[i], "delegatee clisBNB");
            assertEq(IProv(PROVIDER).userLp(u), lp0[i], "userLp");
            assertEq(IProv(PROVIDER).userReservedLp(u), rlp0[i], "userReservedLp");
            assertEq(IProv(PROVIDER).isUserLpSynced(u), sync0[i], "sync status");
        }
        assertEq(clis.balanceOf(RESERVE), res0, "reserve clisBNB");
        assertEq(clis.totalSupply(), sup0, "clisBNB supply");
        assertEq(IProv(PROVIDER).totalReservedLp(), tr0, "totalReservedLp");
        assertEq(IERC20M(SLISBNB).balanceOf(PROVIDER) - pb0, total, "provider received");
        assertEq(gj0 - IERC20M(SLISBNB).balanceOf(gemJoin), total, "left GemJoin");
        assertEq(p.totalDeposit(), total, "totalDeposit");
        assertEq(IERC20M(SLISBNB).allowance(PROVIDER, address(I)), 0, "allowance to Interaction revoked");
        _inv();
        emit log_named_decimal_uint("slisBNB moved out of CDP", total, 18);
        emit log_named_decimal_uint("clisBNB supply (unchanged)", sup0, 18);
    }

    function test_asterMintBurnAfterCutover() public {
        _cutover();
        _cdpOff();
        IAsBnbMinterM m = IAsBnbMinterM(ASBNB_MINTER);
        address asBnb = m.asBnb();
        uint256 b0 = p.userDeposit(ASTER);
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(ASBNB_MINTER, 1 ether);
        uint256 got = m.mintAsBnb(1 ether);
        assertEq(p.userDeposit(ASTER), b0 + 1 ether, "Aster +1");
        uint256 s0 = IERC20M(SLISBNB).balanceOf(user);
        IERC20M(asBnb).approve(ASBNB_MINTER, got);
        m.burnAsBnb(got);
        vm.stopPrank();
        uint256 back = IERC20M(SLISBNB).balanceOf(user) - s0;
        assertGt(back, 0);
        assertEq(p.userDeposit(ASTER), b0 + 1 ether - back, "Aster -back");
        // v1 rounds provide and release separately, so a wei of drift is normal; syncUserLp settles it
        // against userDeposit (the CDP is mocked to revert here)
        if (!IProv(PROVIDER).isUserLpSynced(ASTER)) p.syncUserLp(ASTER);
        assertTrue(IProv(PROVIDER).isUserLpSynced(ASTER), "Aster synced");
        _inv();
    }

    function _syRoundTrip(address sy) internal {
        uint256 b0 = p.userDeposit(sy);
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(sy, 1 ether);
        uint256 sh = ISYM(sy).deposit(user, SLISBNB, 1 ether, 0);
        assertEq(p.userDeposit(sy), b0 + 1 ether, "deposit");
        uint256 out = ISYM(sy).redeem(user, sh, SLISBNB, 0, false);
        vm.stopPrank();
        assertEq(out, 1 ether, "1:1 out");
        assertEq(p.userDeposit(sy), b0, "redeem");
        assertTrue(IProv(PROVIDER).isUserLpSynced(sy), "synced");
        _inv();
    }

    // ---------- user operations after the cut-over, through each integrator, with the CDP switched off ----------

    // clisBNB minted (or burned) for `amount` slisBNB: holder part plus reserve part
    function _lpFor(uint256 amount) internal view returns (uint256) {
        return amount * p.exchangeRate() / 1e18;
    }

    // clisBNB held by an integrator's delegatee plus lpReserveAddress (they are the same address for Aster)
    function _clis(address delegatee) internal view returns (uint256) {
        IERC20M c = IERC20M(CLISBNB);
        return delegatee == RESERVE ? c.balanceOf(RESERVE) : c.balanceOf(delegatee) + c.balanceOf(RESERVE);
    }

    function _logStep(string memory step, address integrator, address delegatee, uint256 slis, uint256 clis0) internal {
        console2.log(step);
        emit log_named_decimal_uint("    slisBNB moved", slis, 18);
        emit log_named_decimal_uint("    provider userDeposit after", p.userDeposit(integrator), 18);
        uint256 c1 = _clis(delegatee);
        if (c1 >= clis0) emit log_named_decimal_uint("    clisBNB minted (delegatee + reserve)", c1 - clis0, 18);
        else emit log_named_decimal_uint("    clisBNB burned (delegatee + reserve)", clis0 - c1, 18);
    }

    function _asterJourney(address u, address holder) internal {
        IAsBnbMinterM m = IAsBnbMinterM(ASBNB_MINTER);
        IERC20M asBnb = IERC20M(m.asBnb());
        address d = dele[0];
        console2.log("== Aster (AsBnbMinter -> YieldProxy -> provider)");
        vm.startPrank(u);
        IERC20M(SLISBNB).approve(ASBNB_MINTER, 5 ether);
        uint256 dep0 = p.userDeposit(ASTER);
        uint256 c0 = _clis(d);
        uint256 got = m.mintAsBnb(5 ether);
        assertEq(p.userDeposit(ASTER), dep0 + 5 ether, "Aster mint: deposit");
        assertEq(_clis(d) - c0, _lpFor(5 ether), "Aster mint: clisBNB");
        _logStep("1. new user mintAsBnb with 5 slisBNB", ASTER, d, 5 ether, c0);
        emit log_named_decimal_uint("    asBNB received", got, 18);

        asBnb.approve(ASBNB_MINTER, got);
        uint256[2] memory parts = [got / 2, got - got / 2];
        string[2] memory labels = ["2. burnAsBnb half (partial withdrawal)", "3. burnAsBnb the rest (full exit)"];
        for (uint256 i; i < 2; i++) {
            uint256 s0 = IERC20M(SLISBNB).balanceOf(u);
            dep0 = p.userDeposit(ASTER);
            c0 = _clis(d);
            m.burnAsBnb(parts[i]);
            uint256 back = IERC20M(SLISBNB).balanceOf(u) - s0;
            assertGt(back, 0, "Aster burn: slisBNB out");
            assertEq(dep0 - p.userDeposit(ASTER), back, "Aster burn: deposit");
            assertApproxEqAbs(c0 - _clis(d), _lpFor(back), 2, "Aster burn: clisBNB");
            _logStep(labels[i], ASTER, d, back, c0);
        }
        assertEq(asBnb.balanceOf(u), 0, "Aster: user fully out");
        vm.stopPrank();

        // an existing asBNB holder exits
        deal(address(asBnb), holder, 3 ether);
        vm.startPrank(holder);
        asBnb.approve(ASBNB_MINTER, 3 ether);
        dep0 = p.userDeposit(ASTER);
        c0 = _clis(d);
        m.burnAsBnb(3 ether);
        uint256 out = IERC20M(SLISBNB).balanceOf(holder);
        vm.stopPrank();
        assertGt(out, 0, "Aster holder: slisBNB out");
        assertEq(dep0 - p.userDeposit(ASTER), out, "Aster holder: deposit");
        _logStep("4. existing holder burnAsBnb 3 asBNB", ASTER, d, out, c0);
    }

    function _syJourney(string memory name, address sy, address d, address u, address holder) internal {
        console2.log(string.concat("== ", name, " (clisBNB SY -> provider)"));
        vm.startPrank(u);
        IERC20M(SLISBNB).approve(sy, 5 ether);
        uint256 dep0 = p.userDeposit(sy);
        uint256 c0 = _clis(d);
        uint256 sh = ISYM(sy).deposit(u, SLISBNB, 5 ether, 0);
        assertEq(p.userDeposit(sy), dep0 + 5 ether, "SY deposit: deposit");
        assertEq(_clis(d) - c0, _lpFor(5 ether), "SY deposit: clisBNB");
        _logStep("1. new user deposits 5 slisBNB", sy, d, 5 ether, c0);
        emit log_named_decimal_uint("    SY shares received", sh, 18);

        uint256[2] memory parts = [sh / 2, sh - sh / 2];
        string[2] memory labels = ["2. redeem half (partial withdrawal)", "3. redeem the rest (full exit)"];
        for (uint256 i; i < 2; i++) {
            dep0 = p.userDeposit(sy);
            c0 = _clis(d);
            uint256 out = ISYM(sy).redeem(u, parts[i], SLISBNB, 0, false);
            assertEq(out, parts[i], "SY redeem: 1:1");
            assertEq(dep0 - p.userDeposit(sy), out, "SY redeem: deposit");
            assertApproxEqAbs(c0 - _clis(d), _lpFor(out), 2, "SY redeem: clisBNB");
            _logStep(labels[i], sy, d, out, c0);
        }
        assertEq(IERC20M(SLISBNB).balanceOf(u), 10 ether, "SY: user got everything back");
        vm.stopPrank();

        // an existing SY holder exits
        deal(sy, holder, 3 ether);
        dep0 = p.userDeposit(sy);
        c0 = _clis(d);
        vm.prank(holder);
        uint256 got = ISYM(sy).redeem(holder, 3 ether, SLISBNB, 0, false);
        assertEq(got, 3 ether, "SY holder: 1:1");
        assertEq(dep0 - p.userDeposit(sy), 3 ether, "SY holder: deposit");
        _logStep("4. existing holder redeems 3 SY shares", sy, d, got, c0);
    }

    function test_userOperationsAfterCutover() public {
        _cutover();
        _cdpOff(); // any call into the CDP Interaction reverts from here on
        uint256 bal0 = IERC20M(SLISBNB).balanceOf(PROVIDER);
        uint256 tot0 = p.totalDeposit();
        address[3] memory us = [makeAddr("asterUser"), makeAddr("pendleUser"), makeAddr("sigmaUser")];
        for (uint256 i; i < 3; i++) deal(SLISBNB, us[i], 10 ether);

        _asterJourney(us[0], makeAddr("asterHolder"));
        _syJourney("Pendle", PENDLE, dele[1], us[1], makeAddr("pendleHolder"));
        _syJourney("Sigma", SIGMA, dele[2], us[2], makeAddr("sigmaHolder"));

        for (uint256 i; i < 3; i++) assertTrue(IProv(PROVIDER).isUserLpSynced(users[i]) || _syncedAfter(users[i]), "synced");
        uint256 paidOut = bal0 - IERC20M(SLISBNB).balanceOf(PROVIDER);
        assertEq(tot0 - p.totalDeposit(), paidOut, "totalDeposit tracks the provider balance");
        _inv();
        console2.log("== Summary");
        emit log_named_decimal_uint("    slisBNB paid out to existing holders (net)", paidOut, 18);
        emit log_named_decimal_uint("    provider slisBNB balance", IERC20M(SLISBNB).balanceOf(PROVIDER), 18);
        emit log_named_decimal_uint("    totalDeposit", p.totalDeposit(), 18);
    }

    // v1 rounds provide and release separately; a wei of drift is settled by syncUserLp (CDP still off)
    function _syncedAfter(address a) internal returns (bool) {
        p.syncUserLp(a);
        return IProv(PROVIDER).isUserLpSynced(a);
    }

    function test_pendleAfterCutover() public {
        _cutover();
        _cdpOff();
        _syRoundTrip(PENDLE);
    }

    function test_sigmaAfterCutover() public {
        _cutover();
        _cdpOff();
        _syRoundTrip(SIGMA);
    }

    function test_delegateAllToAfterCutover() public {
        _cutover();
        _cdpOff();
        address d = makeAddr("newDelegatee");
        vm.prank(PENDLE);
        IProv(PROVIDER).delegateAllTo(d);
        uint256 lp = IProv(PROVIDER).userLp(PENDLE); // after the sync inside delegateAllTo
        assertEq(IERC20M(CLISBNB).balanceOf(d), lp, "all clisBNB to new delegatee");
        (address to, uint256 amt) = IProv(PROVIDER).delegation(PENDLE);
        assertEq(to, d); assertEq(amt, lp);
    }

    function test_otherAccountCannotProvide() public {
        _cutover();
        vm.startPrank(user);
        IERC20M(SLISBNB).approve(PROVIDER, 1 ether);
        vm.expectRevert(bytes("not a served account"));
        p.provide(1 ether);
        vm.stopPrank();
    }

    function test_releaseAboveDepositReverts() public {
        _cutover();
        uint256 d = p.userDeposit(PENDLE);
        vm.prank(PENDLE);
        vm.expectRevert(bytes("insufficient deposit"));
        IProv(PROVIDER).release(PENDLE, d + 1);
    }

    function test_cdpPathsCannotMoveFunds() public {
        _cutover();
        address[2] memory proxies = [CORE_ADMIN, address(I)];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(proxies[i]);
            vm.expectRevert(bytes("liquidation disabled"));
            IProv(PROVIDER).liquidation(proxies[i], 1 ether);
            vm.expectRevert(bytes("liquidation disabled"));
            IProv(PROVIDER).liquidation(PENDLE, proxies[i], 1 ether, "", false);
            vm.expectRevert(bytes("daoBurn disabled"));
            IProv(PROVIDER).daoBurn(PENDLE, 1 ether);
            vm.stopPrank();
        }
        address mig = I.migrator();
        if (mig != address(0)) vm.prank(mig);
        vm.expectRevert(bytes("releaseFor disabled"));
        IProv(PROVIDER).releaseFor(PENDLE, 1 ether);
        _inv();
    }

    // CDP dust is not handled: none of it can be withdrawn through the provider
    function test_cdpDustCannotWithdraw() public {
        uint256 l = I.locked(SLISBNB, DUST);
        require(l > 0, "dust account no longer in CDP; pick another");
        _cutover();
        assertEq(p.userDeposit(DUST), 0, "dust has no deposit here");
        uint256 pb = IERC20M(SLISBNB).balanceOf(PROVIDER);
        uint256 lp = IProv(PROVIDER).userLp(DUST);
        uint256 rlp = IProv(PROVIDER).userReservedLp(DUST);
        require(lp > 0, "dust account holds no clisBNB; pick another");
        // anyone calling syncUserLp must not burn the dust account's clisBNB
        assertTrue(IProv(PROVIDER).isUserLpSynced(DUST), "dust reads synced");
        vm.expectRevert(bytes("already synced"));
        p.syncUserLp(DUST);
        assertEq(IProv(PROVIDER).userLp(DUST), lp, "dust clisBNB kept");
        assertEq(IProv(PROVIDER).userReservedLp(DUST), rlp, "dust reserve kept");
        vm.startPrank(DUST);
        vm.expectRevert(bytes("insufficient deposit"));
        IProv(PROVIDER).release(DUST, l);
        vm.expectRevert(bytes("withdrawLeftover disabled"));
        IProv(PROVIDER).withdrawLeftover();
        vm.stopPrank();
        assertEq(I.locked(SLISBNB, DUST), l, "dust left in CDP");
        assertEq(IERC20M(SLISBNB).balanceOf(PROVIDER), pb, "provider untouched");
        _inv();
    }

    // CDP no longer on the path: a week with no oracle updates does not matter.
    function test_flowsIgnoreStaleCdpOracle() public {
        _cutover();
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 28800);
        _syRoundTrip(PENDLE);
        uint256 all = p.userDeposit(SIGMA);
        uint256 s0 = IERC20M(SLISBNB).balanceOf(SIGMA);
        vm.prank(SIGMA);
        IProv(PROVIDER).release(SIGMA, all);
        assertEq(IERC20M(SLISBNB).balanceOf(SIGMA) - s0, all, "Sigma full exit");
        assertEq(IProv(PROVIDER).userLp(SIGMA), 0, "clisBNB cleared on full exit");
        _inv();
    }

    // An integrator that fully exits during the TimeLock delay is skipped, not a revert.
    function test_cutoverSkipsEmptyAccount() public {
        vm.mockCall(address(I), abi.encodeCall(IInteractionM.locked, (SLISBNB, SIGMA)), abi.encode(uint256(0)));
        _cutover();
        vm.clearMockedCalls();
        assertEq(p.userDeposit(SIGMA), 0, "empty account skipped");
        assertEq(I.locked(SLISBNB, SIGMA), locked0[2], "Sigma left in CDP untouched");
        for (uint256 i; i < 2; i++) assertEq(p.userDeposit(users[i]), locked0[i], "others migrated");
    }

    // Short delivery by the CDP aborts the whole upgrade.
    function test_cutoverRevertsOnShortDelivery() public {
        vm.mockCall(
            address(I),
            abi.encodeWithSignature("withdraw(address,address,uint256)", ASTER, SLISBNB, locked0[0]),
            abi.encode(locked0[0])
        );
        SlisBNBProvider impl = new SlisBNBProvider();
        vm.prank(TIMELOCK);
        vm.expectRevert(bytes("migrate amount mismatch"));
        IProv(PROVIDER).upgradeToAndCall(address(impl), abi.encodeCall(SlisBNBProvider.migrateFromCdp, ()));
    }

    function test_cutoverOnlyOnce() public {
        _cutover();
        vm.prank(TIMELOCK);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        p.migrateFromCdp();
    }
}
