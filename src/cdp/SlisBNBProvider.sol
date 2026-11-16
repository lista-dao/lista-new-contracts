// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDao} from "lista-dao-contracts/contracts/ceros/interfaces/IDao.sol";
import {ILpToken} from "lista-dao-contracts/contracts/ceros/interfaces/ILpToken.sol";
import {BaseTokenProvider} from "lista-dao-contracts/contracts/ceros/provider/BaseTokenProvider.sol";

/**
 * @title SlisBNBProvider
 * @dev In comparison to BaseLpTokenProvider, SlisBNBLpProvider has two major differences:
 * 1. token to lpToken rate is not 1:1 and modifiable
 * 2. user's lpToken will be minted to itself(delegatee) and lpReserveAddress according to userLpRate
 *
 * CDP exit (v2): the provider holds the slisBNB itself instead of depositing it into the CDP.
 * It serves exactly three accounts, hardcoded below. migrateFromCdp() moves their slisBNB out of the CDP
 * once, at upgrade. Amounts and rates do not change, so clisBNB is neither minted nor burned by it.
 * Other accounts (CDP dust) keep their CDP position: reads stay on dao.locked, release reverts.
 */
contract SlisBNBProvider is BaseTokenProvider {
    using SafeERC20 for IERC20;
    // token to lpToken exchange rate
    uint128 public exchangeRate;
    // rate of lpToken to user when deposit
    uint128 public userLpRate;
    // should be a mpc wallet address
    address public lpReserveAddress;
    // user account > sum reserved lpToken
    mapping(address => uint256) public userReservedLp;
    // total reserved lpToken
    uint256 public totalReservedLp;
    // v2: slisBNB held by this contract per served account (read through userDeposit)
    mapping(address => uint256) internal _userDeposit;
    // v2: sum of _userDeposit; invariant: token.balanceOf(this) >= totalDeposit
    uint256 public totalDeposit;

    // v2: the only accounts this provider serves; changing the set needs a new implementation
    address public constant ASTER = 0xE861dd4b0AB6f3a42943e6EF441c3C611CD1bec2; // Aster YieldProxy
    address public constant PENDLE = 0x27FaF900007B4cBa7803000251ec96Bc69ff1BEa; // PendleClisBNBSY
    address public constant SIGMA = 0x8B98563d66B74e5a644BFf78fC72c86bbA847a29; // SigmaClisBNBSY

    /**
     * Events
     */
    event SyncUserLpWithReserve(address account, uint256 userLp, uint256 reservedLp);
    event ChangeExchangeRate(uint128 rate);
    event ChangeUserLpRate(uint128 rate);
    event ChangeLpReserveAddress(address newAddress);
    event Migrated(address indexed account, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin,
        address _manager,
        address _proxy,
        address _pauser,
        address _lpToken,
        address _token,
        address _daoAddress,
        address _lpReserveAddress,
        uint128 _exchangeRate,
        uint128 _userLpRate
    ) public initializer {
        require(_admin != address(0), "admin is the zero address");
        require(_manager != address(0), "manager is the zero address");
        require(_proxy != address(0), "proxy is the zero address");
        require(_pauser != address(0), "pauser is the zero address");
        require(_lpToken != address(0), "lpToken is the zero address");
        require(_token != address(0), "token is the zero address");
        require(_daoAddress != address(0), "daoAddress is the zero address");
        require(_lpReserveAddress != address(0), "lpReserveAddress is the zero address");
        require(_exchangeRate > 0, "exchangeRate invalid");
        require(_userLpRate <= 1e18, "too big rate number");

        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER, _manager);
        _grantRole(PROXY, _proxy);
        _grantRole(PAUSER, _pauser);

        token = _token;
        lpToken = ILpToken(_lpToken);
        dao = IDao(_daoAddress);
        lpReserveAddress = _lpReserveAddress;
        exchangeRate = _exchangeRate;
        userLpRate = _userLpRate;

        IERC20(token).approve(_daoAddress, type(uint256).max);
    }

    /**
     * @dev v2 cut-over, run once through upgradeToAndCall by DEFAULT_ADMIN (TimeLock).
     *      Moves each served account's whole CDP `locked` slisBNB into this contract. Only the balance delta
     *      is trusted. An account with nothing locked is skipped, so an integrator that fully exits during
     *      the TimeLock delay does not block execution. The slisBNB allowance to the CDP is revoked.
     */
    function migrateFromCdp() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        address[3] memory accounts = [ASTER, PENDLE, SIGMA];
        for (uint256 i = 0; i < 3; i++) {
            address account = accounts[i];
            uint256 amount = dao.locked(token, account);
            if (amount == 0) continue;
            uint256 before = IERC20(token).balanceOf(address(this));
            dao.withdraw(account, token, amount);
            require(IERC20(token).balanceOf(address(this)) - before == amount, "migrate amount mismatch");
            _userDeposit[account] = amount;
            totalDeposit += amount;
            emit Migrated(account, amount);
        }
        IERC20(token).safeApprove(address(dao), 0);
    }

    /**
     * @dev slisBNB position of an account: what this contract holds for a served account,
     *      the CDP `locked` balance for anyone else (CDP dust, unchanged from v1)
     */
    function userDeposit(address _account) public view returns (uint256) {
        return _isServed(_account) ? _userDeposit[_account] : dao.locked(token, _account);
    }

    function _isServed(address _account) internal pure returns (bool) {
        return _account == ASTER || _account == PENDLE || _account == SIGMA;
    }

    /**
     * @dev v2: keep the token here and record it; mint lp tokens to delegateTo according to rate
     *
     * @param _account account who deposit token
     * @param _holder lp token holder
     * @param _amount token amount to deposit
     */
    function _provideCollateral(address _account, address _holder, uint256 _amount)
        internal
        override
        returns (uint256)
    {
        // v2: the token stays in this contract; only the served accounts can deposit
        require(_isServed(_account), "not a served account");
        _userDeposit[_account] += _amount;
        totalDeposit += _amount;
        uint256 lpAmount = _amount * exchangeRate / RATE_DENOMINATOR;
        uint256 holderLpAmount = lpAmount * userLpRate / RATE_DENOMINATOR;
        if (holderLpAmount > 0) {
            lpToken.mint(_holder, holderLpAmount);
            userLp[_account] += holderLpAmount;
        }

        uint256 reservedLpAmount = lpAmount - holderLpAmount;
        if (reservedLpAmount > 0) {
            lpToken.mint(lpReserveAddress, reservedLpAmount);
            userReservedLp[_account] += reservedLpAmount;
            totalReservedLp += reservedLpAmount;
        }

        return holderLpAmount;
    }

    /**
     * Burn lp token from both delegator and delegateTo
     *
     * @dev burns delegatee's lpToken first, then delegator's
     */
    function _burnLp(address _account, uint256 _amount)
        internal
        override
    {
        uint256 totalLpAmount = _amount * exchangeRate / RATE_DENOMINATOR;
        uint256 userPart = totalLpAmount * userLpRate / RATE_DENOMINATOR;
        uint256 reservePart = totalLpAmount - userPart;
        uint256 userTotalReserved = userReservedLp[_account];
        if (reservePart > 0) {
            lpToken.burn(lpReserveAddress, reservePart);
            userReservedLp[_account] -= reservePart;
            totalReservedLp -= reservePart;
        }

        if (userPart > 0) {
            if (delegation[_account].amount > 0) {
                uint256 delegatedAmount = delegation[_account].amount;
                uint256 delegateeBurn = userPart > delegatedAmount ? delegatedAmount : userPart;
                // burn delegatee's token, update delegated amount
                lpToken.burn(delegation[_account].delegateTo, delegateeBurn);
                delegation[_account].amount -= delegateeBurn;
                // burn delegator's token
                if (userPart > delegateeBurn) {
                    _safeBurnLp(_account, userPart - delegateeBurn);
                }
                userLp[_account] -= userPart;
            } else {
                // no delegation, only burn from account
                _safeBurnLp(_account, userPart);
                userLp[_account] -= userPart;
            }
        }
    }

    /**
     * @dev v2: pay out of this contract's records instead of dao.withdraw
     */
    function _withdrawLp(address _account, uint256 _amount) internal override {
        _syncLp(_account);
        require(_userDeposit[_account] >= _amount, "insufficient deposit");
        _userDeposit[_account] -= _amount;
        totalDeposit -= _amount;
        _burnLp(_account, _amount);
    }

    function syncUserLp(address _account) external {
        bool synced = _syncLp(_account);
        require(synced, "already synced");
    }

    /**
     * @dev withdraw leftover collateral from Interaction contract; to support historical liquidated slisBnb urns
     */
    function withdrawLeftover() external whenNotPaused nonReentrant {
        uint256 leftover = dao.free(token, msg.sender);
        require(leftover > 0, "no leftover");
        // v2: pay what actually arrived, not what the CDP reports, so the CDP cannot draw on the served deposits
        uint256 before = IERC20(token).balanceOf(address(this));
        dao.withdraw(msg.sender, token, leftover);
        uint256 amount = IERC20(token).balanceOf(address(this)) - before;

        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @dev v2: disabled; the CDP migrator could otherwise pull a served account's slisBNB
    function releaseFor(address, uint256) external pure returns (uint256) {
        revert("releaseFor disabled");
    }

    /// @dev v2: disabled; PROXY holders (Interaction, CDP Core Admin Safe) could otherwise move the slisBNB held here
    function liquidation(address, uint256) public pure override {
        revert("liquidation disabled");
    }

    function liquidation(address, address, uint256, bytes memory, bool) external pure override {
        revert("liquidation disabled");
    }

    function daoBurn(address, uint256) external pure override {
        revert("daoBurn disabled");
    }

    /**
     * check if user lp token is synced with token balance
     *
     * @param _account lp token owner
     */
    function isUserLpSynced(address _account) external view returns (bool) {
        uint256 totalTokenBalance = userDeposit(_account);
        uint256 userTotalLp = totalTokenBalance * exchangeRate / RATE_DENOMINATOR;
        uint256 expectUserPart = userTotalLp * userLpRate / RATE_DENOMINATOR;
        uint256 expectReservePart = userTotalLp - expectUserPart;

        return userLp[_account] == expectUserPart && userReservedLp[_account] == expectReservePart;
    }

    /**
     * @dev mint/burn lpToken to sync user's lpToken with token balance
     *
     * @param _account user address to sync
     */
    function _syncLp(address _account) internal override returns (bool) {
        uint256 expectAllLp = userDeposit(_account) * exchangeRate / RATE_DENOMINATOR;
        uint256 expectUserLp = expectAllLp * userLpRate / RATE_DENOMINATOR;
        uint256 expectReserveLp = expectAllLp - expectUserLp;
        uint256 reservePart = userReservedLp[_account];
        uint256 userPart = userLp[_account];
        if (userPart == expectUserLp && reservePart == expectReserveLp) {
            return false;
        }

        // reservePart
        if (reservePart > expectReserveLp) {
            lpToken.burn(lpReserveAddress, reservePart - expectReserveLp);
            userReservedLp[_account] = expectReserveLp;
            totalReservedLp -= (reservePart - expectReserveLp);
        } else if (reservePart < expectReserveLp) {
            lpToken.mint(lpReserveAddress, expectReserveLp - reservePart);
            userReservedLp[_account] = expectReserveLp;
            totalReservedLp += (expectReserveLp - reservePart);
        }
        // user self and delegation
        Delegation storage userDelegation = delegation[_account];
        uint256 currentDelegateLp = userDelegation.amount;
        uint256 currentUserSelf = userPart - currentDelegateLp;
        uint256 expectDelegateLp = userPart > 0 ? expectUserLp * currentDelegateLp / userPart : 0;
        uint256 expectUserSelfLp = expectUserLp - expectDelegateLp;
        if (currentDelegateLp > expectDelegateLp) {
            lpToken.burn(userDelegation.delegateTo, currentDelegateLp - expectDelegateLp);
            userDelegation.amount = expectDelegateLp;
        } else if (currentDelegateLp < expectDelegateLp) {
            lpToken.mint(userDelegation.delegateTo, expectDelegateLp - currentDelegateLp);
            userDelegation.amount = expectDelegateLp;
        }
        if (currentUserSelf > expectUserSelfLp) {
            lpToken.burn(_account, currentUserSelf - expectUserSelfLp);
        } else if (currentUserSelf < expectUserSelfLp) {
            lpToken.mint(_account, expectUserSelfLp - currentUserSelf);
        }

        userLp[_account] = expectUserLp;
        emit SyncUserLpWithReserve(_account, expectUserLp, expectReserveLp);
        return true;
    }

    function changeExchangeRate(uint128 _exchangeRate) external onlyRole(MANAGER) {
        require(_exchangeRate > 0, "exchangeRate invalid");

        exchangeRate = _exchangeRate;
        emit ChangeExchangeRate(exchangeRate);
    }

    function changeUserLpRate(uint128 _userLpRate) external onlyRole(MANAGER) {
        require(_userLpRate <= 1e18, "userLpRate invalid");

        userLpRate = _userLpRate;
        emit ChangeUserLpRate(userLpRate);
    }

    /**
     * change lpReserveAddress, all reserved lpToken will be burned from original address and be minted to new address
     * @param _lpTokenReserveAddress new lpTokenReserveAddress
     */
    function changeLpReserveAddress(address _lpTokenReserveAddress) external onlyRole(MANAGER) {
        require(_lpTokenReserveAddress != address(0) && _lpTokenReserveAddress != lpReserveAddress, "lpTokenReserveAddress invalid");
        if (totalReservedLp > 0) {
            lpToken.burn(lpReserveAddress, totalReservedLp);
            lpToken.mint(_lpTokenReserveAddress, totalReservedLp);
        }
        lpReserveAddress = _lpTokenReserveAddress;
        emit ChangeLpReserveAddress(lpReserveAddress);
    }
}
