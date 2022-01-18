//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


contract Mints {
    
    mapping(address => uint256) public mints;

    function _setMints(address _mint, uint256 _amount) internal {
        mints[_mint] = _amount;
    }

    modifier checkMint(address _mint, uint256 _amount) {
        mints[_mint] -= _amount;
        _;
    }
}