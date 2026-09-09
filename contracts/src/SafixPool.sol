// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPassportRegistry} from "./interfaces/IPassportRegistry.sol";

contract SafixPool {
    struct AssetConfig {
        bool enabled;
        uint16 maxLtvBps;
        uint16 liqThresholdBps;
        uint256 priceUsd1e18;
    }

    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 totalDrawn;
    }

    struct DepositRecord {
        uint256 rawStake;
        uint256 snapshotP;
        uint256 snapshotScale;
        mapping(address => uint256) snapshotS;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant P_PRECISION = 1e27;
    uint256 private constant SCALE_FACTOR = 1e9;
    uint256 private constant P_MIN = P_PRECISION / SCALE_FACTOR;

    IERC20 public immutable stable;
    address public owner;
    address public priceUpdater;
    address public passportRegistry;

    uint16 public originationFeeBps = 50;
    uint16 public redemptionFeeBps = 30;
    uint16 public liquidationIncentiveBps = 50;
    uint256 public maxPriceAge;
    uint256 public protocolFees;
    mapping(address => uint256) public priceUpdatedAt;
    mapping(address => address) public priceFeeds;
    mapping(address => uint8) public priceFeedDecimals;

    address[] public assetList;
    mapping(address => AssetConfig) public assetConfig;
    mapping(address => mapping(address => Position)) public positions;

    uint256 public totalDeposits;
    uint256 public productP = P_PRECISION;
    uint256 public currentScale;
    mapping(uint256 => mapping(address => uint256)) public sumS;
    mapping(address => DepositRecord) private depositRecords;
    mapping(address => mapping(address => uint256)) public pendingGains;

    bool private entered;

    event AssetConfigured(address indexed asset, uint16 maxLtvBps, uint16 liqThresholdBps);
    event PriceSet(address indexed asset, uint256 priceUsd1e18);
    event Deposited(address indexed provider, uint256 amount);
    event Withdrawn(address indexed provider, uint256 amount);
    event GainsClaimed(address indexed provider, address indexed asset, uint256 amount);
    event CollateralLocked(address indexed borrower, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, address indexed asset, uint256 amount);
    event Drawn(address indexed borrower, address indexed asset, uint256 amount, uint256 fee);
    event Repaid(address indexed borrower, address indexed asset, uint256 amount);
    event PositionClosed(address indexed borrower, address indexed asset, uint256 redemptionFee);
    event Liquidated(
        address indexed borrower,
        address indexed asset,
        address indexed caller,
        uint256 debtOffset,
        uint256 collateralSeized
    );
    event FeesCollected(address indexed to, uint256 amount);
    event OwnerChanged(address indexed newOwner);
    event PriceUpdaterSet(address indexed updater);
    event PriceFeedSet(address indexed asset, address indexed feed);
    event PassportRegistrySet(address indexed registry);
    event LiquidationIncentiveSet(uint16 bps);
    event MaxPriceAgeSet(uint256 seconds_);
    event FeesSet(uint16 originationBps, uint16 redemptionBps);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier nonReentrant() {
        require(!entered, "reentrancy");
        entered = true;
        _;
        entered = false;
    }

    constructor(address stable_) {
        stable = IERC20(stable_);
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    function setFees(uint16 originationBps, uint16 redemptionBps) external onlyOwner {
        require(originationBps <= 500 && redemptionBps <= 500, "fee too high");
        originationFeeBps = originationBps;
        redemptionFeeBps = redemptionBps;
        emit FeesSet(originationBps, redemptionBps);
    }

    function setPriceUpdater(address updater) external onlyOwner {
        priceUpdater = updater;
        emit PriceUpdaterSet(updater);
    }

    function setPassportRegistry(address registry) external onlyOwner {
        passportRegistry = registry;
        emit PassportRegistrySet(registry);
    }

    function setLiquidationIncentive(uint16 bps) external onlyOwner {
        require(bps <= 200, "too high");
        liquidationIncentiveBps = bps;
        emit LiquidationIncentiveSet(bps);
    }

    function setMaxPriceAge(uint256 seconds_) external onlyOwner {
        maxPriceAge = seconds_;
        emit MaxPriceAgeSet(seconds_);
    }

    function configureAsset(
        address asset,
        uint16 maxLtvBps,
        uint16 liqThresholdBps,
        uint256 priceUsd1e18
    ) external onlyOwner {
        require(maxLtvBps < liqThresholdBps && liqThresholdBps <= BPS, "bad config");
        if (!assetConfig[asset].enabled) assetList.push(asset);
        assetConfig[asset] =
            AssetConfig({enabled: true, maxLtvBps: maxLtvBps, liqThresholdBps: liqThresholdBps, priceUsd1e18: priceUsd1e18});
        priceUpdatedAt[asset] = block.timestamp;
        emit AssetConfigured(asset, maxLtvBps, liqThresholdBps);
    }

    function setPrice(address asset, uint256 priceUsd1e18) external {
        require(msg.sender == owner || msg.sender == priceUpdater, "not price updater");
        require(assetConfig[asset].enabled, "asset off");
        assetConfig[asset].priceUsd1e18 = priceUsd1e18;
        priceUpdatedAt[asset] = block.timestamp;
        emit PriceSet(asset, priceUsd1e18);
    }

    function setPriceFeed(address asset, address feed) external onlyOwner {
        require(assetConfig[asset].enabled, "asset off");
        if (feed != address(0)) {
            uint8 feedDecimals = IAggregatorV3(feed).decimals();
            require(feedDecimals <= 18, "bad feed decimals");
            priceFeedDecimals[asset] = feedDecimals;
        } else {
            delete priceFeedDecimals[asset];
        }
        priceFeeds[asset] = feed;
        emit PriceFeedSet(asset, feed);
    }

    function currentPrice(address asset) public view returns (uint256 price1e18, uint256 updatedAt) {
        address feed = priceFeeds[asset];
        if (feed == address(0)) {
            return (assetConfig[asset].priceUsd1e18, priceUpdatedAt[asset]);
        }
        (, int256 answer,, uint256 feedUpdatedAt,) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, "bad feed answer");
        require(feedUpdatedAt > 0, "bad feed round");
        price1e18 = uint256(answer) * 10 ** (18 - priceFeedDecimals[asset]);
        updatedAt = feedUpdatedAt;
    }

    function _requireFreshPrice(address asset) internal view {
        if (maxPriceAge == 0) return;
        (, uint256 updatedAt) = currentPrice(asset);
        require(block.timestamp - updatedAt <= maxPriceAge, "stale price");
    }

    function collectProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amount = protocolFees;
        protocolFees = 0;
        require(stable.transfer(to, amount), "transfer failed");
        emit FeesCollected(to, amount);
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    function collateralValueStable(address asset, uint256 amount) public view returns (uint256) {
        (uint256 price1e18,) = currentPrice(asset);
        return (amount * price1e18) / 1e30;
    }

    function compoundedDepositOf(address provider) public view returns (uint256) {
        DepositRecord storage record = depositRecords[provider];
        if (record.rawStake == 0) return 0;
        uint256 scaleDiff = currentScale - record.snapshotScale;
        if (scaleDiff == 0) return (record.rawStake * productP) / record.snapshotP;
        if (scaleDiff == 1) return (record.rawStake * productP) / record.snapshotP / SCALE_FACTOR;
        return 0;
    }

    function _gainSince(DepositRecord storage record, address asset) internal view returns (uint256) {
        if (record.rawStake == 0) return 0;
        uint256 firstPortion = sumS[record.snapshotScale][asset] - record.snapshotS[asset];
        uint256 secondPortion =
            currentScale > record.snapshotScale ? sumS[record.snapshotScale + 1][asset] / SCALE_FACTOR : 0;
        return (record.rawStake * (firstPortion + secondPortion)) / record.snapshotP;
    }

    function gainOf(address provider, address asset) public view returns (uint256) {
        DepositRecord storage record = depositRecords[provider];
        return pendingGains[provider][asset] + _gainSince(record, asset);
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 balance = stable.balanceOf(address(this));
        return balance > protocolFees ? balance - protocolFees : 0;
    }

    function _realize(address provider) internal {
        DepositRecord storage record = depositRecords[provider];
        uint256 compounded = compoundedDepositOf(provider);
        uint256 count = assetList.length;
        for (uint256 i = 0; i < count; i++) {
            address asset = assetList[i];
            uint256 gain = _gainSince(record, asset);
            if (gain > 0) pendingGains[provider][asset] += gain;
            record.snapshotS[asset] = sumS[currentScale][asset];
        }
        record.rawStake = compounded;
        record.snapshotP = productP;
        record.snapshotScale = currentScale;
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "zero");
        _realize(msg.sender);
        DepositRecord storage record = depositRecords[msg.sender];
        record.rawStake += amount;
        totalDeposits += amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _realize(msg.sender);
        DepositRecord storage record = depositRecords[msg.sender];
        require(amount > 0 && amount <= record.rawStake, "bad amount");
        require(amount <= availableLiquidity(), "illiquid");
        record.rawStake -= amount;
        totalDeposits -= amount;
        require(stable.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function claimGains(address[] calldata assets) external nonReentrant {
        _realize(msg.sender);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amount = pendingGains[msg.sender][assets[i]];
            if (amount == 0) continue;
            pendingGains[msg.sender][assets[i]] = 0;
            require(IERC20(assets[i]).transfer(msg.sender, amount), "transfer failed");
            emit GainsClaimed(msg.sender, assets[i], amount);
        }
    }

    function lockCollateral(address asset, uint256 amount) external nonReentrant {
        require(assetConfig[asset].enabled, "asset off");
        require(amount > 0, "zero");
        positions[msg.sender][asset].collateral += amount;
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit CollateralLocked(msg.sender, asset, amount);
    }

    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(amount > 0 && amount <= position.collateral, "bad amount");
        uint256 remaining = position.collateral - amount;
        if (position.debt > 0 || position.totalDrawn > 0) {
            require(remaining > 0, "close position instead");
        }
        if (position.debt > 0) {
            _requireFreshPrice(asset);
            uint256 remainingValue = collateralValueStable(asset, remaining);
            require(
                (remainingValue * assetConfig[asset].maxLtvBps) / BPS >= position.debt,
                "would break ltv"
            );
        }
        position.collateral = remaining;
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");
        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    function draw(address asset, uint256 amount) external nonReentrant {
        AssetConfig storage config = assetConfig[asset];
        require(config.enabled, "asset off");
        require(amount > 0, "zero");
        _requireFreshPrice(asset);
        if (passportRegistry != address(0)) {
            require(IPassportRegistry(passportRegistry).isEligible(msg.sender), "passport required");
        }
        Position storage position = positions[msg.sender][asset];
        uint256 fee = (amount * originationFeeBps) / BPS;
        uint256 newDebt = position.debt + amount + fee;
        uint256 value = collateralValueStable(asset, position.collateral);
        require((value * config.maxLtvBps) / BPS >= newDebt, "exceeds ltv");
        require(amount <= availableLiquidity(), "illiquid");
        position.debt = newDebt;
        position.totalDrawn += amount;
        protocolFees += fee;
        require(stable.transfer(msg.sender, amount), "transfer failed");
        emit Drawn(msg.sender, asset, amount, fee);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(amount > 0 && amount <= position.debt, "bad amount");
        position.debt -= amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Repaid(msg.sender, asset, amount);
    }

    function closePosition(address asset) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(position.collateral > 0 || position.debt > 0, "no position");
        uint256 redemptionFee = (position.totalDrawn * redemptionFeeBps) / BPS;
        uint256 owed = position.debt + redemptionFee;
        uint256 collateral = position.collateral;
        position.collateral = 0;
        position.debt = 0;
        position.totalDrawn = 0;
        protocolFees += redemptionFee;
        if (owed > 0) {
            require(stable.transferFrom(msg.sender, address(this), owed), "transfer failed");
        }
        if (collateral > 0) {
            require(IERC20(asset).transfer(msg.sender, collateral), "transfer failed");
        }
        emit PositionClosed(msg.sender, asset, redemptionFee);
    }

    function isLiquidatable(address borrower, address asset) public view returns (bool) {
        Position storage position = positions[borrower][asset];
        if (position.debt == 0) return false;
        uint256 value = collateralValueStable(asset, position.collateral);
        return (value * assetConfig[asset].liqThresholdBps) / BPS < position.debt;
    }

    function liquidate(address borrower, address asset, uint256 debtAmount) external nonReentrant {
        _requireFreshPrice(asset);
        require(isLiquidatable(borrower, asset), "healthy");
        Position storage position = positions[borrower][asset];
        uint256 offset = debtAmount >= position.debt ? position.debt : debtAmount;
        require(offset > 0, "zero");
        require(totalDeposits > offset, "pool too small");
        uint256 seized = (position.collateral * offset) / position.debt;
        // The redemption fee at close is charged on totalDrawn, so the share of the position the
        // liquidation takes has to leave with it. Without this, draws that were already settled by
        // a liquidation would be charged again the next time the borrower closes.
        uint256 drawnOffset = (position.totalDrawn * offset) / position.debt;
        uint256 incentive = (seized * liquidationIncentiveBps) / BPS;
        uint256 poolShare = seized - incentive;
        position.debt -= offset;
        position.collateral -= seized;
        position.totalDrawn -= drawnOffset;
        sumS[currentScale][asset] += (poolShare * productP) / totalDeposits;
        uint256 newP = (productP * (totalDeposits - offset)) / totalDeposits;
        while (newP < P_MIN) {
            currentScale += 1;
            newP *= SCALE_FACTOR;
        }
        productP = newP;
        totalDeposits -= offset;
        if (incentive > 0) {
            require(IERC20(asset).transfer(msg.sender, incentive), "transfer failed");
        }
        emit Liquidated(borrower, asset, msg.sender, offset, seized);
    }
}
