// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SurfinTestBase.sol";
import "../../src/surfin/BpnEarnPool.sol";

/**
 * Stateful handler driving random BpnEarnPool + adapter lifecycles: deposits, share
 * transfer attempts (always rejected), escrowed requests, cash pushed by the adapter, partial settlements (duplicate
 * ids included), claims, deploys to the partner and recalls. Every action is bounded so it
 * never reverts spuriously. adminTopUp is left out: it may park quota above the escrow by
 * design.
 */
contract BpnInvariantHandler is Test {
  MockERC20 usdt;
  SurfinAdapter adapter;
  BpnEarnPool pool;
  address bot;
  address manager;
  address wallet;
  address[] internal actors;
  uint256[] public ids;

  uint256 public ghostDeposited;
  uint256 public ghostRecalled;
  uint256 public ghostDeployed;
  uint256 public ghostClaimed;
  // shares each actor should hold: deposits less requests (positions never move)
  mapping(address => uint256) public ghostHeld;
  // transfers between holders that went through; must stay 0
  uint256 public ghostTransfers;

  constructor(
    MockERC20 _usdt,
    SurfinAdapter _adapter,
    BpnEarnPool _pool,
    address _bot,
    address _manager,
    address _wallet
  ) {
    usdt = _usdt;
    adapter = _adapter;
    pool = _pool;
    bot = _bot;
    manager = _manager;
    wallet = _wallet;
    actors.push(makeAddr("bpn_actor_1"));
    actors.push(makeAddr("bpn_actor_2"));
    actors.push(makeAddr("bpn_actor_3"));
  }

  function actorsLength() external view returns (uint256) {
    return actors.length;
  }

  function actorAt(uint256 i) external view returns (address) {
    return actors[i];
  }

  function idsLength() external view returns (uint256) {
    return ids.length;
  }

  function deposit(uint256 actorSeed, uint256 amount) public {
    address a = actors[actorSeed % actors.length];
    amount = bound(amount, 1e18, 1_000_000e18);
    usdt.mint(a, amount);
    vm.startPrank(a);
    usdt.approve(address(pool), amount);
    pool.deposit(amount, a);
    vm.stopPrank();
    ghostDeposited += amount;
    ghostHeld[a] += amount;
  }

  function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
    address from = actors[fromSeed % actors.length];
    address to = actors[toSeed % actors.length];
    uint256 bal = pool.balanceOf(from);
    if (bal == 0) return;
    amount = bound(amount, 1, bal);
    vm.prank(from);
    try pool.transfer(to, amount) {
      ghostTransfers++;
    } catch {}
  }

  function request(uint256 actorSeed, uint256 amount) public {
    address a = actors[actorSeed % actors.length];
    uint256 bal = pool.balanceOf(a);
    if (bal == 0) return;
    amount = bound(amount, 1, bal);
    vm.prank(a);
    ids.push(pool.requestRedeem(amount));
    ghostHeld[a] -= amount;
  }

  function push(uint256 amount) public {
    uint256 avail = adapter.instantWithdrawable();
    uint256 escrow = pool.totalEscrowed();
    uint256 quota = pool.withdrawQuota();
    uint256 room = escrow > quota ? escrow - quota : 0;
    uint256 max = avail < room ? avail : room;
    if (max == 0) return;
    amount = bound(amount, 1, max);
    vm.prank(bot);
    adapter.finishFlexWithdraw(amount);
  }

  /// @dev settles up to three requests from `seed`, sometimes the same one twice, within
  ///      the funded quota and each request's escrow.
  function settle(uint256 seed, uint256 amount) public {
    if (ids.length == 0) return;
    uint256 budget = pool.withdrawQuota();
    if (budget == 0) return;
    uint256[] memory sel = new uint256[](3);
    uint256[] memory amt = new uint256[](3);
    uint256 n;
    for (uint256 k = 0; k < 3 && budget > 0; k++) {
      uint256 id = ids[((seed % ids.length) + (k == 2 ? 0 : k)) % ids.length]; // k == 2 repeats the first id
      (, , , uint256 pending, ) = pool.requests(id);
      for (uint256 m = 0; m < n; m++) {
        if (sel[m] == id) pending -= amt[m];
      }
      if (pending == 0) continue;
      uint256 cap = pending < budget ? pending : budget;
      uint256 s = bound(uint256(keccak256(abi.encode(amount, k))), 1, cap);
      sel[n] = id;
      amt[n] = s;
      budget -= s;
      n++;
    }
    if (n == 0) return;
    uint256[] memory sIds = new uint256[](n);
    uint256[] memory sAmt = new uint256[](n);
    for (uint256 m = 0; m < n; m++) {
      (sIds[m], sAmt[m]) = (sel[m], amt[m]);
    }
    vm.prank(bot);
    pool.settleRedeem(sIds, sAmt);
  }

  function claim(uint256 seed, uint256 count) public {
    if (ids.length == 0) return;
    count = bound(count, 1, ids.length);
    uint256[] memory c = new uint256[](count);
    uint256 owed;
    for (uint256 k = 0; k < count; k++) {
      c[k] = ids[((seed % ids.length) + k) % ids.length];
      bool dup;
      for (uint256 m = 0; m < k; m++) {
        if (c[m] == c[k]) dup = true;
      }
      if (!dup) {
        (, , , , uint256 claimable) = pool.requests(c[k]);
        owed += claimable;
      }
    }
    pool.claimRedeem(c);
    ghostClaimed += owed;
  }

  function deploy(uint256 amount) public {
    uint256 max = adapter.maxDeployToSurfin();
    if (max == 0) return;
    amount = bound(amount, 1, max);
    vm.prank(manager);
    adapter.deployToSurfin(amount);
    ghostDeployed += amount;
  }

  /// @dev the partner sends cash back; the book is reset to what it still holds
  function recall(uint256 amount) public {
    uint256 held = usdt.balanceOf(wallet);
    if (held == 0) return;
    amount = bound(amount, 1, held);
    vm.prank(wallet);
    usdt.transfer(manager, amount);
    vm.startPrank(manager);
    usdt.approve(address(adapter), amount);
    adapter.settleRecall(amount, 0, 0, held - amount);
    vm.stopPrank();
    ghostRecalled += amount;
  }
}

