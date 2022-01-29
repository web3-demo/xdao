//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./utils/SafeToken.sol";

library XDaoMath {
    function max(uint256 a, uint256 b) internal pure returns(uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns(uint256) {
        return a < b ? a : b;
    }
}

interface IERC20Capped {
    function cap() external view returns (uint256);
}

interface IXDao {
    function totalStaked() external view returns (uint256);
}
// 公募释放
// pool 总质押 每 超过 0.5% ，释放 5%
// 总 质押 超过 10% 释放完成 
// 不用mint
contract PublicRelease is OwnableUpgradeable {
    using SafeToken for address;
    using XDaoMath for uint256;

    // EPX
    uint256 public constant EPX = 10000;

    // 奖励 token
    address public xToken;
    // xdao
    address public xDao;

    // release detail
    // amount: 待释放余额
    // release: 可提取的数量
    // lastReleaseRate: 最后一次释放的比例
    struct Release {
        uint256 amount;
        uint256 lastReleaseRateEPX;
    }
    mapping (address => Release) public investor;

    event AddInvestor(address indexed owner, uint256 amount, uint256 releaseRateEPX);

    function initialize(address _xToken, address _xDao) public initializer {
        __Ownable_init();
        xToken = _xToken;
        xDao = _xDao;
    }

    ////////// 添加 地址 //////////
    // 添加 investor
    // 没有检查地址重复添加
    struct ReleaseInput {
        address owner;
        uint256 amount;
    }
    function addInvestor(ReleaseInput[] memory _invs) external onlyOwner {
        // 从 1 开始拨币
        uint256 nowReleaseRateEPX = releaseEPX();
        for(uint256 i = 0; i < _invs.length; i++) {
            Release storage _inv = investor[_invs[i].owner];
            // 只能添加一次
            if ( _inv.amount == 0 ) {
                _inv.amount = _invs[i].amount;
                _inv.lastReleaseRateEPX = nowReleaseRateEPX;
                emit AddInvestor(_invs[i].owner, _invs[i].amount, nowReleaseRateEPX);
            }
        }
    }

    ////////// 释放 率 //////////
    // 当前释放率
    // 这里是离散数
    function releaseEPX(uint256 staked, uint256 totalCap) public pure returns(uint256){
        return staked * 10000 * 500 / totalCap / 5;
    }

    function releaseEPX() public view returns(uint256) {
        return releaseEPX(IXDao(xDao).totalStaked(), IERC20Capped(xToken).cap());
    }

    function Harvest(address _owner) public returns(uint256 release) {
        release = _updateOwner(_owner);
        xToken.safeTransfer(_owner, release);
    }

    function _updateOwner(address _owner) internal returns(uint256 release) {
        Release storage _inv = investor[_owner];
        uint256 newReleaseRateEPX = releaseEPX();
        release = (newReleaseRateEPX - _inv.lastReleaseRateEPX).min(EPX) * _inv.amount / EPX;
        _inv.lastReleaseRateEPX = newReleaseRateEPX;
    }
}