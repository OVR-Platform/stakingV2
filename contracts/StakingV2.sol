pragma solidity 0.5.16;
import "hardhat/console.sol";

// INTERFACE
import { IERC20Mintable } from "../interfaces/IERC20Mintable.sol";
import { IERC20 } from "../interfaces/IERC20.sol";

// LIB
import { SafeMath } from "../lib/SafeMath.sol";
import { Address } from "../lib/Address.sol";
import { SafeERC20 } from "../lib/SafeERC20.sol";
import { ABDKMath64x64 } from "../lib/ABDKMath64x64.sol";
import { ABDKMathQuad } from "../lib/ABDKMathQuad.sol";

// CONTRACTS
import { Initializable } from "./Initializable.sol";
import { ReentrancyGuard } from "./ReentrancyGuard.sol";
import { ERC20, ERC20Interface } from "./OVRToken.sol";
import { Context } from "./Context.sol";
import { Ownable } from "./Ownable.sol";

contract StakingV2 is Ownable, ReentrancyGuard {
    using Address for address;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // EVENTS

    /**
     * @dev Emitted when a user deposits tokens.
     * @param sender User address.
     * @param id User's unique deposit ID.
     * @param amount The amount of deposited tokens.
     * @param currentBalance Current user balance.
     * @param timestamp Operation date
     */
    event Deposited(
        address indexed sender,
        uint256 indexed id,
        uint256 amount,
        uint256 currentBalance,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a user withdraws tokens.
     * @param sender User address.
     * @param id User's unique deposit ID.
     * @param totalWithdrawalAmount The total amount of withdrawn tokens.
     * @param currentBalance Balance before withdrawal
     * @param timestamp Operation date
     */
    event WithdrawnAll(
        address indexed sender,
        uint256 indexed id,
        uint256 totalWithdrawalAmount,
        uint256 currentBalance,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a user extends lockup.
     * @param sender User address.
     * @param id User's unique deposit ID.
     * @param currentBalance Balance before lockup extension
     * @param finalBalance Final balance
     * @param timestamp The instant when the lockup is extended.
     */
    event ExtendedLockup(
        address indexed sender,
        uint256 indexed id,
        uint256 currentBalance,
        uint256 finalBalance,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a new Liquidity Provider address value is set.
     * @param value A new address value.
     * @param sender The owner address at the moment of address changing.
     */
    event LiquidityProviderAddressSet(address value, address sender);

    struct AddressParam {
        address oldValue;
        address newValue;
        uint256 timestamp;
    }

    // The deposit user balaces
    mapping(address => mapping(uint256 => uint256)) public balances;
    // The dates of users deposits/withdraws/extendLockups
    mapping(address => mapping(uint256 => uint256)) public depositDates;

    // Variable that prevents _deposit method from being called 2 times TODO CHECK
    bool private locked;

    // Variable to pause all operations
    bool private contractPaused = false;

    bool private pausedDepositsAndLockupExtensions = false;

    // STAKE token
    IERC20Mintable public token;
    // Reward Token
    IERC20Mintable public tokenReward;

    // The address for the Liquidity Providers
    AddressParam public liquidityProviderAddressParam;

    uint256 private constant DAY = 1 days;
    uint256 private constant MONTH = 30 days;
    uint256 private constant YEAR = 365 days;

    // The period after which the new value of the parameter is set
    uint256 public constant PARAM_UPDATE_DELAY = 7 days;

    // MODIFIERS

    /*
     *      1   |     2    |     3    |     4    |     5
     * 0 Months | 3 Months | 6 Months | 9 Months | 12 Months
     */
    modifier validDepositId(uint256 _depositId) {
        require(_depositId >= 1 && _depositId <= 5, "Invalid depositId");
        _;
    }

    // Impossible to withdrawAll if you have never deposited.
    modifier balanceExists(uint256 _depositId) {
        require(balances[msg.sender][_depositId] > 0, "Your deposit is zero");
        _;
    }

    modifier isNotLocked() {
        require(locked == false, "Locked, try again later");
        _;
    }

    modifier isNotPaused() {
        require(contractPaused == false, "Paused");
        _;
    }

    modifier isNotPausedOperations() {
        require(contractPaused == false, "Paused");
        _;
    }

    modifier isNotPausedDepositAndLockupExtensions() {
        require(pausedDepositsAndLockupExtensions == false, "Paused Deposits and Extensions");
        _;
    }

    /**
     * @dev Pause Deposits, Withdraw, Lockup Extension
     */
    function pauseContract(bool value) public onlyOwner {
        contractPaused = value;
    }

    /**
     * @dev Pause Deposits and Lockup Extension
     */
    function pauseDepositAndLockupExtensions(bool value) public onlyOwner {
        pausedDepositsAndLockupExtensions = value;
    }

    /**
     * @dev Initializes the contract. _tokenAddress _tokenReward will have the same address
     * @param _owner The owner of the contract.
     * @param _tokenAddress The address of the STAKE token contract.
     * @param _tokenReward The address of token rewards.
     * @param _liquidityProviderAddress The address for the Liquidity Providers reward.
     */
    function initializeStaking(
        address _owner,
        address _tokenAddress,
        address _tokenReward,
        address _liquidityProviderAddress
    ) external initializer {
        require(_owner != address(0), "Zero address");
        require(_tokenAddress.isContract(), "Not a contract address");
        Ownable.initialize(msg.sender);
        ReentrancyGuard.initialize();
        token = IERC20Mintable(_tokenAddress);
        tokenReward = IERC20Mintable(_tokenReward);
        setLiquidityProviderAddress(_liquidityProviderAddress);
        Ownable.transferOwnership(_owner);
    }

    /**
     * @dev Sets the address for the Liquidity Providers reward.
     * Can only be called by owner.
     * @param _address The new address.
     */
    function setLiquidityProviderAddress(address _address) public onlyOwner {
        require(_address != address(0), "Zero address");
        require(_address != address(this), "Wrong address");
        AddressParam memory param = liquidityProviderAddressParam;
        if (param.timestamp == 0) {
            param.oldValue = _address;
        } else if (_paramUpdateDelayElapsed(param.timestamp)) {
            param.oldValue = param.newValue;
        }
        param.newValue = _address;
        param.timestamp = _now();
        liquidityProviderAddressParam = param;
        emit LiquidityProviderAddressSet(_address, msg.sender);
    }

    /**
     * @return Returns true if param update delay elapsed.
     */
    function _paramUpdateDelayElapsed(uint256 _paramTimestamp) internal view returns (bool) {
        return _now() > _paramTimestamp.add(PARAM_UPDATE_DELAY);
    }

    /**
     * @dev This method is used to deposit tokens to the deposit opened before.
     * It calls the internal "_deposit" method and transfers tokens from sender to contract.
     * Sender must approve tokens first.
     *
     * Instead this, user can use the simple "transferFrom" method of OVR token contract to make a deposit.
     *
     * @param _depositId User's unique deposit ID.
     * @param _amount The amount to deposit.
     */
    function deposit(uint256 _depositId, uint256 _amount)
        public
        validDepositId(_depositId)
        isNotLocked
        isNotPaused
        isNotPausedDepositAndLockupExtensions
    {
        require(_amount > 0, "Amount should be more than 0");

        _deposit(msg.sender, _depositId, _amount);
        console.log("\t\tUSER BALANCE AFTER DEPOSIT:", getCurrentBalance(_depositId, msg.sender));

        _setLocked(true);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        _setLocked(false);
    }

    /**
     * @param _sender The address of the sender.
     * @param _depositId User's deposit ID.
     * @param _amount The amount to deposit.
     */
    function _deposit(
        address _sender,
        uint256 _depositId,
        uint256 _amount
    ) internal nonReentrant {
        uint256 currentBalance = getCurrentBalance(_depositId, _sender);
        uint256 finalBalance = calcRewards(_sender, _depositId);
        uint256 timestamp = _now();

        balances[_sender][_depositId] = _amount.add(finalBalance);
        depositDates[_sender][_depositId] = _now();
        emit Deposited(_sender, _depositId, _amount, currentBalance, timestamp);
    }

    /**
     * @dev This method is used to withdraw rewards and balance.
     * It calls the internal "_withdrawAll" method.
     * @param _depositId User's unique deposit ID
     */
    function withdrawAll(uint256 _depositId) external balanceExists(_depositId) validDepositId(_depositId) isNotPaused {
        require(isLockupPeriodExpired(_depositId), "Too early, Lockup period");
        _withdrawAll(msg.sender, _depositId);
    }

    function _withdrawAll(address _sender, uint256 _depositId)
        internal
        balanceExists(_depositId)
        validDepositId(_depositId)
        nonReentrant
    {
        uint256 currentBalance = getCurrentBalance(_depositId, _sender);
        uint256 finalBalance = calcRewards(_sender, _depositId);

        require(finalBalance > 0, "Nothing to withdraw");
        balances[_sender][_depositId] = 0;

        _setLocked(true);
        require(tokenReward.transfer(_sender, finalBalance), "Liquidity pool transfer failed");
        _setLocked(false);

        emit WithdrawnAll(_sender, _depositId, finalBalance, currentBalance, _now());
    }

    /**
     * This method is used to extend lockup. It is available if your lockup period is expired and if depositId != 1
     * It calls the internal "_extendLockup" method.
     * @param _depositId User's unique deposit ID
     */
    function extendLockup(uint256 _depositId)
        external
        balanceExists(_depositId)
        validDepositId(_depositId)
        isNotPaused
        isNotPausedDepositAndLockupExtensions
    {
        require(_depositId != 1, "No lockup is set up");
        _extendLockup(msg.sender, _depositId);
    }

    function _extendLockup(address _sender, uint256 _depositId) internal nonReentrant {
        uint256 timestamp = _now();
        uint256 currentBalance = getCurrentBalance(_depositId, _sender);
        uint256 finalBalance = calcRewards(_sender, _depositId);

        balances[_sender][_depositId] = finalBalance;
        depositDates[_sender][_depositId] = timestamp;
        emit ExtendedLockup(_sender, _depositId, currentBalance, finalBalance, timestamp);
    }

    function isLockupPeriodExpired(uint256 _depositId) public view validDepositId(_depositId) returns (bool) {
        uint256 lockPeriod;

        if (_depositId == 1) {
            lockPeriod = 0;
        } else if (_depositId == 2) {
            lockPeriod = MONTH * 3; // 3 months
        } else if (_depositId == 3) {
            lockPeriod = MONTH * 6; // 6 months
        } else if (_depositId == 4) {
            lockPeriod = MONTH * 9; // 9 months
        } else if (_depositId == 5) {
            lockPeriod = MONTH * 12; // 12 months
        }

        if (_now() > depositDates[msg.sender][_depositId].add(lockPeriod)) {
            return true;
        } else {
            return false;
        }
    }

    function pow(int128 _x, uint256 _n) public pure returns (int128 r) {
        r = ABDKMath64x64.fromUInt(1);
        while (_n > 0) {
            if (_n % 2 == 1) {
                r = ABDKMath64x64.mul(r, _x);
                _n -= 1;
            } else {
                _x = ABDKMath64x64.mul(_x, _x);
                _n /= 2;
            }
        }
    }

    /**
     * This method is calcuate final compouded capital.
     * @param _principal User's balance
     * @param _ratio Interest rate
     * @param _n Periods is timestamp
     * @return finalBalance The final compounded capital
     *
     * A = C ( 1 + rate )^t
     */
    function compound(
        uint256 _principal,
        uint256 _ratio,
        uint256 _n
    ) public view returns (uint256) {
        uint256 daysCount = _n.div(DAY);

        console.log("\t\tDAYSCOUNT", daysCount);
        return
            ABDKMath64x64.mulu(
                pow(ABDKMath64x64.add(ABDKMath64x64.fromUInt(1), ABDKMath64x64.divu(_ratio, 10**18)), daysCount),
                _principal
            );
    }

    /**
     * This moethod is used to calculate final compounded balance and is based on deposit duration and deposit id.
     * Each deposit mode is characterized by the lockup period and interest rate.
     * At the expiration of the lockup period the final compounded capital
     * will use minimum interest rate.
     *
     * This function can be called at any time to get the current total reward.
     * @param _sender Sender Address.
     * @param _depositId The depositId
     * @return finalBalance The final compounded capital
     */
    function calcRewards(address _sender, uint256 _depositId) public view validDepositId(_depositId) returns (uint256) {
        uint256 timePassed = _now().sub(depositDates[_sender][_depositId]);
        uint256 currentBalance = getCurrentBalance(_depositId, _sender);
        uint256 finalBalance;

        uint256 ratio;
        uint256 lockPeriod;

        if (_depositId == 1) {
            ratio = 100000000000000; // APY 3.7% InterestRate = 0.01
            lockPeriod = 0;
        } else if (_depositId == 2) {
            ratio = 300000000000000; // APY 11.6% InterestRate = 0.03
            lockPeriod = MONTH * 3; // 3 months
        } else if (_depositId == 3) {
            ratio = 400000000000000; // APY 15.7% InterestRate = 0.04
            lockPeriod = MONTH * 6; // 6 months
        } else if (_depositId == 4) {
            ratio = 600000000000000; // APY 25.5% InterestRate = 0.06
            lockPeriod = MONTH * 9; // 9 months
        } else if (_depositId == 5) {
            ratio = 800000000000000; // APY 33.9% InterestRate = 0.08
            lockPeriod = YEAR; // 12 months
        }

        // You can't have earnings without balance
        if (currentBalance == 0) {
            console.log("\t\tCOMPOUND:", 0);
            return finalBalance = 0;
        }

        // No lockup
        if (_depositId == 1) {
            finalBalance = compound(currentBalance, ratio, timePassed);
            console.log("\t\tCOMPOUND:", finalBalance);
            return finalBalance;
        }

        // If you have an uncovered period from lockup, you still get rewards at the minimum rate
        if (timePassed > lockPeriod) {
            uint256 rewardsWithLockup = compound(currentBalance, ratio, lockPeriod).sub(currentBalance);
            finalBalance = compound(rewardsWithLockup.add(currentBalance), 100000000000000, timePassed.sub(lockPeriod));

            console.log("\t\tCOMPOUND:", finalBalance);

            return finalBalance;
        }

        finalBalance = compound(currentBalance, ratio, timePassed);
        console.log("\t\tCOMPOUND:", finalBalance);
        return finalBalance;
    }

    function getCurrentBalance(uint256 _depositId, address _address) public view returns (uint256 addressBalance) {
        addressBalance = balances[_address][_depositId];
    }

    /**
     * @return Returns current liquidity providers reward address.
     */
    function liquidityProviderAddress() public view returns (address) {
        AddressParam memory param = liquidityProviderAddressParam;
        return param.newValue;
    }

    /**
     * @dev Sets lock to prevent reentrance.
     */
    function _setLocked(bool _locked) internal {
        locked = _locked;
    }

    function senderCurrentBalance() public view returns (uint256) {
        return msg.sender.balance;
    }

    /**
     * @return Returns current timestamp.
     */
    function _now() internal view returns (uint256) {
        // Note that the timestamp can have a 900-second error:
        // https://github.com/ethereum/wiki/blob/c02254611f218f43cbb07517ca8e5d00fd6d6d75/Block-Protocol-2.0.md
        // return now; // solium-disable-line security/no-block-members
        return block.timestamp;
    }
}
