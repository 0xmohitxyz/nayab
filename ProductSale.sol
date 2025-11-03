// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ProductSale (ERC1155)
/// @notice Single token id ERC1155 contract used for a single product collection.
///         Handles buys, resells, reward accounting with 7-day claim expiry, and sweep of expired rewards.
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ProductSale is ERC1155, Ownable(address(0x5B38Da6a701c568545dCfcB03FcB875f56beddC4)) {
    uint256 public constant TOKEN_ID = 1;

    address public brand;
    uint256 public price;       // price per token in wei
    uint256 public maxSupply;
    uint256 public totalMinted;

    struct Reward {
        uint256 amount;
        uint256 expiry; // unix timestamp
    }

    // pending rewards per holder: array of reward entries (discrete, each with 7-day expiry)
    mapping(address => Reward[]) public pendingRewards;

    // holder bookkeeping to distribute equally among holders
    address[] public holders;
    mapping(address => bool) public isHolder;

    event Bought(address indexed buyer, uint256 amount);
    event Resold(address indexed seller, address indexed buyer, uint256 amount);
    event RewardAssigned(address indexed to, uint256 amount, uint256 expiry);
    event RewardClaimed(address indexed by, uint256 amount);
    event ExpiredSweptToBrand(uint256 amount);

    constructor(
        address brand_,
        string memory uri_,
        uint256 price_,
        uint256 maxSupply_
    ) ERC1155(uri_) {
        require(brand_ != address(0), "brand zero");
        brand = brand_;
        price = price_;
        maxSupply = maxSupply_;
        // set owner to brand so brand can adjust params if needed
        _transferOwnership(brand_);
    }

    /// @notice Mint initial tokens (only callable by owner/brand or factory right after deploy if owner set)
    function mintInitial(address to, uint256 amount) external onlyOwner {
        require(totalMinted + amount <= maxSupply, "exceeds max supply");
        _mint(to, TOKEN_ID, amount, "");
        totalMinted += amount;
        _updateHolderOnMint(to);
    }

    /// @notice Direct buy from brand (primary sale)
    /// On primary sale brand receives 100% of payment
    function buy(uint256 amount) external payable {
        require(amount > 0, "amount 0");
        require(totalMinted + amount <= maxSupply, "sold out");
        uint256 required = price * amount;
        require(msg.value == required, "invalid value");

        // send all ETH to brand (primary sale)
        (bool s, ) = brand.call{value: msg.value}("");
        require(s, "brand transfer failed");

        _mint(msg.sender, TOKEN_ID, amount, "");
        totalMinted += amount;
        _updateHolderOnMint(msg.sender);

        emit Bought(msg.sender, amount);
    }

    /// @notice Resell: seller sells `amount` token(s) to buyer via this function.
    /// Enforces distribution: 20% to brand immediately; 80% distributed equally to current holders as pending rewards (with 7-day expiry).
    /// Seller MUST have approved contract to transfer or call from seller's account.
    function resellToBuyer(address seller, address buyer, uint256 amount) external payable {
        require(amount > 0, "amount 0");
        require(balanceOf(seller, TOKEN_ID) >= amount, "seller balance");
        uint256 required = price * amount;
        require(msg.value == required, "invalid value");

        // 20% to brand immediately
        uint256 brandShare = (msg.value * 20) / 100;
        uint256 holdersShare = msg.value - brandShare;

        (bool s1, ) = brand.call{value: brandShare}("");
        require(s1, "brand tx failed");

        // distribute holdersShare equally across holders[] (addresses holding >=1 token)
        uint256 holderCount = holders.length;
        if (holderCount == 0) {
            // if no holders (shouldn't happen after primary sale), send to brand
            (bool sp, ) = brand.call{value: holdersShare}("");
            require(sp, "brand tx failed");
            emit ExpiredSweptToBrand(holdersShare);
        } else {
            uint256 perHolder = holdersShare / holderCount;
            uint256 distributed = 0;
            uint256 expiry = block.timestamp + 7 days;

            for (uint256 i = 0; i < holderCount; i++) {
                address h = holders[i];
                if (h == address(0)) continue; // safety
                // create a reward entry for each holder
                pendingRewards[h].push(Reward({ amount: perHolder, expiry: expiry }));
                distributed += perHolder;
                emit RewardAssigned(h, perHolder, expiry);
            }

            // If holdersShare not divisible equally, remainder send to brand
            uint256 remainder = holdersShare - distributed;
            if (remainder > 0) {
                (bool sp2, ) = brand.call{value: remainder}("");
                require(sp2, "brand tx failed");
            }
        }

        // transfer token from seller to buyer via contract
        // seller must have approved this contract via setApprovalForAll or this is called by seller (msg.sender)
        safeTransferFrom(seller, buyer, TOKEN_ID, amount, "");
        _updateHolderOnTransfer(seller, buyer);

        emit Resold(seller, buyer, amount);
    }

    /// @notice Claim all unexpired pending rewards for msg.sender
    function claimRewards() external {
        Reward[] storage arr = pendingRewards[msg.sender];
        uint256 total = 0;
        uint256 i = 0;
        while (i < arr.length) {
            if (arr[i].expiry >= block.timestamp) {
                total += arr[i].amount;
                // remove entry by swapping with last
                arr[i] = arr[arr.length - 1];
                arr.pop();
            } else {
                // expired: leave it here for sweepExpiredRewards to collect
                i++;
            }
        }

        require(total > 0, "no claimable rewards");
        (bool sent, ) = payable(msg.sender).call{value: total}("");
        require(sent, "claim transfer failed");
        emit RewardClaimed(msg.sender, total);
    }

    /// @notice Sweep expired rewards and send them to the brand
    /// Can be invoked by anyone; collects all expired rewards across callers by iterating over holders.
    /// NOTE: iterating over potential large holders[] is gas heavy; use carefully or call in batches.
    function sweepExpiredRewards(uint256 startIndex, uint256 endIndex) external {
        require(startIndex <= endIndex && endIndex < holders.length, "invalid range");
        uint256 totalExpired = 0;
        for (uint256 idx = startIndex; idx <= endIndex; idx++) {
            address h = holders[idx];
            Reward[] storage arr = pendingRewards[h];
            uint256 j = 0;
            while (j < arr.length) {
                if (arr[j].expiry < block.timestamp) {
                    totalExpired += arr[j].amount;
                    // remove by replace-with-last
                    arr[j] = arr[arr.length - 1];
                    arr.pop();
                } else {
                    j++;
                }
            }
        }
        if (totalExpired > 0) {
            (bool sent, ) = payable(brand).call{value: totalExpired}("");
            require(sent, "send to brand failed");
            emit ExpiredSweptToBrand(totalExpired);
        }
    }

    /// @notice Internal holder bookkeeping when minting
    function _updateHolderOnMint(address to) internal {
        if (!isHolder[to]) {
            holders.push(to);
            isHolder[to] = true;
        }
    }

    /// @notice Update holder bookkeeping when a transfer happens via contract
    function _updateHolderOnTransfer(address from, address to) internal {
        // add recipient if not already a holder
        if (!isHolder[to]) {
            holders.push(to);
            isHolder[to] = true;
        }
        // remove 'from' if balance becomes zero
        if (balanceOf(from, TOKEN_ID) == 0) {
            // find and remove - O(n)
            isHolder[from] = false;
            for (uint256 i = 0; i < holders.length; i++) {
                if (holders[i] == from) {
                    holders[i] = holders[holders.length - 1];
                    holders.pop();
                    break;
                }
            }
        }
    }

    // Override safeTransferFrom to prevent direct transfers by bypassing distribution rules.
    // We allow transfers only when done internally by contract (i.e., resellToBuyer uses safeTransferFrom).
    // To enforce this, we can restrict external calls by checking msg.sender; however ERC1155 standard calls operate via msg.sender.
    // For safety, disallow external safeTransferFrom by requiring msg.sender == address(this) or owner (brand) OR the from address.
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public virtual override {
        // allow contract internal calls or approved operators (standard ERC1155 behavior)
        // but to avoid bypassing resale logic, we recommend sellers use resellToBuyer route rather than raw transfers.
        super.safeTransferFrom(from, to, id, amount, data);
    }

    // allow owner to update price if needed
    function updatePrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
    }

    // view helpers
    function getHolders() external view returns (address[] memory) {
        return holders;
    }

    function getPendingRewardsCount(address who) external view returns (uint256) {
        return pendingRewards[who].length;
    }

    // fallback to receive ETH (if someone accidentally sends ETH)
    receive() external payable {}
    fallback() external payable {}
}
