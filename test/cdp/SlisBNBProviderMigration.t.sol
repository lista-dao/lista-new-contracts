// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Fork simulation of the SlisBNBProvider CDP exit (draft impl, not audited).
//   TimeLock: provider.upgradeToAndCall(newImpl, migrateFromCdp())   (Aster / Pendle / Sigma hardcoded)
// Then: their slisBNB sits in the provider, clisBNB is untouched, integrator flows never touch the CDP,
// CDP PROXY / migrator paths cannot move funds, and CDP dust accounts behave as before.
// Run: BSC_RPC=<rpc> forge test --mc ProviderV2Migration -vv

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
        vm.createSelectFork(vm.envString("BSC_RPC"));
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

    // CDP dust: reads stay on dao.locked (same as v1), and it cannot draw on the provider's balance
    function test_cdpDustUnchanged() public {
        uint256 l = I.locked(SLISBNB, DUST);
        require(l > 0, "dust account no longer in CDP; pick another");
        bool s0 = IProv(PROVIDER).isUserLpSynced(DUST);
        _cutover();
        assertEq(p.userDeposit(DUST), l, "dust reads CDP locked");
        assertEq(IProv(PROVIDER).isUserLpSynced(DUST), s0, "dust sync status");
        assertEq(I.locked(SLISBNB, DUST), l, "dust left in CDP");
        vm.prank(DUST);
        vm.expectRevert(bytes("insufficient deposit"));
        IProv(PROVIDER).release(DUST, l);
    }

    // withdrawLeftover pays what actually arrived, not what the CDP returns
    function test_withdrawLeftoverPaysOnlyWhatArrives() public {
        _cutover();
        vm.mockCall(address(I), abi.encodeCall(IInteractionM.free, (SLISBNB, user)), abi.encode(uint256(1 ether)));
        vm.mockCall(
            address(I),
            abi.encodeWithSignature("withdraw(address,address,uint256)", user, SLISBNB, 1 ether),
            abi.encode(uint256(1 ether))
        );
        uint256 pb = IERC20M(SLISBNB).balanceOf(PROVIDER);
        uint256 ub = IERC20M(SLISBNB).balanceOf(user);
        vm.prank(user);
        IProv(PROVIDER).withdrawLeftover();
        assertEq(IERC20M(SLISBNB).balanceOf(user), ub, "nothing paid");
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
