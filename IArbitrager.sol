// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface IArbitrager {
    function arbitrage(address to, uint16 fee, address[] calldata pairsPath, uint16[] calldata fees, uint8[] calldata tokensIndexPath, uint8[] calldata pairTypes) external;
}
