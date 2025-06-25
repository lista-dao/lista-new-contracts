// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ILendingRewardsDistributorV2 } from "../src/interface/ILendingRewardsDistributorV2.sol";
import { MockERC20 } from "../src/mock/MockERC20.sol";
import { RewardsRouter } from "../src/RewardsRouter.sol";

contract RewardsRouterTest is Test {
  MockERC20 lista;
  MockERC20 lisUSD;
  address distributor1 = makeAddr("distributor1");
  address distributor2 = makeAddr("distributor2");

  RewardsRouter router;

  address admin = makeAddr("admin");
  address bot = makeAddr("bot");
  address manager = makeAddr("manager");
  address pauser = makeAddr("pauser");

  event SetDistributorWhitelist(address indexed distributor, bool whitelisted);
  event TransferRewards(address indexed distributor, address indexed token, uint256 amount);

  function setUp() public {
    lista = new MockERC20("lista", "lista");
    lisUSD = new MockERC20("lisUSD", "lisUSD");

    RewardsRouter distributorImpl = new RewardsRouter();

    address[] memory distributors = new address[](2);
    distributors[0] = distributor1;
    distributors[1] = distributor2;

    ERC1967Proxy proxy_ = new ERC1967Proxy(
      address(distributorImpl),
      abi.encodeWithSelector(RewardsRouter.initialize.selector, admin, manager, bot, pauser, distributors)
    );

    router = RewardsRouter(address(proxy_));
    assertTrue(router.distributors(distributor1));
    assertTrue(router.distributors(distributor2));

    assertTrue(router.hasRole(router.MANAGER(), manager));
    assertTrue(router.hasRole(router.BOT(), bot));
    assertTrue(router.hasRole(router.PAUSER(), pauser));
  }

  function test_transferRewards() public {
    deal(address(lista), address(router), 100 ether);
    vm.startPrank(bot);
    vm.expectRevert("Token not supported by distributor");
    vm.mockCall(
      distributor1,
      abi.encodeWithSelector(ILendingRewardsDistributorV2.tokens.selector, address(lista)),
      abi.encode(false) // not whitelisted token
    );
    router.transferRewards(address(lista), distributor1, 100 ether); // revert on not whitelisted token

    vm.mockCall(
      distributor1,
      abi.encodeWithSelector(ILendingRewardsDistributorV2.tokens.selector, address(lista)),
      abi.encode(true) // whitelisted token
    );

    vm.expectEmit(true, true, true, true);
    emit TransferRewards(distributor1, address(lista), 100 ether);
    router.transferRewards(address(lista), distributor1, 100 ether); // success

    assertEq(0, lista.balanceOf(address(router)));
    assertEq(100 ether, lista.balanceOf(distributor1));
  }

  function test_batchTransferRewards() public {
    deal(address(lista), address(router), 100 ether);
    deal(address(lisUSD), address(router), 100 ether);
    vm.startPrank(bot);

    address[] memory distributors = new address[](2);
    distributors[0] = distributor1;
    distributors[1] = distributor1;

    address[] memory tokens = new address[](2);
    tokens[0] = address(lista);
    tokens[1] = address(lisUSD);

    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100 ether;
    amounts[1] = 100 ether;

    vm.mockCall(
      distributor1,
      abi.encodeWithSelector(ILendingRewardsDistributorV2.tokens.selector, address(lista)),
      abi.encode(true) // whitelisted LISTA token
    );

    vm.mockCall(
      distributor1,
      abi.encodeWithSelector(ILendingRewardsDistributorV2.tokens.selector, address(lisUSD)),
      abi.encode(true) // whitelisted lisUSD token
    );

    vm.expectEmit(true, true, true, true);
    emit TransferRewards(distributor1, address(lista), 100 ether);
    emit TransferRewards(distributor2, address(lista), 100 ether);

    router.batchTransferRewards(tokens, distributors, amounts); // success

    assertEq(0, lista.balanceOf(address(router)));
    assertEq(0, lisUSD.balanceOf(address(router)));
    assertEq(100 ether, lista.balanceOf(distributor1));
    assertEq(100 ether, lisUSD.balanceOf(distributor1));
  }

  function test_setDistributorWhitelist() public {
    vm.startPrank(manager);
    address[] memory distributors = new address[](2);
    distributors[0] = address(0);
    distributors[1] = distributor1;
    bool[] memory status = new bool[](2);
    status[0] = true;
    status[1] = false;
    vm.expectRevert("Invalid distributor address");
    router.setDistributorWhitelist(distributors, status);

    distributors[0] = distributor1;
    distributors[1] = makeAddr("distributor3");
    status[0] = false;
    status[1] = true;

    router.setDistributorWhitelist(distributors, status);

    assertTrue(!router.distributors(distributor1));
    assertTrue(router.distributors(makeAddr("distributor3")));
  }

  function test_emergencyWithdraw() public {
    deal(address(lista), address(router), 99 ether);

    vm.expectRevert();
    router.emergencyWithdraw(address(lista));

    vm.prank(manager);
    router.emergencyWithdraw(address(lista)); // success

    assertEq(99 ether, lista.balanceOf(address(manager)));
    assertEq(0, lista.balanceOf(address(router)));
  }
}
