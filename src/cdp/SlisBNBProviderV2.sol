// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SlisBNBProvider} from "lista-dao-contracts/contracts/ceros/provider/SlisBNBProvider.sol";

interface ISlisBNBxMinterLike {
    function rebalance(address account) external returns (bool, uint256);
    function syncDelegatee(address account, address newDelegatee) external;
    function delegation(address account) external view returns (address);
}

interface IStakeManagerLike {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

/**
 * @title SlisBNBProviderV2 (DRAFT, not audited)
 * @notice Standalone Launchpool provider. Same proxy address as the CDP SlisBNBProvider, so integrators
 *         (Aster YieldProxy, Pendle/Sigma clisBNB SY) keep calling provide/release/delegateAllTo unchanged.
 *         slisBNB is held by this contract instead of being deposited into the CDP Interaction contract, and
 *         clisBNB (= slisBNBx) is minted through SlisBNBxMinter, with this contract registered as a module.
 *
 * Storage: inherits the CDP SlisBNBProvider layout unchanged and only appends new variables.
 *
 * Cut-over: TimeLock calls upgradeToAndCall(V2, migrateFromCdp(users)) in one tx:
 *   per user: Interaction.withdraw(user, slisBNB, locked) pays the slisBNB to this contract (we are the
 *   registered helio provider), the user's balance is credited here, the legacy clisBNB (user / delegatee /
 *   lpReserve parts) is burned, the delegatee is written to the minter and the minter mints slisBNBx.
 * Users not migrated (CDP dust) keep their CDP position; they cannot use provide/release here.
 */
contract SlisBNBProviderV2 is SlisBNBProvider {
    using SafeERC20 for IERC20;

    ISlisBNBxMinterLike public immutable SLISBNBX_MINTER;
    IStakeManagerLike public immutable STAKE_MANAGER;

    /* ---------------- appended storage (after SlisBNBProvider.totalReservedLp) ---------------- */
    /// @dev slisBNB held by this contract for each account
    mapping(address => uint256) public userBalance;
    /// @dev sum of userBalance
    uint256 public totalBalance;
    /// @dev deposit allow-list (the CDP Interaction whitelist no longer applies)
    mapping(address => bool) public depositWhitelist;

    event MigratedFromCdp(address indexed account, uint256 amount);
    event DepositWhitelistSet(address indexed account, bool allowed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _minter, address _stakeManager) SlisBNBProvider() {
        require(_minter != address(0) && _stakeManager != address(0), "zero address");
        SLISBNBX_MINTER = ISlisBNBxMinterLike(_minter);
        STAKE_MANAGER = IStakeManagerLike(_stakeManager);
    }

    /* ----------------------------------- cut-over ----------------------------------- */

    /**
     * @notice One-time move of the given accounts' slisBNB out of the CDP into this contract.
     * @dev Called through upgradeToAndCall by DEFAULT_ADMIN (TimeLock). Each account's whole CDP `locked`
     *      balance is withdrawn; the account must have no CDP debt (Interaction enforces it).
     *      The SlisBNBxMinter must already list this contract as a module.
     */
    function migrateFromCdp(address[] calldata accounts, address[] calldata whitelist)
        external
        reinitializer(2)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i = 0; i < whitelist.length; i++) {
            depositWhitelist[whitelist[i]] = true;
            emit DepositWhitelistSet(whitelist[i], true);
        }
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            uint256 amount = dao.locked(token, account);
            require(amount > 0, "nothing to migrate");
            uint256 before = IERC20(token).balanceOf(address(this));
            dao.withdraw(account, token, amount);
            require(IERC20(token).balanceOf(address(this)) - before == amount, "migrate amount mismatch");
            userBalance[account] += amount;
            totalBalance += amount;
            _sync(account, address(0));
            emit MigratedFromCdp(account, amount);
        }
    }

    /* ----------------------------------- user flows ----------------------------------- */

    function provide(uint256 _amount) external override whenNotPaused nonReentrant returns (uint256) {
        _deposit(msg.sender, _amount, address(0));
        return _amount;
    }

    /// @dev same rule as V1: the delegatee can only change while the account holds nothing here
    function provide(uint256 _amount, address _delegateTo)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        require(_delegateTo != address(0), "delegateTo cannot be zero address");
        require(_delegateTo != msg.sender, "delegateTo cannot be self");
        address current = _currentDelegatee(msg.sender);
        require(
            current == _delegateTo || userBalance[msg.sender] == 0,
            "delegateTo is differ from the current one"
        );
        _deposit(msg.sender, _amount, _delegateTo);
        return _amount;
    }

    function release(address _recipient, uint256 _amount)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        require(_recipient != address(0), "zero recipient");
        require(_amount > 0, "zero withdrawal amount");
        require(userBalance[msg.sender] >= _amount, "insufficient balance");
        userBalance[msg.sender] -= _amount;
        totalBalance -= _amount;
        _sync(msg.sender, address(0));
        IERC20(token).safeTransfer(_recipient, _amount);
        emit Withdrawal(msg.sender, _recipient, _amount);
        return _amount;
    }

    function delegateAllTo(address _newDelegateTo) external override whenNotPaused nonReentrant {
        require(_newDelegateTo != address(0), "delegateTo cannot be zero address");
        require(userBalance[msg.sender] > 0, "zero balance to delegate");
        address old = _currentDelegatee(msg.sender);
        _sync(msg.sender, _newDelegateTo);
        emit ChangeDelegateTo(msg.sender, old, _newDelegateTo);
    }

    /// @notice permissionless re-sync of an account's slisBNBx with its balance here
    function syncSlisBNBx(address account) external {
        _sync(account, address(0));
    }

    /// @notice SlisBNBxMinter module callback
    function getUserBalanceInBnb(address account) external view returns (uint256) {
        return STAKE_MANAGER.convertSnBnbToBnb(userBalance[account]);
    }

    function setDepositWhitelist(address[] calldata accounts, bool allowed) external onlyRole(MANAGER) {
        for (uint256 i = 0; i < accounts.length; i++) {
            depositWhitelist[accounts[i]] = allowed;
            emit DepositWhitelistSet(accounts[i], allowed);
        }
    }

    /* ------------------------ CDP paths disabled after the cut-over ------------------------ */

    /// @dev PROXY holders (Interaction, CDP Core Admin Safe) could otherwise move the slisBNB now held here
    function liquidation(address, uint256) public pure override {
        revert("V2: liquidation disabled");
    }

    function daoBurn(address, uint256) external pure override {
        revert("V2: daoBurn disabled");
    }

    /// @dev only reachable from releaseFor (migrator path); release() is overridden above
    function _withdrawLp(address, uint256) internal pure override {
        revert("V2: CDP withdraw disabled");
    }

    /* ----------------------------------- internals ----------------------------------- */

    function _deposit(address account, uint256 amount, address delegateTo) internal {
        require(amount > 0, "zero deposit amount");
        require(depositWhitelist[account], "not in deposit whitelist");
        IERC20(token).safeTransferFrom(account, address(this), amount);
        userBalance[account] += amount;
        totalBalance += amount;
        _sync(account, delegateTo);
        emit Deposit(account, amount, amount);
    }

    function _currentDelegatee(address account) internal view returns (address d) {
        d = SLISBNBX_MINTER.delegation(account);
        if (d == address(0)) d = delegation[account].delegateTo; // legacy record not yet moved
    }

    /**
     * @dev 1) burn any legacy clisBNB this contract minted for the account (user part, delegatee part,
     *         lpReserve part) and move the legacy delegatee into the minter;
     *      2) optionally switch the delegatee (minter moves the account's whole slisBNBx);
     *      3) minter re-mints slisBNBx from getUserBalanceInBnb.
     */
    function _sync(address account, address newDelegatee) internal {
        uint256 up = userLp[account];
        uint256 rp = userReservedLp[account];
        if (up > 0 || rp > 0) {
            if (rp > 0) {
                lpToken.burn(lpReserveAddress, rp);
                userReservedLp[account] = 0;
                totalReservedLp -= rp;
            }
            uint256 da = delegation[account].amount;
            address legacyDelegatee = delegation[account].delegateTo;
            if (da > 0) lpToken.burn(legacyDelegatee, da);
            if (up > da) _safeBurnLp(account, up - da);
            userLp[account] = 0;
            delete delegation[account];
            if (legacyDelegatee != address(0) && legacyDelegatee != account && newDelegatee == address(0)) {
                newDelegatee = legacyDelegatee;
            }
        }
        if (newDelegatee != address(0)) {
            SLISBNBX_MINTER.syncDelegatee(account, newDelegatee);
        }
        SLISBNBX_MINTER.rebalance(account);
    }
}
