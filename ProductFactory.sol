// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ProductSale.sol";

contract ProductFactory {
    event ProductDeployed(address indexed brand, address productAddress);

    function createProduct(
        string memory uri_,
        uint256 price_,
        uint256 maxSupply_
    ) external returns (address) {
        ProductSale p = new ProductSale(msg.sender, uri_, price_, maxSupply_);
        emit ProductDeployed(msg.sender, address(p));
        return address(p);
    }
}