contract BpnEarnPoolInvariant is SurfinTestBase {
  BpnEarnPool pool;
  BpnInvariantHandler handler;

  function setUp() public override {
    super.setUp();
    BpnEarnPool impl = new BpnEarnPool();
    pool = BpnEarnPool(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeWithSelector(
            impl.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(usdt),
            address(this),
            "BPN",
            "BPN"
          )
        )
      )
    );
    adapter = SurfinAdapter(
      address(
        new ERC1967Proxy(
          address(new SurfinAdapter(address(usdt))),
          abi.encodeWithSelector(
            SurfinAdapter.initialize.selector,
            admin,
            manager,
            pauser,
            bot,
            address(pool),
            address(0),
            surfinWallet
          )
        )
      )
    );
    vm.prank(admin);
    pool.setAdapter(address(adapter));
    vm.startPrank(manager);
    adapter.setFloorRate(0);
    pool.setCap(type(uint256).max);
    vm.stopPrank();

    handler = new BpnInvariantHandler(usdt, adapter, pool, bot, manager, surfinWallet);
    targetContract(address(handler));
    bytes4[] memory actions = new bytes4[](8);
    actions[0] = handler.deposit.selector;
    actions[1] = handler.transfer.selector;
    actions[2] = handler.request.selector;
    actions[3] = handler.push.selector;
    actions[4] = handler.settle.selector;
    actions[5] = handler.claim.selector;
    actions[6] = handler.deploy.selector;
    actions[7] = handler.recall.selector;
    targetSelector(FuzzSelector({ addr: address(handler), selectors: actions }));
  }

  function _sums() internal view returns (uint256 pending, uint256 claimable) {
    uint256 n = handler.idsLength();
    for (uint256 i = 0; i < n; i++) {
      (, , , uint256 p, uint256 c) = pool.requests(handler.ids(i));
      pending += p;
      claimable += c;
    }
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 64
  function invariant_escrowMatchesRequests() public view {
    (uint256 pending, uint256 claimable) = _sums();
    assertEq(pool.balanceOf(address(pool)), pool.totalEscrowed(), "escrow balance");
    assertEq(pool.totalEscrowed(), pending, "escrow == sum of pending");
    assertEq(pool.totalConfirmedUnclaimed(), claimable, "confirmed == sum of claimable");
    assertEq(pool.totalPendingWithdraw(), pool.totalEscrowed() + pool.totalConfirmedUnclaimed(), "pending split");
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 64
  function invariant_sharesStayWithTheirDepositor() public view {
    assertEq(handler.ghostTransfers(), 0, "a share moved between holders");
    for (uint256 i = 0; i < handler.actorsLength(); i++) {
      address a = handler.actorAt(i);
      assertEq(pool.balanceOf(a), handler.ghostHeld(a), "position left its depositor");
    }
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 64
  function invariant_poolCashBacksQuotaAndClaims() public view {
    assertEq(usdt.balanceOf(address(pool)), pool.withdrawQuota() + pool.totalConfirmedUnclaimed(), "pool cash");
    assertLe(pool.withdrawQuota(), pool.totalEscrowed(), "quota above the escrow");
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 64
  function invariant_adapterReadsTheUncoveredEscrow() public view {
    assertEq(adapter.onDemandUnfunded(), pool.totalEscrowed() - pool.withdrawQuota(), "unfunded queue");
    assertEq(pool.totalPrincipal(), pool.totalSupply() - pool.totalEscrowed(), "earning principal");
    // the queue stays payable: idle cash never drops below the uncovered escrow unless it
    // is at the partner, i.e. deploys never took cash the queue needed
    assertGe(adapter.idleBalance() + usdt.balanceOf(surfinWallet), adapter.onDemandUnfunded(), "queue unbacked");
  }

  /// forge-config: default.invariant.runs = 64
  /// forge-config: default.invariant.depth = 64
  function invariant_cashIsConserved() public view {
    assertEq(
      handler.ghostDeposited() + handler.ghostRecalled(),
      adapter.idleBalance() + usdt.balanceOf(address(pool)) + handler.ghostDeployed() + handler.ghostClaimed(),
      "cash created or lost"
    );
  }
}
