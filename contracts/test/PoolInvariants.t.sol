// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @dev Drives every state-changing path on the pool that moves stable or collateral, including the
///      reserve, the dust write-off, collateral withdrawal and fee collection. An invariant suite that
///      never calls the newest code is the one place where green is misleading, so each action is
///      bounded by the pool's own arithmetic rather than skipped: the suite runs with
///      `fail_on_revert`, and a guard that returned early too often would hide a path as surely as
///      leaving it out.
contract PoolHandler is CommonBase, StdCheats, StdUtils {
    SafixPool public immutable pool;
    MockERC20 public immutable usdc;
    MockERC20 public immutable tbill;
    /// @dev The pool's owner. With no timelock wired, the owner is also who `onlyTimelock` admits,
    ///      which is how a fresh deployment is configured; the delay itself is tested elsewhere.
    address public immutable owner;

    address[3] public lps;
    address[3] public borrowers;
    address public immutable sponsor;
    address public immutable treasury;

    /// @dev How often each path actually executed, as opposed to being called and returning early.
    uint256 public reserveFunded;
    uint256 public reserveWithdrawn;
    uint256 public feesCollected;
    uint256 public collateralWithdrawn;
    uint256 public absorbed;

    uint256 private constant BASE_PRICE = 100e18;
    uint256 private constant MAX_LTV_BPS = 8000;

    constructor(SafixPool pool_, MockERC20 usdc_, MockERC20 tbill_, address owner_) {
        pool = pool_;
        usdc = usdc_;
        tbill = tbill_;
        owner = owner_;
        sponsor = vm.addr(0x3000);
        treasury = vm.addr(0x4000);
        for (uint256 i = 0; i < 3; i++) {
            lps[i] = vm.addr(0x1000 + i);
            borrowers[i] = vm.addr(0x2000 + i);
            vm.prank(lps[i]);
            usdc.approve(address(pool), type(uint256).max);
            vm.startPrank(borrowers[i]);
            usdc.approve(address(pool), type(uint256).max);
            tbill.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(sponsor);
        usdc.approve(address(pool), type(uint256).max);
    }

    // --------------------------------------------------------------------------------------
    // liquidity
    // --------------------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 amount) external {
        address lp = lps[bound(actorSeed, 0, 2)];
        amount = bound(amount, 1e6, 500_000e6);
        usdc.mint(lp, amount);
        vm.prank(lp);
        pool.deposit(amount);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address lp = lps[bound(actorSeed, 0, 2)];
        uint256 compounded = pool.compoundedDepositOf(lp);
        uint256 cap = compounded < pool.availableLiquidity() ? compounded : pool.availableLiquidity();
        if (cap == 0) return;
        amount = bound(amount, 1, cap);
        vm.prank(lp);
        pool.withdraw(amount);
    }

    function claim(uint256 actorSeed) external {
        address lp = lps[bound(actorSeed, 0, 2)];
        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(lp);
        pool.claimGains(assets);
    }

    // --------------------------------------------------------------------------------------
    // borrowing
    // --------------------------------------------------------------------------------------

    function lockAndDraw(uint256 actorSeed, uint256 collateralAmount, uint256 drawAmount) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        collateralAmount = bound(collateralAmount, 1e18, 500e18);
        tbill.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), collateralAmount);

        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        uint256 feeBps = pool.originationFeeBps();
        uint256 value = pool.collateralValueStable(address(tbill), collateral);
        uint256 capacity = (value * MAX_LTV_BPS) / 10_000;
        uint256 headroom = capacity > debt ? capacity - debt : 0;
        uint256 maxDraw = (headroom * 10_000) / (10_000 + feeBps);
        // Liquidity bounds the debt a draw creates, fee included, not the amount handed over.
        uint256 byLiquidity = (pool.drawableLiquidity() * 10_000) / (10_000 + feeBps);
        if (maxDraw > byLiquidity) maxDraw = byLiquidity;
        // A draw that would leave the position under the floor is refused, so the smallest draw is
        // the one that lifts it onto the floor. The extra unit covers the fee's rounding down.
        uint256 floor = pool.minPositionDebt();
        uint256 minDraw = debt >= floor ? 1e6 : ((floor - debt) * 10_000) / (10_000 + feeBps) + 1;
        if (minDraw < 1e6) minDraw = 1e6;
        if (maxDraw >= minDraw) {
            pool.draw(address(tbill), bound(drawAmount, minDraw, maxDraw));
        }
        vm.stopPrank();
    }

    /// @dev Holds the whole debt and the redemption fee on the whole principal before repaying, so
    ///      a partial that would leave dust takes the escalation path rather than the refusal: both
    ///      are the pool's to decide, and the escalation is the one that moves money.
    function repay(uint256 actorSeed, uint256 amount) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        (, uint256 debt, uint256 principal) = pool.positions(borrower, address(tbill));
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        uint256 owed = debt + (principal * pool.redemptionFeeBps()) / 10_000;
        uint256 balance = usdc.balanceOf(borrower);
        if (balance < owed) usdc.mint(borrower, owed - balance);
        vm.prank(borrower);
        pool.repay(address(tbill), amount);
    }

    /// @dev Withdraws only what the pool would release: everything when nothing was ever drawn,
    ///      otherwise all but what keeps the position alive and the loan inside its LTV.
    function withdrawCollateral(uint256 actorSeed, uint256 amount) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        (uint256 collateral, uint256 debt, uint256 principal) = pool.positions(borrower, address(tbill));
        if (collateral == 0) return;
        uint256 keep = (debt > 0 || principal > 0) ? 1 : 0;
        if (debt > 0) {
            (uint256 price,) = pool.currentPrice(address(tbill));
            // Rounded up twice, against the pool's two roundings down.
            uint256 neededValue = (debt * 10_000 + MAX_LTV_BPS - 1) / MAX_LTV_BPS;
            uint256 needed = (neededValue * 1e30 + price - 1) / price;
            if (needed > keep) keep = needed;
        }
        if (keep >= collateral) return;
        amount = bound(amount, 1, collateral - keep);
        vm.prank(borrower);
        pool.withdrawCollateral(address(tbill), amount);
        collateralWithdrawn += 1;
    }

    function closePosition(uint256 actorSeed) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        (uint256 collateral, uint256 debt, uint256 principal) = pool.positions(borrower, address(tbill));
        if (collateral == 0 && debt == 0) return;
        uint256 owed = debt + (principal * pool.redemptionFeeBps()) / 10_000;
        uint256 balance = usdc.balanceOf(borrower);
        if (balance < owed) usdc.mint(borrower, owed - balance);
        vm.prank(borrower);
        pool.closePosition(address(tbill));
    }

    function movePrice(uint256 pct) external {
        pct = bound(pct, 40, 160);
        pool.setPrice(address(tbill), (BASE_PRICE * pct) / 100);
    }

    // --------------------------------------------------------------------------------------
    // losses
    // --------------------------------------------------------------------------------------

    /// @dev Mirrors the pool: a partial that would leave dust takes the whole position, and the
    ///      only liquidation refused is one whose loss to providers would take their deposits to
    ///      zero, which the product-sum accounting cannot represent.
    function liquidate(uint256 actorSeed, uint256 portion) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        if (!pool.isLiquidatable(borrower, address(tbill))) return;
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        portion = bound(portion, 1, debt);
        uint256 offset = debt - portion < pool.minPositionDebt() ? debt : portion;
        uint256 seized = (collateral * offset) / debt;
        uint256 incentive = (seized * pool.liquidationIncentiveBps()) / 10_000;
        (uint256 price,) = pool.currentPrice(address(tbill));
        uint256 received = ((seized - incentive) * price) / 1e30;
        if (pool.totalDeposits() <= _providerLoss(offset, received)) return;
        pool.liquidate(borrower, address(tbill), portion);
    }

    /// @dev The dust write-off, for a position liquidatable and worth less than the floor.
    function absorbBadDebt(uint256 actorSeed) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        if (!pool.isLiquidatable(borrower, address(tbill))) return;
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        (uint256 price,) = pool.currentPrice(address(tbill));
        uint256 value = (collateral * price) / 1e30;
        // Anything worth liquidating goes through liquidate, and the pool refuses it here.
        if (value >= pool.minPositionDebt()) return;
        if (pool.totalDeposits() <= _providerLoss(debt, value)) return;
        vm.prank(owner);
        pool.absorbBadDebt(borrower, address(tbill));
        absorbed += 1;
    }

    /// @dev What providers carry when `offset` of debt is cancelled for `received` of value: the
    ///      whole offset, less whatever the reserve pays towards a shortfall.
    function _providerLoss(uint256 offset, uint256 received) internal view returns (uint256) {
        if (received >= offset) return offset;
        uint256 shortfall = offset - received;
        uint256 reserve = pool.reserve();
        return offset - (shortfall > reserve ? reserve : shortfall);
    }

    // --------------------------------------------------------------------------------------
    // the reserve and the fees
    // --------------------------------------------------------------------------------------

    function fundReserve(uint256 amount) external {
        amount = bound(amount, 1, 50_000e6);
        usdc.mint(sponsor, amount);
        vm.prank(sponsor);
        pool.fundReserve(amount);
        reserveFunded += 1;
    }

    function withdrawReserve(uint256 amount) external {
        uint256 reserve = pool.reserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        vm.prank(owner);
        pool.withdrawReserve(treasury, amount);
        reserveWithdrawn += 1;
    }

    function collectProtocolFees() external {
        vm.prank(owner);
        pool.collectProtocolFees(treasury);
        feesCollected += 1;
    }

    function lpAt(uint256 index) external view returns (address) {
        return lps[index];
    }

    function borrowerAt(uint256 index) external view returns (address) {
        return borrowers[index];
    }
}

