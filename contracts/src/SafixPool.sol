// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Guardable} from "./Guardable.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPassportRegistry} from "./interfaces/IPassportRegistry.sol";

contract SafixPool is Guardable {
    /// @notice Pausable actions. Each is a bit, so `pause(PAUSE_ALL)` is one transaction.
    /// Only the three ways new risk enters the pool are pausable. Repaying, closing a position,
    /// withdrawing collateral, claiming gains and withdrawing liquidity have no switch at all:
    /// whatever the emergency, nobody is locked in.
    uint8 public constant PAUSE_DRAWS = 1;
    uint8 public constant PAUSE_DEPOSITS = 2;
    uint8 public constant PAUSE_LIQUIDATIONS = 4;
    uint8 public constant PAUSE_ALL = 7;

    /// @param debtCap       most stable that may be owed against this asset at once, 0 for uncapped
    /// @param collateralCap most of this asset the pool will hold as collateral, 0 for uncapped
    ///
    /// Both caps are appended after the original four fields, so a reader built against the older
    /// shape still decodes the first four correctly.
    struct AssetConfig {
        bool enabled;
        uint16 maxLtvBps;
        uint16 liqThresholdBps;
        uint256 priceUsd1e18;
        uint256 debtCap;
        uint256 collateralCap;
    }

    /// @notice Per-asset limits a price has to satisfy before the pool will act on it. Each field is
    ///         off when zero, so an asset with no guard behaves as it did before one was configured.
    /// @param maxPriceAge     seconds a price may be old, set to the feed's own heartbeat
    /// @param maxDeviationBps how far a price may move from the previous update
    /// @param minPrice1e18    lower sanity bound
    /// @param maxPrice1e18    upper sanity bound
    struct PriceGuard {
        uint64 maxPriceAge;
        uint16 maxDeviationBps;
        uint256 minPrice1e18;
        uint256 maxPrice1e18;
    }

    /// @notice Why a price may not be acted on. Callers that must not revert read this instead.
    enum PriceStatus {
        Ok,
        AssetDisabled,
        SequencerDown,
        SequencerGracePeriod,
        FeedUnavailable,
        Stale,
        BelowBand,
        AboveBand,
        DeviationTooLarge
    }

    /// @param principal the part of `debt` that was drawn rather than charged as an origination fee,
    ///                  and has not been paid back yet. It is the redemption fee's base (#33): paying
    ///                  principal back, by a repayment or at close, pays the fee on it, and a
    ///                  liquidation retires it in proportion without one. It never exceeds `debt`.
    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 principal;
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

    /// @notice Holds the delay on risk parameters. Zero means none is wired yet and the owner still
    ///         sets them directly, which is the state a deployment is configured in.
    address public timelock;

    address public priceUpdater;
    address public passportRegistry;

    uint16 public originationFeeBps = 50;
    uint16 public redemptionFeeBps = 30;
    uint16 public liquidationIncentiveBps = 50;
    uint256 public protocolFees;
    mapping(address => uint256) public priceUpdatedAt;
    mapping(address => address) public priceFeeds;
    mapping(address => uint8) public priceFeedDecimals;
    mapping(address => PriceGuard) public priceGuards;

    /// @notice Chainlink L2 sequencer uptime feed. Robinhood Chain is an Orbit rollup, so a price
    ///         feed can keep returning a recent-looking answer while the sequencer is down or has
    ///         only just come back, which is exactly when a liquidation would fire on a price
    ///         nobody had a chance to react to. Zero means no feed is wired yet.
    address public sequencerUptimeFeed;

    /// @notice How long after the sequencer comes back before prices are trusted again, giving
    ///         borrowers a window to repay or add collateral before liquidations resume.
    uint256 public sequencerGracePeriod;

    address[] public assetList;
    mapping(address => AssetConfig) public assetConfig;
    mapping(address => mapping(address => Position)) public positions;

    /// @notice Stable currently owed against each asset, and how much of each asset the pool holds
    ///         as collateral. Accumulators rather than views: summing over every borrower would not
    ///         survive the book growing, and the interface needs to show remaining room cheaply.
    mapping(address => uint256) public assetDebt;
    mapping(address => uint256) public assetCollateral;

    /// @notice Stable owed across every asset, kept against `globalDebtCeiling`.
    uint256 public totalDebt;

    /// @notice Most the pool will lend in total, 0 for uncapped.
    uint256 public globalDebtCeiling;

    /// @notice Smallest debt a position may carry while open. A position below this is worth less
    ///         than the gas to liquidate it, so it would sit there unliquidatable; positions are
    ///         held at or above it, or closed outright. 0 disables the floor.
    uint256 public minPositionDebt;

    /// @notice Liquidity a draw must leave behind, so the pool cannot be drained to the point where
    ///         providers cannot withdraw and liquidations cannot be absorbed. 0 disables the floor.
    uint256 public minLiquidityBuffer;

    /// @notice Stable held against bad debt. It sits in the pool's balance but belongs to neither
    ///         the providers nor the fee treasury, so it is excluded from available liquidity the
    ///         same way protocol fees are.
    ///
    /// The policy, in one line: **the reserve absorbs a shortfall first, and only what it cannot
    /// cover is socialised across providers — and even then it is recorded rather than absorbed
    /// silently.** Holding it against protocol fees alone was rejected because fees are revenue that
    /// gets withdrawn; a reserve that can be spent elsewhere is not a reserve. Socialising first was
    /// rejected because a provider should not be the first line of defence against a gap they had no
    /// part in. Funding it from a share of origination fees ties the buffer to the volume that
    /// creates the risk.
    uint256 public reserve;

    /// @notice Share of each origination fee routed to the reserve rather than to protocol fees.
    uint16 public reserveFeeShareBps;

    /// @notice Shortfall the reserve could not cover, which providers absorbed. Kept as a running
    ///         total so the loss has a name and a number instead of disappearing into the
    ///         product-sum accounting.
    uint256 public badDebt;

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
    /// @notice The redemption fee paid with a repayment, on the principal that repayment retired. A
    ///         close reports its own fee in `PositionClosed`.
    event RedemptionFeePaid(address indexed borrower, address indexed asset, uint256 principalRetired, uint256 fee);
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
    event TimelockSet(address indexed timelock);
    event PriceUpdaterSet(address indexed updater);
    event PriceFeedSet(address indexed asset, address indexed feed);
    event PassportRegistrySet(address indexed registry);
    event LiquidationIncentiveSet(uint16 bps);
    event FeesSet(uint16 originationBps, uint16 redemptionBps);
    event SequencerUptimeFeedSet(address indexed feed, uint256 gracePeriod);
    event AssetCapsSet(address indexed asset, uint256 debtCap, uint256 collateralCap);
    event AssetRetired(address indexed asset, bool retired);

    /// @notice Assets closed to new exposure. Kept beside `assetConfig` rather than inside it: a
    ///         seventh field would change that getter's shape and every reader built against it.
    mapping(address => bool) public assetRetired;
    event ReserveFeeShareSet(uint16 bps);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserveAfter);
    event ReserveWithdrawn(address indexed to, uint256 amount, uint256 reserveAfter);
    event BadDebtRealised(
        address indexed borrower,
        address indexed asset,
        uint256 shortfall,
        uint256 fromReserve,
        uint256 socialised
    );
    event RiskLimitsSet(uint256 globalDebtCeiling, uint256 minPositionDebt, uint256 minLiquidityBuffer);
    event PriceGuardSet(
        address indexed asset,
        uint64 maxPriceAge,
        uint16 maxDeviationBps,
        uint256 minPrice1e18,
        uint256 maxPrice1e18
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @dev Guards the parameters that change what a position is worth or when it is liquidated.
    ///      Until a timelock is wired the owner holds this, which is how a fresh deployment gets
    ///      configured; once one is set, the owner cannot reach these functions at all.
    modifier onlyTimelock() {
        require(msg.sender == (timelock == address(0) ? owner : timelock), "not timelock");
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

    /// @notice Hands the owner role to another address.
    /// @dev    The owner pauses, unpauses, collects fees, appoints the guardian and the price
    ///         updater, and absorbs bad debt. It is the operational key, distinct from the timelock
    ///         that holds the parameters. Zero is refused: an ownerless pool could never be paused
    ///         again, and pausing is the one thing that has to work at the worst moment.
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    /// @notice Wires the timelock that risk parameters have to pass through. Set once at handover;
    ///         afterwards the owner can no longer change an LTV, a fee or a cap directly.
    function setTimelock(address newTimelock) external onlyTimelock {
        timelock = newTimelock;
        emit TimelockSet(newTimelock);
    }

    /// @notice Appoints the guardian. Separate from the owner so the brake can be held by a key
    ///         that is quick to reach, without giving it the owner's authority.
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @notice Stops the given actions immediately. No timelock: a brake that waits is not a brake.
    ///         `pause(PAUSE_ALL)` stops every way new risk enters the pool in a single transaction.
    function pause(uint8 actions) external {
        require(msg.sender == guardian || msg.sender == owner, "not guardian");
        _pause(actions, msg.sender);
    }

    /// @notice Resumes the given actions. Owner only, never the guardian alone: stopping is urgent,
    ///         restarting is a decision.
    function unpause(uint8 actions) external onlyOwner {
        _unpause(actions, msg.sender);
    }

    /// @notice Sets what a borrower pays at the door and on the way out, in basis points.
    /// @dev    Behind the timelock, and capped at five percent each, because these are the whole
    ///         cost of a loan here: there is no interest to dilute a change, so a fee moved without
    ///         notice lands entirely on the next borrower. The cap is what stops a compromised
    ///         timelock from turning a draw into a confiscation. Existing debt is unaffected; the
    ///         origination fee was charged when it was drawn, and the redemption fee is read as
    ///         principal returns.
    function setFees(uint16 originationBps, uint16 redemptionBps) external onlyTimelock {
        require(originationBps <= 500 && redemptionBps <= 500, "fee too high");
        originationFeeBps = originationBps;
        redemptionFeeBps = redemptionBps;
        emit FeesSet(originationBps, redemptionBps);
    }

    /// @notice Appoints the address allowed to post prices alongside the owner.
    /// @dev    `onlyOwner` rather than the timelock on purpose: a pool that cannot price an asset
    ///         refuses every draw, every withdrawal against collateral and every liquidation, so
    ///         restoring the ability to price has to be immediate rather than delayed. Zero retires
    ///         the role, which is what a pool whose assets all carry feeds should do.
    function setPriceUpdater(address updater) external onlyOwner {
        priceUpdater = updater;
        emit PriceUpdaterSet(updater);
    }

    /// @notice Points the pool at the registry it reads credit passports from.
    /// @dev    Zero means no passport is required to draw, which is the state a permissionless
    ///         deployment stays in. Setting one gates drawing on whatever `requiredPassport`
    ///         demands, and the registry is read rather than copied, so a revocation there takes
    ///         effect here on the next draw.
    function setPassportRegistry(address registry) external onlyOwner {
        passportRegistry = registry;
        emit PassportRegistrySet(registry);
    }

    /// @notice Sets the cut a liquidator keeps of the collateral it seizes, in basis points.
    /// @dev    The pool cannot rely on one keeper being awake, so it pays whoever closes a bad
    ///         position. Capped at two percent: every point paid here comes out of what the
    ///         providers receive, and a liquidation is supposed to fund them rather than the person
    ///         who noticed it first.
    function setLiquidationIncentive(uint16 bps) external onlyTimelock {
        require(bps <= 200, "too high");
        liquidationIncentiveBps = bps;
        emit LiquidationIncentiveSet(bps);
    }

    /// @notice Wires the L2 sequencer uptime feed. Passing the zero address removes it, which is the
    ///         state a chain without a published feed starts in.
    function setSequencerUptimeFeed(address feed, uint256 gracePeriod) external onlyOwner {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerUptimeFeedSet(feed, gracePeriod);
    }

    /// @notice Sets the limits a price for this asset has to satisfy. Age is per asset rather than
    ///         global because each feed has its own heartbeat; a treasury feed that updates daily
    ///         and an equity feed that updates hourly cannot share one deadline.
    function setPriceGuard(
        address asset,
        uint64 maxPriceAge,
        uint16 maxDeviationBps,
        uint256 minPrice1e18,
        uint256 maxPrice1e18
    ) external onlyTimelock {
        require(maxDeviationBps <= BPS, "bad deviation");
        require(maxPrice1e18 == 0 || minPrice1e18 <= maxPrice1e18, "bad band");
        priceGuards[asset] = PriceGuard({
            maxPriceAge: maxPriceAge,
            maxDeviationBps: maxDeviationBps,
            minPrice1e18: minPrice1e18,
            maxPrice1e18: maxPrice1e18
        });
        emit PriceGuardSet(asset, maxPriceAge, maxDeviationBps, minPrice1e18, maxPrice1e18);
    }

    /// @notice Accepts an asset as collateral, or changes the terms it is accepted on.
    /// @param asset            the token the pool will hold
    /// @param maxLtvBps        the most that may be owed against it, as a share of its value
    /// @param liqThresholdBps  the share at which the position may be liquidated
    /// @param priceUsd1e18     its price now, until a feed or the price updater moves it
    /// @dev    The two ratios are what separate a borrower from liquidation, so the gap between
    ///         them is the room a price has to move before a position is closed. Configuring an
    ///         asset that is already configured changes its terms rather than adding it twice.
    ///         There is no way back to unconfigured: use `setAssetRetired` to stop new exposure
    ///         while what is outstanding stays liquidatable.
    function configureAsset(
        address asset,
        uint16 maxLtvBps,
        uint16 liqThresholdBps,
        uint256 priceUsd1e18
    ) external onlyTimelock {
        require(maxLtvBps < liqThresholdBps && liqThresholdBps <= BPS, "bad config");
        AssetConfig storage config = assetConfig[asset];
        if (!config.enabled) assetList.push(asset);
        // Fields are assigned rather than the struct replaced, so reconfiguring an asset's LTV does
        // not silently drop the caps that bound it.
        config.enabled = true;
        config.maxLtvBps = maxLtvBps;
        config.liqThresholdBps = liqThresholdBps;
        config.priceUsd1e18 = priceUsd1e18;
        priceUpdatedAt[asset] = block.timestamp;
        emit AssetConfigured(asset, maxLtvBps, liqThresholdBps);
    }

    /// @notice Share of each origination fee that goes to the reserve instead of protocol fees.
    ///         Capped at half: past that the protocol stops funding itself, and a reserve nobody can
    ///         afford to operate around is not risk management.
    function setReserveFeeShare(uint16 bps) external onlyTimelock {
        require(bps <= 5_000, "share too high");
        reserveFeeShareBps = bps;
        emit ReserveFeeShareSet(bps);
    }

    /// @notice Adds stable to the reserve from outside the fee stream. Open to anyone, because a
    ///         protocol seeding its own buffer at launch, or a partner topping it up, should not
    ///         need a privileged path.
    function fundReserve(uint256 amount) external nonReentrant {
        require(amount > 0, "zero");
        reserve += amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    /// @notice Takes stable back out of the reserve, through the timelock. The reserve is the
    ///         providers' buffer: emptying it touches no deposit, but it decides who carries the
    ///         next shortfall, so taking money out gets the same notice as every other change to a
    ///         lender's exposure. Funding stays instant and open to anyone. It cannot reach further
    ///         than the reserve holds, so it can never be a path into provider deposits.
    function withdrawReserve(address to, uint256 amount) external onlyTimelock nonReentrant {
        require(amount > 0 && amount <= reserve, "bad amount");
        reserve -= amount;
        require(stable.transfer(to, amount), "transfer failed");
        emit ReserveWithdrawn(to, amount, reserve);
    }

    /// @notice Bounds how much of the pool one asset may account for. Set independently of
    ///         `configureAsset` so tuning an LTV never disturbs a cap, or the other way round.
    ///         Either cap may be lowered below current usage: that stops further growth without
    ///         forcing anything open to unwind, which would be a liquidation by another name.
    /// @notice Stops new exposure to an asset without touching what is already outstanding.
    /// @dev    An asset can outlive its usefulness: the stock behind it is delisted, its token is
    ///         compromised, its feed is retired. Until now the pool had no way to say so. Setting a
    ///         cap to zero says the opposite, because zero means uncapped, and clearing `enabled`
    ///         would take the price with it and leave existing positions unliquidatable, which
    ///         turns a bad asset into frozen bad debt.
    ///
    ///         So retirement is deliberately narrow. Locking collateral and drawing are refused.
    ///         Repaying, closing, withdrawing collateral and liquidating all carry on exactly as
    ///         before, because the pool still has to be able to get out of what it already holds.
    function setAssetRetired(address asset, bool retired) external onlyTimelock {
        require(assetConfig[asset].enabled, "asset off");
        assetRetired[asset] = retired;
        emit AssetRetired(asset, retired);
    }

    /// @notice Limits how much may be owed against an asset and how much of it the pool will hold.
    /// @dev    Zero means uncapped, not closed, which is worth reading twice: to stop new exposure
    ///         use `setAssetRetired`. Caps bound concentration in a single asset, so one collateral
    ///         going bad cannot take the whole pool with it.
    function setAssetCaps(address asset, uint256 debtCap, uint256 collateralCap) external onlyTimelock {
        require(assetConfig[asset].enabled, "asset off");
        assetConfig[asset].debtCap = debtCap;
        assetConfig[asset].collateralCap = collateralCap;
        emit AssetCapsSet(asset, debtCap, collateralCap);
    }

    /// @notice The pool-wide limits: how much may be owed in total, how small a position may be,
    ///         and how much liquidity a draw has to leave behind. Zero disables any of them.
    function setRiskLimits(uint256 globalDebtCeiling_, uint256 minPositionDebt_, uint256 minLiquidityBuffer_)
        external
        onlyTimelock
    {
        globalDebtCeiling = globalDebtCeiling_;
        minPositionDebt = minPositionDebt_;
        minLiquidityBuffer = minLiquidityBuffer_;
        emit RiskLimitsSet(globalDebtCeiling_, minPositionDebt_, minLiquidityBuffer_);
    }

    /// @notice How much more may be drawn against this asset before its own cap binds. Uncapped
    ///         assets report the maximum, so the interface can take a minimum across limits without
    ///         special-casing. This is the number a borrow screen needs before a signature, rather
    ///         than discovering the boundary through a revert.
    function assetDebtHeadroom(address asset) public view returns (uint256) {
        uint256 cap = assetConfig[asset].debtCap;
        if (cap == 0) return type(uint256).max;
        uint256 used = assetDebt[asset];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice How much more of this asset the pool will accept as collateral.
    function assetCollateralHeadroom(address asset) public view returns (uint256) {
        uint256 cap = assetConfig[asset].collateralCap;
        if (cap == 0) return type(uint256).max;
        uint256 used = assetCollateral[asset];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice How much more the pool will lend in total before the global ceiling binds.
    function globalDebtHeadroom() public view returns (uint256) {
        if (globalDebtCeiling == 0) return type(uint256).max;
        return totalDebt >= globalDebtCeiling ? 0 : globalDebtCeiling - totalDebt;
    }

    /// @notice Liquidity a draw may take before it would breach the buffer.
    function drawableLiquidity() public view returns (uint256) {
        uint256 available = availableLiquidity();
        if (minLiquidityBuffer == 0) return available;
        return available <= minLiquidityBuffer ? 0 : available - minLiquidityBuffer;
    }

    /// @notice Manual price for an asset without a feed. The same sanity bounds a feed answer has to
    ///         clear are enforced here, so a mistaken or compromised updater cannot post a price the
    ///         pool would refuse from an oracle.
    function setPrice(address asset, uint256 priceUsd1e18) external {
        require(msg.sender == owner || msg.sender == priceUpdater, "not price updater");
        require(assetConfig[asset].enabled, "asset off");
        PriceGuard storage guard = priceGuards[asset];
        if (guard.minPrice1e18 != 0) require(priceUsd1e18 >= guard.minPrice1e18, "price below band");
        if (guard.maxPrice1e18 != 0) require(priceUsd1e18 <= guard.maxPrice1e18, "price above band");
        uint256 previous = assetConfig[asset].priceUsd1e18;
        if (guard.maxDeviationBps != 0 && previous != 0) {
            uint256 movement = priceUsd1e18 > previous ? priceUsd1e18 - previous : previous - priceUsd1e18;
            require((movement * BPS) / previous <= guard.maxDeviationBps, "price jump");
        }
        assetConfig[asset].priceUsd1e18 = priceUsd1e18;
        priceUpdatedAt[asset] = block.timestamp;
        emit PriceSet(asset, priceUsd1e18);
    }

    /// @notice Points an asset at a Chainlink feed, or takes it off one.
    /// @dev    A feed replaces the posted price entirely for that asset, so this is what retires the
    ///         manual updater. The feed's own decimals are read and stored once here rather than
    ///         assumed, and more than eighteen is refused because the conversion to 1e18 would
    ///         underflow. Zero returns the asset to whatever price was last posted.
    function setPriceFeed(address asset, address feed) external onlyTimelock {
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

    /// @dev Reads the raw price without judging it. Never reverts: a feed that is unreachable or
    ///      answering nonsense comes back as not available, so view callers keep working.
    function _readPrice(address asset)
        internal
        view
        returns (bool available, uint256 price1e18, uint256 updatedAt, uint80 roundId)
    {
        address feed = priceFeeds[asset];
        if (feed == address(0)) {
            uint256 manual = assetConfig[asset].priceUsd1e18;
            return (manual > 0, manual, priceUpdatedAt[asset], 0);
        }
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80 id, int256 answer, uint256, uint256 feedUpdatedAt, uint80
        ) {
            if (answer <= 0 || feedUpdatedAt == 0) return (false, 0, 0, 0);
            return (true, uint256(answer) * 10 ** (18 - priceFeedDecimals[asset]), feedUpdatedAt, id);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /// @dev True when the sequencer is up and has been up for longer than the grace period. With no
    ///      feed wired there is nothing to check, so pricing proceeds as it did before.
    function _sequencerStatus() internal view returns (PriceStatus) {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return PriceStatus.Ok;
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            // Chainlink's convention: 0 is up, 1 is down. startedAt is when that last changed, and a
            // zero there means the feed has not started, which is not something to trust prices on.
            if (answer != 0 || startedAt == 0 || startedAt > block.timestamp) return PriceStatus.SequencerDown;
            if (block.timestamp - startedAt <= sequencerGracePeriod) return PriceStatus.SequencerGracePeriod;
            return PriceStatus.Ok;
        } catch {
            return PriceStatus.SequencerDown;
        }
    }

    /// @dev How far the latest feed answer moved from the one before it. Compares consecutive rounds
    ///      rather than tracking a stored reference, so a quiet market never drifts into a rejection.
    function _deviationExceeded(address asset, uint256 price1e18, uint80 roundId, uint16 maxDeviationBps)
        internal
        view
        returns (bool)
    {
        if (maxDeviationBps == 0 || roundId == 0) return false;
        address feed = priceFeeds[asset];
        if (feed == address(0)) return false;
        try IAggregatorV3(feed).getRoundData(roundId - 1) returns (
            uint80, int256 answer, uint256, uint256 previousUpdatedAt, uint80
        ) {
            if (answer <= 0 || previousUpdatedAt == 0) return false;
            uint256 previous = uint256(answer) * 10 ** (18 - priceFeedDecimals[asset]);
            uint256 movement = price1e18 > previous ? price1e18 - previous : previous - price1e18;
            return (movement * BPS) / previous > maxDeviationBps;
        } catch {
            // No previous round to compare against is not itself a reason to reject.
            return false;
        }
    }

    /// @notice Whether this asset's price can be acted on, and why not when it cannot. Reverts for
    ///         nothing, so keepers, the interface and internal view callers can all ask safely.
    function priceStatus(address asset)
        public
        view
        returns (PriceStatus status, uint256 price1e18, uint256 updatedAt)
    {
        if (!assetConfig[asset].enabled) return (PriceStatus.AssetDisabled, 0, 0);

        PriceStatus sequencer = _sequencerStatus();
        if (sequencer != PriceStatus.Ok) return (sequencer, 0, 0);

        (bool available, uint256 price, uint256 at, uint80 roundId) = _readPrice(asset);
        if (!available) return (PriceStatus.FeedUnavailable, 0, 0);

        PriceGuard storage guard = priceGuards[asset];
        if (guard.minPrice1e18 != 0 && price < guard.minPrice1e18) return (PriceStatus.BelowBand, price, at);
        if (guard.maxPrice1e18 != 0 && price > guard.maxPrice1e18) return (PriceStatus.AboveBand, price, at);
        if (at > block.timestamp) return (PriceStatus.Stale, price, at);
        if (guard.maxPriceAge != 0 && block.timestamp - at > guard.maxPriceAge) {
            return (PriceStatus.Stale, price, at);
        }
        if (_deviationExceeded(asset, price, roundId, guard.maxDeviationBps)) {
            return (PriceStatus.DeviationTooLarge, price, at);
        }
        return (PriceStatus.Ok, price, at);
    }

    /// @notice The price as reported, without the guards. Kept for readers that want the raw number.
    function currentPrice(address asset) public view returns (uint256 price1e18, uint256 updatedAt) {
        (bool available, uint256 price, uint256 at,) = _readPrice(asset);
        require(available, "bad feed answer");
        return (price, at);
    }

    /// @dev Every path that puts a borrower at risk on a price goes through here.
    function _requireUsablePrice(address asset) internal view returns (uint256 price1e18) {
        PriceStatus status;
        (status, price1e18,) = priceStatus(asset);
        if (status == PriceStatus.Ok) return price1e18;
        if (status == PriceStatus.SequencerDown) revert("sequencer down");
        if (status == PriceStatus.SequencerGracePeriod) revert("sequencer grace period");
        if (status == PriceStatus.FeedUnavailable) revert("feed unavailable");
        if (status == PriceStatus.Stale) revert("stale price");
        if (status == PriceStatus.BelowBand) revert("price below band");
        if (status == PriceStatus.AboveBand) revert("price above band");
        if (status == PriceStatus.DeviationTooLarge) revert("price jump");
        revert("asset off");
    }

    /// @notice Sends the protocol's accumulated fees to an address of the owner's choosing.
    /// @dev    Only what fees produced: this counter is separate from deposits and from the
    ///         reserve, and `availableLiquidity` already excludes it, so collecting cannot reach
    ///         providers' money or the buffer that stands in front of them. Zeroed before the
    ///         transfer, which is what makes the reentrancy guard belt as well as braces.
    function collectProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amount = protocolFees;
        protocolFees = 0;
        require(stable.transfer(to, amount), "transfer failed");
        emit FeesCollected(to, amount);
    }

    /// @notice How many assets have ever been configured as collateral.
    /// @dev    Configured, not currently accepted: a retired asset is still counted, because it is
    ///         still one the pool holds and may have to liquidate.
    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    /// @notice What an amount of an asset is worth in stable units, at the price the pool holds.
    /// @dev    Reverts rather than guessing when the price is not usable, because a value derived
    ///         from a price the pool refuses to act on would be a number that looks like a fact.
    function collateralValueStable(address asset, uint256 amount) public view returns (uint256) {
        (uint256 price1e18,) = currentPrice(asset);
        return (amount * price1e18) / 1e30;
    }

    /// @notice What a provider's deposit is worth now, after the liquidations it absorbed.
    /// @dev    Deposits shrink as the pool takes losses. The product-sum accounting tracks that
    ///         without touching each record: a deposit two scale rollovers behind has been reduced
    ///         past what the arithmetic can represent and is worth nothing, which this reports as
    ///         zero rather than as a number the division would otherwise produce.
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

    /// @notice The collateral a provider has earned in an asset and not yet claimed.
    /// @dev    This is the return on a deposit. It grows only when a liquidation happens, which is
    ///         why a quiet market pays a provider nothing.
    function gainOf(address provider, address asset) public view returns (uint256) {
        DepositRecord storage record = depositRecords[provider];
        return pendingGains[provider][asset] + _gainSince(record, asset);
    }

    /// @notice Stable that can actually be lent or withdrawn: the balance less the two claims on it
    ///         that belong to neither providers nor borrowers.
    function availableLiquidity() public view returns (uint256) {
        uint256 balance = stable.balanceOf(address(this));
        uint256 committed = protocolFees + reserve;
        return balance > committed ? balance - committed : 0;
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

    /// @notice Puts stable into the pool, to be lent out and to absorb liquidations.
    /// @dev    A deposit buys a share of what the pool earns and of what it loses. There is no
    ///         interest: providers are paid when a position is liquidated and its collateral comes
    ///         to them at a discount, so a quiet market pays nothing and a violent one pays well.
    ///         Gains already accrued are realised before the stake changes, so a new deposit never
    ///         dilutes what this provider was already owed.
    function deposit(uint256 amount) external nonReentrant {
        require(!isPaused(PAUSE_DEPOSITS), "deposits paused");
        require(amount > 0, "zero");
        _realize(msg.sender);
        DepositRecord storage record = depositRecords[msg.sender];
        record.rawStake += amount;
        totalDeposits += amount;
        require(stable.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposited(msg.sender, amount);
    }

    /// @notice Takes stable back out of the pool.
    /// @dev    Limited by what is not currently lent out, not by what was deposited: a provider
    ///         whose money is in a borrower's hands waits for it to be repaid or liquidated. This
    ///         is the one lever a provider has and it is deliberately not pausable.
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

    /// @notice Collects the collateral this provider's deposits earned from liquidations.
    /// @dev    Gains are the return: a liquidated position's collateral arrives here at a discount
    ///         to its price, split across providers by what each had in the pool at the time. Taken
    ///         per asset because they are separate tokens, and the caller names which ones it wants
    ///         rather than the pool walking a list that could grow past what fits in a block.
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

    /// @notice Moves collateral into the caller's position, without borrowing anything yet.
    /// @dev    Separate from `draw` so that locking and borrowing are two decisions: collateral can
    ///         be added to a position under pressure without also taking on more debt. Refused for
    ///         a retired asset, since that is new exposure to something the protocol is winding
    ///         down.
    function lockCollateral(address asset, uint256 amount) external nonReentrant {
        require(assetConfig[asset].enabled, "asset off");
        require(!assetRetired[asset], "asset retired");
        require(amount > 0, "zero");
        require(amount <= assetCollateralHeadroom(asset), "collateral cap");
        positions[msg.sender][asset].collateral += amount;
        assetCollateral[asset] += amount;
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit CollateralLocked(msg.sender, asset, amount);
    }

    /// @notice Takes collateral back out, as far as the debt against it allows.
    /// @dev    Needs a usable price, because what is left has to still cover what is owed. A
    ///         position with no debt can be emptied entirely; one with debt may withdraw only down
    ///         to its borrowing limit, not down to its liquidation threshold, so a withdrawal never
    ///         leaves a position one tick from being closed.
    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(amount > 0 && amount <= position.collateral, "bad amount");
        uint256 remaining = position.collateral - amount;
        // A position that still owes has to close to release the last of its collateral. Principal
        // never exceeds debt, so once the debt is repaid the redemption fee has been paid with it and
        // a close would collect nothing: there is no reason left to hold the collateral back.
        if (position.debt > 0) {
            require(remaining > 0, "close position instead");
        }
        // With no debt there is nothing a price could tell us, so an unusable feed never traps
        // collateral. Only a withdrawal that has to be checked against a loan needs a price.
        if (position.debt > 0) {
            uint256 price1e18 = _requireUsablePrice(asset);
            uint256 remainingValue = (remaining * price1e18) / 1e30;
            require(
                (remainingValue * assetConfig[asset].maxLtvBps) / BPS >= position.debt,
                "would break ltv"
            );
        }
        position.collateral = remaining;
        assetCollateral[asset] -= amount;
        require(IERC20(asset).transfer(msg.sender, amount), "transfer failed");
        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    /// @notice Borrows stable against collateral already locked.
    /// @dev    The fee is charged here, once, and added to the debt. Nothing accrues afterwards:
    ///         the debt recorded now is the debt owed in ten years, which is what makes the
    ///         liquidation threshold a function of price alone rather than of price and time.
    ///         Refused when the asset is retired, when the price is not usable, when a cap or the
    ///         pool's liquidity is reached, and when the position would be left below the minimum
    ///         worth liquidating.
    function draw(address asset, uint256 amount) external nonReentrant {
        require(!isPaused(PAUSE_DRAWS), "draws paused");
        AssetConfig storage config = assetConfig[asset];
        require(config.enabled, "asset off");
        require(!assetRetired[asset], "asset retired");
        require(amount > 0, "zero");
        uint256 price1e18 = _requireUsablePrice(asset);
        if (passportRegistry != address(0)) {
            require(IPassportRegistry(passportRegistry).isEligible(msg.sender), "passport required");
        }
        Position storage position = positions[msg.sender][asset];
        uint256 fee = (amount * originationFeeBps) / BPS;
        uint256 newDebt = position.debt + amount + fee;
        uint256 value = (position.collateral * price1e18) / 1e30;
        require((value * config.maxLtvBps) / BPS >= newDebt, "exceeds ltv");

        // Caps are measured against debt, fee included, because that is what the pool is owed.
        uint256 debtAdded = amount + fee;
        require(debtAdded <= assetDebtHeadroom(asset), "asset cap");
        require(debtAdded <= globalDebtHeadroom(), "global cap");
        require(newDebt >= minPositionDebt, "position too small");
        // Available liquidity falls by the fee as well as the amount, because the fee is set aside
        // as protocol revenue rather than left lendable. Checking the amount alone would let a draw
        // dip the pool under its own buffer by exactly the fee.
        require(debtAdded <= drawableLiquidity(), "illiquid");

        position.debt = newDebt;
        position.principal += amount;
        assetDebt[asset] += debtAdded;
        totalDebt += debtAdded;
        // The reserve is funded from the same event that creates the risk it covers.
        uint256 toReserve = (fee * reserveFeeShareBps) / BPS;
        reserve += toReserve;
        protocolFees += fee - toReserve;
        require(stable.transfer(msg.sender, amount), "transfer failed");
        emit Drawn(msg.sender, asset, amount, fee);
    }

    /// @dev The redemption fee on principal paid back. Rounded down, as it always was at close.
    function _redemptionFee(uint256 principal) internal view returns (uint256) {
        return (principal * redemptionFeeBps) / BPS;
    }

    /// @notice Pays `amount` of debt, and with it the redemption fee on the principal it retires. The
    ///         fee is paid on principal as it goes back rather than all at close, so repaying before
    ///         closing skips nothing. `repaymentOwed` quotes both before the signature.
    function repay(address asset, uint256 amount) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(amount > 0 && amount <= position.debt, "bad amount");
        uint256 remaining = position.debt - amount;
        // A repayment that would leave dust takes the whole debt instead, the way `liquidate`
        // takes the whole position rather than leave dust behind. Refusing it would refuse the one
        // repayment that cures an unhealthy position whenever the floor sits above the healthy
        // debt, and would leave a position under a floor raised after it opened repayable only in
        // full, by a second call. The position still ends at zero or at the floor and above, never
        // in between. It escalates only when the borrower has approved and holds the whole debt and
        // the redemption fee on the whole principal; otherwise the refusal stands with its reason,
        // rather than surfacing as a token error about an allowance nobody asked for.
        if (remaining != 0 && remaining < minPositionDebt) {
            uint256 whole = position.debt + _redemptionFee(position.principal);
            require(
                stable.allowance(msg.sender, address(this)) >= whole && stable.balanceOf(msg.sender) >= whole,
                "position too small"
            );
            amount = position.debt;
            remaining = 0;
        }
        // Principal goes back in proportion to the debt repaid, and pays the redemption fee as it
        // goes. Proportion keeps principal at or below the debt, which is what bounds what a later
        // liquidation can retire without a fee. A repayment of the whole debt retires all of it.
        uint256 principalRetired = (position.principal * amount) / position.debt;
        uint256 fee = _redemptionFee(principalRetired);
        position.debt = remaining;
        position.principal -= principalRetired;
        assetDebt[asset] -= amount;
        totalDebt -= amount;
        protocolFees += fee;
        require(stable.transferFrom(msg.sender, address(this), amount + fee), "transfer failed");
        emit Repaid(msg.sender, asset, amount);
        if (principalRetired > 0) emit RedemptionFeePaid(msg.sender, asset, principalRetired, fee);
    }

    /// @notice What `repay(asset, amount)` would take from `borrower`: the debt it retires and the
    ///         redemption fee on the principal inside it. It applies the same dust rule `repay` does,
    ///         so an interface can approve the right amount before the signature, including the whole
    ///         debt and its fee when the amount asked for would leave dust, and it refuses what repay
    ///         refuses.
    function repaymentOwed(address borrower, address asset, uint256 amount)
        external
        view
        returns (uint256 debtRetired, uint256 fee)
    {
        Position storage position = positions[borrower][asset];
        require(amount > 0 && amount <= position.debt, "bad amount");
        debtRetired = amount;
        uint256 remaining = position.debt - amount;
        if (remaining != 0 && remaining < minPositionDebt) debtRetired = position.debt;
        fee = _redemptionFee((position.principal * debtRetired) / position.debt);
    }

    /// @notice Repays everything owed and returns the collateral in one call.
    /// @dev    The way out for a borrower who wants to be done: repaying to zero and withdrawing
    ///         separately costs two transactions and leaves a window between them. Not pausable,
    ///         like every other exit, because a borrower must always be able to get out.
    function closePosition(address asset) external nonReentrant {
        Position storage position = positions[msg.sender][asset];
        require(position.collateral > 0 || position.debt > 0, "no position");
        // Whatever principal is still outstanding pays its fee now; what went back earlier paid then.
        uint256 redemptionFee = _redemptionFee(position.principal);
        uint256 owed = position.debt + redemptionFee;
        uint256 collateral = position.collateral;
        assetDebt[asset] -= position.debt;
        totalDebt -= position.debt;
        assetCollateral[asset] -= collateral;
        position.collateral = 0;
        position.debt = 0;
        position.principal = 0;
        protocolFees += redemptionFee;
        if (owed > 0) {
            require(stable.transferFrom(msg.sender, address(this), owed), "transfer failed");
        }
        if (collateral > 0) {
            require(IERC20(asset).transfer(msg.sender, collateral), "transfer failed");
        }
        emit PositionClosed(msg.sender, asset, redemptionFee);
    }

    /// @notice A position is only liquidatable on a price the pool is willing to act on. While the
    ///         sequencer is down or recovering, or the price is stale, out of band or a sudden jump,
    ///         this answers false: no keeper is told to seize collateral on a number nobody could
    ///         have reacted to. It never reverts, so a keeper scanning positions is not knocked over
    ///         by one unusable feed.
    /// @notice Clears a position whose remaining collateral is worth less than the gas to liquidate
    ///         it. Nobody will take it: the keeper incentive is a share of something close to
    ///         nothing, so the debt would sit on the book forever and the collateral with it.
    ///
    /// The pool takes the collateral, cancels the debt, and books the gap through the same reserve
    /// and socialisation path a liquidation uses. No keeper incentive is carved out, because there
    /// is no keeper and nothing worth paying one from.
    ///
    /// Owner only, and only for a position that is both liquidatable and genuinely dust, so this
    /// can never be a way to close a healthy loan. It needs `minPositionDebt` set, since that is
    /// what defines dust.
    function absorbBadDebt(address borrower, address asset) external onlyOwner nonReentrant {
        require(minPositionDebt > 0, "no dust threshold");
        uint256 price1e18 = _requireUsablePrice(asset);
        require(isLiquidatable(borrower, asset), "healthy");

        Position storage position = positions[borrower][asset];
        uint256 collateral = position.collateral;
        uint256 debt = position.debt;
        uint256 collateralValue = (collateral * price1e18) / 1e30;
        require(collateralValue < minPositionDebt, "not dust");

        position.collateral = 0;
        position.debt = 0;
        position.principal = 0;
        assetDebt[asset] -= debt;
        totalDebt -= debt;
        assetCollateral[asset] -= collateral;

        uint256 lpLoss = _settleShortfall(borrower, asset, debt, collateralValue);
        _distributeToProviders(asset, collateral, lpLoss);

        emit Liquidated(borrower, asset, msg.sender, debt, collateral);
    }


    /// @dev Hands a liquidation's proceeds and its shortfall to the providers, in the one place
    ///      both paths go through.
    ///
    ///      The arithmetic here is the whole of the product-sum accounting and it is precision
    ///      critical: `sumS` records what each deposit is owed of the collateral, `productP`
    ///      records what is left of each deposit, and the scale rolls over when `productP` would
    ///      otherwise round to nothing. Written twice it could drift apart in one path and not the
    ///      other, and a divergence there would be silent, so it is written once.
    ///
    ///      The pool is too small only when providers would carry every last unit of their
    ///      deposits: the accounting cannot represent a pool emptied to zero, because P would reach
    ///      zero and every later deposit would compound to nothing. The requirement is on what
    ///      providers actually carry, the shortfall less whatever the reserve paid, not on the
    ///      debt, so a shortfall the reserve covers is not refused where a lone borrower's debt
    ///      equals the deposits. Deposits never fall below the debt outstanding, so that boundary
    ///      is the only place this can bind, and one more unit of deposits clears it.
    function _distributeToProviders(address asset, uint256 gain, uint256 lpLoss) internal {
        require(totalDeposits > lpLoss, "pool too small");

        if (gain > 0) {
            sumS[currentScale][asset] += (gain * productP) / totalDeposits;
        }
        uint256 newP = (productP * (totalDeposits - lpLoss)) / totalDeposits;
        while (newP < P_MIN) {
            currentScale += 1;
            newP *= SCALE_FACTOR;
        }
        productP = newP;
        totalDeposits -= lpLoss;
    }

    /// @dev Places the gap between debt cancelled and value received. The reserve takes it first;
    ///      whatever the reserve cannot cover is socialised across providers, and recorded rather
    ///      than absorbed silently. Returns what the providers actually lose, which is the number
    ///      the product-sum accounting is then advanced by.
    function _settleShortfall(address borrower, address asset, uint256 offset, uint256 received)
        internal
        returns (uint256 lpLoss)
    {
        if (received >= offset) return offset;

        uint256 shortfall = offset - received;
        uint256 fromReserve = shortfall > reserve ? reserve : shortfall;
        uint256 socialised = shortfall - fromReserve;

        reserve -= fromReserve;
        badDebt += socialised;
        emit BadDebtRealised(borrower, asset, shortfall, fromReserve, socialised);

        // Providers carry the offset less whatever the reserve just paid on their behalf. Total
        // claims fall by exactly `offset` either way, so the pool's books stay balanced.
        return offset - fromReserve;
    }

    /// @notice Whether a position may be liquidated right now.
    /// @dev    Answers false for any price the pool would not act on, so a stale or out-of-band
    ///         price reads as "not liquidatable" rather than reverting. A keeper deciding what to
    ///         do next needs an answer rather than an exception, and refusing to act on a price
    ///         nobody trusts is the safe direction.
    function isLiquidatable(address borrower, address asset) public view returns (bool) {
        Position storage position = positions[borrower][asset];
        if (position.debt == 0) return false;
        (PriceStatus status, uint256 price1e18,) = priceStatus(asset);
        if (status != PriceStatus.Ok) return false;
        uint256 value = (position.collateral * price1e18) / 1e30;
        return (value * assetConfig[asset].liqThresholdBps) / BPS < position.debt;
    }

    /// @notice Closes an unhealthy position, cancelling its debt against the pool and handing the
    ///         collateral to the providers.
    /// @param debtAmount how much of the debt to settle; more than is owed settles all of it
    /// @dev    Anyone may call this, and the caller takes a small cut of the seized collateral for
    ///         doing so, because the pool cannot depend on a single keeper being awake. The rest
    ///         goes to the providers, and the protocol itself takes nothing: there is no revenue
    ///         here, which is the point. A shortfall, where the collateral is worth less than the
    ///         debt, is met by the reserve first and only then by the providers.
    function liquidate(address borrower, address asset, uint256 debtAmount) external nonReentrant {
        require(!isPaused(PAUSE_LIQUIDATIONS), "liquidations paused");
        // Reverts with the reason the price is unusable, rather than the misleading "healthy".
        uint256 price1e18 = _requireUsablePrice(asset);
        require(isLiquidatable(borrower, asset), "healthy");
        Position storage position = positions[borrower][asset];
        uint256 offset = debtAmount >= position.debt ? position.debt : debtAmount;
        // A partial liquidation that would leave dust takes the whole position instead. Otherwise
        // the remainder sits there worth less than the gas to clear it, which is exactly the
        // unliquidatable position the minimum is there to prevent.
        if (position.debt - offset < minPositionDebt) offset = position.debt;
        require(offset > 0, "zero");
        uint256 seized = (position.collateral * offset) / position.debt;
        // The principal inside the debt this settles leaves with it, without a fee: a liquidation is
        // not the borrower paying back. Principal never exceeds debt, so this can never retire more
        // fee base than the debt it settles. The ratio used to be lifetime draws over current debt,
        // which any repayment made unbounded (#33).
        uint256 principalRetired = (position.principal * offset) / position.debt;
        uint256 incentive = (seized * liquidationIncentiveBps) / BPS;
        uint256 poolShare = seized - incentive;
        position.debt -= offset;
        position.collateral -= seized;
        position.principal -= principalRetired;
        assetDebt[asset] -= offset;
        totalDebt -= offset;
        assetCollateral[asset] -= seized;

        // What the pool actually receives for the debt it cancels. When a price gaps through the
        // threshold this is worth less than the debt, and the difference is a real loss that has to
        // land somewhere named rather than quietly diluting every provider.
        uint256 received = (poolShare * price1e18) / 1e30;
        uint256 lpLoss = _settleShortfall(borrower, asset, offset, received);
        // Checked inside, after the settlement: a refusal reverts the settlement with everything else.
        _distributeToProviders(asset, poolShare, lpLoss);
        if (incentive > 0) {
            require(IERC20(asset).transfer(msg.sender, incentive), "transfer failed");
        }
        emit Liquidated(borrower, asset, msg.sender, offset, seized);
    }
}
