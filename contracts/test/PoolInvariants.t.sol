// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract PoolHandler is CommonBase, StdCheats, StdUtils {
    SafixPool public immutable pool;
    MockERC20 public immutable usdc;
    MockERC20 public immutable tbill;

    address[3] public lps;
    address[3] public borrowers;

    uint256 private constant BASE_PRICE = 100e18;

    constructor(SafixPool pool_, MockERC20 usdc_, MockERC20 tbill_) {
        pool = pool_;
        usdc = usdc_;
        tbill = tbill_;
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
    }

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

    function lockAndDraw(uint256 actorSeed, uint256 collateralAmount, uint256 drawAmount) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        collateralAmount = bound(collateralAmount, 1e18, 500e18);
        tbill.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        pool.lockCollateral(address(tbill), collateralAmount);

        (uint256 collateral, uint256 debt,) = pool.positions(borrower, address(tbill));
        uint256 value = pool.collateralValueUsdc(address(tbill), collateral);
        uint256 capacity = (value * 8000) / 10_000;
        uint256 headroom = capacity > debt ? capacity - debt : 0;
        uint256 maxDraw = (headroom * 10_000) / (10_000 + pool.originationFeeBps());
        uint256 available = pool.availableLiquidity();
        if (maxDraw > available) maxDraw = available;
        if (maxDraw >= 1e6) {
            pool.draw(address(tbill), bound(drawAmount, 1e6, maxDraw));
        }
        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        (, uint256 debt,) = pool.positions(borrower, address(tbill));
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        uint256 balance = usdc.balanceOf(borrower);
        if (balance < amount) usdc.mint(borrower, amount - balance);
        vm.prank(borrower);
        pool.repay(address(tbill), amount);
    }

    function closePosition(uint256 actorSeed) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        (uint256 collateral, uint256 debt, uint256 totalDrawn) = pool.positions(borrower, address(tbill));
        if (collateral == 0 && debt == 0) return;
        uint256 owed = debt + (totalDrawn * pool.redemptionFeeBps()) / 10_000;
        uint256 balance = usdc.balanceOf(borrower);
        if (balance < owed) usdc.mint(borrower, owed - balance);
        vm.prank(borrower);
        pool.closePosition(address(tbill));
    }

    function movePrice(uint256 pct) external {
        pct = bound(pct, 40, 160);
        pool.setPrice(address(tbill), (BASE_PRICE * pct) / 100);
    }

    function liquidate(uint256 actorSeed, uint256 portion) external {
        address borrower = borrowers[bound(actorSeed, 0, 2)];
        if (!pool.isLiquidatable(borrower, address(tbill))) return;
        (, uint256 debt,) = pool.positions(borrower, address(tbill));
        uint256 total = pool.totalDeposits();
        if (total <= 1 || debt == 0) return;
        uint256 cap = debt < total - 1 ? debt : total - 1;
        portion = bound(portion, 1, cap);
        pool.liquidate(borrower, address(tbill), portion);
    }

    function claim(uint256 actorSeed) external {
        address lp = lps[bound(actorSeed, 0, 2)];
        address[] memory assets = new address[](1);
        assets[0] = address(tbill);
        vm.prank(lp);
        pool.claimGains(assets);
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

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 6);
        tbill = new MockERC20("Tokenized treasury 3M", "tBILL", 18);
        pool = new SafixPool(address(usdc));
        pool.configureAsset(address(tbill), 8000, 9000, 100e18);
        handler = new PoolHandler(pool, usdc, tbill);
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

    function invariant_usdcConservation() public view {
        assertEq(
            usdc.balanceOf(address(pool)) + _sumDebt(),
            pool.totalDeposits() + pool.protocolFees()
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

    function invariant_productStaysInBand() public view {
        assertGe(pool.productP(), 1e18);
        assertLe(pool.productP(), 1e27);
    }
}