contract PoolInvariantsTest is Test {
    SafixPool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal tbill;
    PoolHandler internal handler;

    /// @dev A position floor, so the dust write-off has a definition of dust to act on and is
    ///      reachable at all, and so the floor's own paths — the draw minimum, the repayment that
    ///      escalates, the liquidation that takes the whole position — are in every sequence.
    uint256 internal constant FLOOR = 500e6;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        // Route a quarter of every origination fee to the reserve so the randomised sequences
        // exercise funding it, spending it on a shortfall, and running it dry.
        pool.setReserveFeeShare(2_500);
        pool.setRiskLimits(0, FLOOR, 0);
        handler = new PoolHandler(pool, usdc, tbill, address(this));
        pool.setPriceUpdater(address(handler));
        targetContract(address(handler));
    }

    function _sumDebt() internal view returns (uint256 total) {
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 debt,) = pool.positions(handler.borrowerAt(i), address(tbill));
            total += debt;
        }
    }

    function _sumCollateral() internal view returns (uint256 total) {
        for (uint256 i = 0; i < 3; i++) {
            (uint256 collateral,,) = pool.positions(handler.borrowerAt(i), address(tbill));
            total += collateral;
        }
    }

    /// @dev Every unit of stable in the pool is claimed by exactly one of: the providers, the fee
    ///      treasury, or the reserve. Bad debt moves a claim between them and never destroys one.
    function invariant_usdcConservation() public view {
        assertEq(
            usdc.balanceOf(address(pool)) + _sumDebt(),
            pool.totalDeposits() + pool.protocolFees() + pool.reserve()
        );
    }

    function invariant_compoundedMatchesTotal() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; i++) {
            sum += pool.compoundedDepositOf(handler.lpAt(i));
        }
        assertApproxEqAbs(sum, pool.totalDeposits(), 1e4);
    }

    function invariant_collateralCoversClaims() public view {
        uint256 gains = 0;
        for (uint256 i = 0; i < 3; i++) {
            gains += pool.gainOf(handler.lpAt(i), address(tbill));
        }
        assertGe(tbill.balanceOf(address(pool)) + 2, _sumCollateral() + gains);
    }

    /// @dev The caps are only as good as the accumulators they read, so those have to match the
    ///      positions they summarise on every reachable state.
    function invariant_accumulatorsMatchPositions() public view {
        assertEq(pool.assetDebt(address(tbill)), _sumDebt(), "assetDebt drifted from the positions");
        assertEq(pool.totalDebt(), _sumDebt(), "totalDebt drifted from the positions");
        assertEq(
            pool.assetCollateral(address(tbill)), _sumCollateral(), "assetCollateral drifted from the positions"
        );
    }

    function invariant_productStaysInBand() public view {
        assertGe(pool.productP(), 1e18);
        assertLe(pool.productP(), 1e27);
    }

    /// @dev What belongs to neither providers nor borrowers — protocol fees and the reserve — is
    ///      always backed by stable the pool actually holds; by conservation, provider deposits
    ///      never fall below the debt outstanding. So collecting fees or withdrawing the reserve
    ///      can never pay out a provider's money, and the only place a liquidation can meet the
    ///      "pool too small" refusal is the boundary where deposits equal the debt exactly.
    function invariant_committedClaimsAreBacked() public view {
        assertGe(usdc.balanceOf(address(pool)), pool.protocolFees() + pool.reserve(), "fees or reserve unbacked");
        assertGe(pool.totalDeposits(), _sumDebt(), "deposits fell below the debt");
    }

    /// @dev The redemption fee's base is outstanding principal, and principal never exceeds the debt
    ///      it is part of. So a liquidation, which retires principal in proportion to the debt it
    ///      settles, can never retire more fee base than debt — the failure in #33, which this suite
    ///      could not see while the base was lifetime draws and a repayment left it behind.
    function invariant_principalNeverExceedsDebt() public view {
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 debt, uint256 principal) = pool.positions(handler.borrowerAt(i), address(tbill));
            assertLe(principal, debt, "principal exceeded the debt it is part of");
        }
    }

    /// @dev The fuzzer only proves something about the paths it actually executes. This drives one
    ///      short sequence through the handler and requires every path the reserve work added to
    ///      run to completion, so a guard that quietly made one unreachable fails here rather than
    ///      leaving the suite green over code it never touched.
    function testTheHandlerReachesEveryPathItDrives() public {
        handler.deposit(0, 100_000e6);
        // A small position, drawn just onto the floor, that a fall to 40% makes dust.
        handler.lockAndDraw(0, 8e18, 0);
        // A large one with room to release collateral against its loan.
        handler.lockAndDraw(1, 500e18, 0);

        handler.fundReserve(1_000e6);
        handler.withdrawReserve(100e6);
        handler.collectProtocolFees();
        handler.withdrawCollateral(1, 1);

        handler.movePrice(40);
        handler.absorbBadDebt(0);

        assertEq(handler.reserveFunded(), 1, "fundReserve never ran");
        assertEq(handler.reserveWithdrawn(), 1, "withdrawReserve never ran");
        assertEq(handler.feesCollected(), 1, "collectProtocolFees never ran");
        assertEq(handler.collateralWithdrawn(), 1, "withdrawCollateral never ran");
        assertEq(handler.absorbed(), 1, "absorbBadDebt never ran");

        invariant_usdcConservation();
        invariant_accumulatorsMatchPositions();
        invariant_committedClaimsAreBacked();
    }
}
