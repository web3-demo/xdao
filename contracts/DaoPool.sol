//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./utils/SafeToken.sol";

import "hardhat/console.sol";

contract Dividend {

    using SafeToken for address;

    // 空投地址
    address public dialer;

    // 空投代币
    address public dividendToken;

    modifier onlyDialer() {
        require(msg.sender == dialer, "caller only dialer");
        _;
    }

    constructor(address _dialer, address _dividendToken) {
        dialer = _dialer;
        dividendToken = _dividendToken;
    }

    // 权限丢失风险
    function setDialer(address _new_dialer) public onlyDialer {
        dialer = _new_dialer;
    }

    struct Drops {
        address to;
        uint256 amount;
    }
    function batchDrop(Drops[] calldata _drops) external onlyDialer {
        for(uint256 i = 0; i < _drops.length; i++) {
            dividendToken.safeTransfer(_drops[i].to, _drops[i].amount);
        }
    }
}

interface IERC20_Miner {
    function mint(address to, uint amount) external;
    /// @dev Burn ERC1155 token to redeem ERC20 token back.
    function burn(uint amount) external;
    function cap() external view returns (uint256);
}

library XDaoMath {
    function max(uint256 a, uint256 b) internal pure returns(uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns(uint256) {
        return a < b ? a : b;
    }
}

contract XDaoPool is OwnableUpgradeable, ReentrancyGuardUpgradeable {

    using SafeToken for address;
    using XDaoMath for uint256;

    uint256 public constant EPX = 1 << 64;
    uint256 public constant multiplier = 2;
    uint256 public constant maxCycle = 60 days;

    Dividend public monthlyDividend;
    Dividend public quarterlyDividend;

    // 月度 分红比列
    uint256 public monthlyDividendRateEPX;
    // 季度 分红比列
    uint256 public quarterlyDividendRateEPX;
    
    // token
    address public stakeToken;

    // feer mint bnb 接收地址
    address public feeCollector;

    // 累积存入
    uint256 public totalStaked;
    // unlock num
    uint256 public unlockStaked;

    // activate 激活结算时间
    uint256 public activateTime;

    // alice referrer bob
    // bob => a
    mapping(address => uint256) public recommended;
    
    // stake
    mapping(address => uint256) public staked;

    // unlock
    struct UnlockValue {
        uint256 amount;
        uint256 startTime;
        uint256 lastUnlockTime;
    }
    mapping(address => UnlockValue[]) public unlock;

    // 过滤
    // 被推荐过的地址就不能在参与了
    // 只能 自己买一次
    // 买的时候 填推荐人 可以 是 0x00 或其他人
    // 推荐人必须是获取过空投的地址
    // 只能 推荐 50 个人
    modifier checkReferrer(address _referrer) {
        // 买过的不能再买
        // 只能买一次不会造成重复使用推荐人的情况
        require(recommended[msg.sender] == 0, "minted");
        recommended[msg.sender] += 1;

        if ( _referrer != address(0) ) {
            // 最多推荐 50 人
            recommended[_referrer] += 1;
            // 且 _referrer 必须是系统内用户
            // _referrer 自己 使用过
            require(recommended[_referrer] > 1, "Referrer is not a system address");
            // 判断写在修改后，直接判断结果
            // 在修改前判断需要考虑变量的影响
            require(recommended[_referrer] <= 51, "Maximum of 50 referrals");
        }
        _;
    }

    event Mint(address indexed buyer, address indexed referrer, uint256 time);
    event Activate(address indexed user, uint256 amount);
    
    function initialize(address _stakeToken) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        stakeToken = _stakeToken;
        monthlyDividend = new Dividend(msg.sender,_stakeToken);
        quarterlyDividend = new Dividend(msg.sender,_stakeToken);
        monthlyDividendRateEPX = EPX * 2 / 10;
        quarterlyDividendRateEPX = EPX * 2 / 10;
        feeCollector = msg.sender;
        activateTime = 0;
        // 0.05%
        unlockStaked = IERC20_Miner(_stakeToken).cap() * 5 / 10000;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = _feeCollector;
    }

    function setActivate() external  {
        _activateTime();
    }

    // function setUnLock(uint256 rate) external onlyOwner {
    //     unlockStaked = IERC20_Miner(_stakeToken).cap() * rate / 1000;
    // }

    function unlockOf(address _owner) view external returns(UnlockValue[] memory) {
        return unlock[_owner];
    }

    function unlockSizeOf(address _owner) view public returns(uint256) {
        return unlock[_owner].length;
    }

    ///////// mint /////////
    // 空投
    function mint(address _referrer) external payable nonReentrant {
        _mintPos(_referrer);
    }

    function mint() external payable nonReentrant {
        _mintPos(address(0));
    }

    function _mintPos(address _referrer) internal checkReferrer(_referrer) {
        require(msg.value == 5e16,"Required 0.05 BNB");
        
        // 1 亿个
        // 10,000,000 000000000000000
        uint256 amount = 1e22;
        // 质押增加 1亿
        staked[msg.sender] += amount;
        // 给推荐人 1e23
        if (_referrer != address(0)) {
            staked[_referrer] += amount;
            amount *= 2;
        }

        // 增加 累积质押
        _addTotalStaked(amount);

        // 增发 xdao
        _mint(amount);
        // 转移 bnb
        SafeToken.safeTransferETH(feeCollector, msg.value);

        emit Mint(msg.sender, _referrer, block.timestamp);
    }

    function _mint(uint256 _amount) internal {
        IERC20_Miner(stakeToken).mint(address(this), _amount);
    }

    function _burn(uint256 _amount) internal {
        IERC20_Miner(stakeToken).burn(_amount);
    }

    // 增加 totalStake
    function _addTotalStaked(uint256 _amount) internal {
        totalStaked += _amount;
    }

    ///////// activate 解锁 /////////
    function getUnlockAmount(uint256 lockAmount, uint256 unlockCycle) public pure returns(uint256) {
        // 输入已做限制
        // unlockCycle = unlockCycle.min(maxCycle, unlockCycle);
        return lockAmount * unlockCycle / maxCycle;
    }

    // 解锁
    function activate(uint256 _amount) external {
        require(_amount > 0,"activate amount need > 0");

        // 更新激活
        _activateUnlock();

        // 存入 token
        stakeToken.safeTransferFrom(msg.sender, address(this), _amount);
        // 判断 余额是否够
        uint256 _unlock = multiplier * _amount;
        // 这里限制了用户 无法 超额解锁
        staked[msg.sender] -= _unlock;
        _sendDividend(msg.sender, _unlock);
        _sendMonthly(_amount);
        emit Activate(msg.sender, _amount);
    }

    // 激活
    // 状态定义
    // startTime > 0 为激活
    function _activateUnlock() internal {
        // 激活条件
        // 已激活 停止下一步
        if (_checkActivate()) return;
        // 激活后 activateTime > 0 不会二次运行
        if ( _isActivate() )  {
            _activateTime();
        }
    }

    function _activateTime() internal {
        activateTime = block.timestamp;
    }

    // 检查激活
    function _checkActivate() internal view returns(bool) {
        return activateTime > 0;
    }

    // 激活条件
    function _isActivate() internal view returns(bool) {
        return totalStaked > unlockStaked;
    }

    // 月度分红
    function _sendMonthly(uint256 _amount) internal {
        uint monthly = _amount * monthlyDividendRateEPX / EPX + 1;
        stakeToken.safeTransfer(address(monthlyDividend), monthly);
        _burn(_amount - monthly);
    }

    // 季度分红 quarterlyDividend
    function _sendDividend(address _owner, uint256 _amount) internal {
        // 这里会被舍去 1
        uint quarterly = _amount * quarterlyDividendRateEPX / EPX + 1;
        stakeToken.safeTransfer(address(quarterlyDividend), quarterly);
        _addUnlockFor(_owner, _amount - quarterly);
    }

    // 添加仓位
    // 过期仓位覆盖
    // 先创建
    function _addUnlockFor(address _owner, uint256 _amount) internal {
        UnlockValue[] storage _unlockList  = unlock[_owner];
        uint256 _now = block.timestamp;
        _unlockList.push(
            UnlockValue(
                _amount,
                _now,
                _now
            )
        );
    }

    ///////// Harvest /////////
    // 这里 对 i 做限制
    // 防止 int 未出现的仓位
    // 逐个取走 防止数组过长 超过 gas limit
    function harvestFor(address _owner, uint256 _i) external returns(uint256 _unlockAmount) {
        require(unlockSizeOf(_owner) > _i, "id too long");
        _unlockAmount = _getTotalUnlockFor(_owner, _i);
        stakeToken.safeTransfer(_owner, _unlockAmount);
    }

    function batchHarvest(address _owner, uint256[] calldata _ids) external returns(uint256 _unlockAmount) {
        uint256 size = unlockSizeOf(_owner);
        for(uint256 i = 0; i < _ids.length; i++) {
            // id 超过 已有数组 不计算
            if ( size > _ids[i] ) {
                _unlockAmount += _getTotalUnlockFor(_owner, i);
            }
        }
        stakeToken.safeTransfer(_owner, _unlockAmount);
    }

    function _updateLastTime(address _owner, uint256 _i) internal {
        // 最大 60 天
        unlock[_owner][_i].lastUnlockTime = block.timestamp.min(unlock[_owner][_i].startTime + maxCycle);
    }

    function _getTotalUnlockFor(address _owner, uint256 _i) internal returns(uint256 unlockAmount) {
        // 检查是否已激活
        if ( !_checkActivate() ) {
            // 未激活不分配
            unlockAmount = 0;
        } else {
            UnlockValue storage _unlock = unlock[_owner][_i];
            // 初始化
            _initUnlockFor(_unlock);
            // 计算
            uint256 _lastTime = _unlock.lastUnlockTime;
            uint256 _startTime = _unlock.startTime;
            // 限制 最大截止时间 不超过 60 days
            uint256 _maxLast = block.timestamp.min(_startTime + maxCycle);
            unlockAmount = getUnlockAmount( _unlock.amount, _maxLast - _lastTime);
            _unlock.lastUnlockTime = _maxLast;
        }
    }

    // 初始化仓位
    // 定义：startTime < activateTime 解锁未激活
    // 激活 重置 startTime 和 lastTime 为开始释放时间
    function _initUnlockFor(UnlockValue storage _unlock) internal {
        if ( _unlock.startTime < activateTime ) {
            _unlock.startTime = activateTime;
            _unlock.lastUnlockTime = activateTime;
        }
    }
}