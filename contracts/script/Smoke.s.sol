// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafixPool} from "../src/SafixPool.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Drives the full borrower lifecycle against a live deployment with real transactions:
///         deposit, lock, draw, repay, close, liquidate.
///
/// The borrower is a wallet other than the deployer, which is what the launch checklist asks for.
/// Every threshold is read back from the pool rather than assumed, so the script follows whatever
/// configuration the chain actually holds.
///
/// Required environment:
///   PRIVATE_KEY        deployer / pool owner, funds the borrower and moves the price
///   TESTER_PRIVATE_KEY the borrower, must be a different key
///   POOL               SafixPool address
///   USDG               pool denomination token address
///   ASSET              collateral asset address, already configured on the pool
///   DEPOSIT_AMOUNT     borrower's liquidity deposit, in stable units
///   COLLATERAL_AMOUNT  collateral locked per position, in asset units
///   DRAW_AMOUNT        drawn per position, in stable units
///   REPAY_AMOUNT       partial repayment before the position is closed, in stable units
contract Smoke is Script {
    uint256 private constant BPS = 10_000;

    struct Plan {
        uint256 deployerKey;
        uint256 testerKey;
        address deployer;
        address tester;
        uint256 depositAmount;
        uint256 collateralAmount;
        uint256 drawAmount;
        uint256 repayAmount;
        uint256 borrowerFunding;
        uint16 liqThresholdBps;
        uint256 startingPrice;
    }

    SafixPool private pool;
    IERC20 private stable;
    IERC20 private asset;
    address private assetAddress;

    function run() external {
        Plan memory plan = _plan();
        _fundBorrower(plan);
        _borrowerLifecycle(plan);
        _liquidate(plan);
    }

    /// @dev Reads the environment and the pool's own configuration, and checks the requested amounts
    ///      against the capacity the chain reports before a single transaction is sent.
    function _plan() private returns (Plan memory plan) {
        plan.deployerKey = vm.envUint("PRIVATE_KEY");
        plan.testerKey = vm.envUint("TESTER_PRIVATE_KEY");
        plan.deployer = vm.addr(plan.deployerKey);
        plan.tester = vm.addr(plan.testerKey);
        require(plan.deployer != plan.tester, "tester must differ from deployer");

        pool = SafixPool(vm.envAddress("POOL"));
        stable = IERC20(vm.envAddress("USDG"));
        assetAddress = vm.envAddress("ASSET");
        asset = IERC20(assetAddress);

        plan.depositAmount = vm.envUint("DEPOSIT_AMOUNT");
        plan.collateralAmount = vm.envUint("COLLATERAL_AMOUNT");
        plan.drawAmount = vm.envUint("DRAW_AMOUNT");
        plan.repayAmount = vm.envUint("REPAY_AMOUNT");

        uint16 maxLtvBps;
        bool enabled;
        (enabled, maxLtvBps, plan.liqThresholdBps,) = pool.assetConfig(assetAddress);
        require(enabled, "asset not configured on pool");

        (plan.startingPrice,) = pool.currentPrice(assetAddress);
        uint256 originationFeeBps = pool.originationFeeBps();
        uint256 collateralValue = pool.collateralValueStable(assetAddress, plan.collateralAmount);
        uint256 maxDraw = (((collateralValue * maxLtvBps) / BPS) * BPS) / (BPS + originationFeeBps);
        require(plan.drawAmount > 0 && plan.drawAmount <= maxDraw, "DRAW_AMOUNT exceeds LTV capacity");

        uint256 originationFee = (plan.drawAmount * originationFeeBps) / BPS;
        require(
            plan.repayAmount > 0 && plan.repayAmount < plan.drawAmount + originationFee,
            "REPAY_AMOUNT must be a partial repayment"
        );

        // The borrower pays the deposit and both fees out of pocket; the drawn amount funds the rest.
        uint256 redemptionFee = (plan.drawAmount * pool.redemptionFeeBps()) / BPS;
        plan.borrowerFunding = plan.depositAmount + originationFee + redemptionFee;

        console.log("--- configuration read from chain ---");
        console.log("pool", address(pool));
        console.log("asset", assetAddress);
        console.log("deployer", plan.deployer);
        console.log("borrower", plan.tester);
        console.log("maxLtvBps", maxLtvBps);
        console.log("liqThresholdBps", plan.liqThresholdBps);
        console.log("originationFeeBps", originationFeeBps);
        console.log("redemptionFeeBps", pool.redemptionFeeBps());
        console.log("startingPrice1e18", plan.startingPrice);
        console.log("collateralValueStable", collateralValue);
        console.log("maxDrawForCollateral", maxDraw);
    }

    /// @dev Step 1. The deployer hands the borrower the stable and collateral it needs. Plain ERC-20
    ///      transfers, so this works unchanged once real tokenized assets replace the test ones.
    function _fundBorrower(Plan memory plan) private {
        vm.startBroadcast(plan.deployerKey);
        require(stable.transfer(plan.tester, plan.borrowerFunding), "stable funding failed");
        require(asset.transfer(plan.tester, plan.collateralAmount), "collateral funding failed");
        vm.stopBroadcast();

        console.log("--- borrower funded ---");
        console.log("stableSent", plan.borrowerFunding);
        console.log("collateralSent", plan.collateralAmount);
    }

    /// @dev Steps 2 to 6. deposit, lock, draw, repay, close, then a second position left open for
    ///      the liquidation step.
    function _borrowerLifecycle(Plan memory plan) private {
        vm.startBroadcast(plan.testerKey);
        require(stable.approve(address(pool), type(uint256).max), "stable approve failed");
        require(asset.approve(address(pool), type(uint256).max), "collateral approve failed");

        pool.deposit(plan.depositAmount);
        pool.lockCollateral(assetAddress, plan.collateralAmount);
        pool.draw(assetAddress, plan.drawAmount);
        pool.repay(assetAddress, plan.repayAmount);
        pool.closePosition(assetAddress);

        // Reopen so there is a live position for the liquidation leg.
        pool.lockCollateral(assetAddress, plan.collateralAmount);
        pool.draw(assetAddress, plan.drawAmount);
        vm.stopBroadcast();

        (uint256 collateral, uint256 debt, uint256 totalDrawn) = pool.positions(plan.tester, assetAddress);
        console.log("--- lifecycle complete, position reopened ---");
        console.log("borrowerCompoundedDeposit", pool.compoundedDepositOf(plan.tester));
        console.log("positionCollateral", collateral);
        console.log("positionDebt", debt);
        console.log("positionTotalDrawn", totalDrawn);
        console.log("poolProtocolFees", pool.protocolFees());
    }

    /// @dev Step 7. Move the price just past the asset's own liquidation threshold, liquidate, then
    ///      put the price back. The crash price is solved from the threshold rather than picked.
    function _liquidate(Plan memory plan) private {
        (, uint256 debt,) = pool.positions(plan.tester, assetAddress);
        require(debt > 0, "no debt to liquidate");
        require(pool.totalDeposits() > debt, "pool too small to absorb the offset");

        // isLiquidatable holds when collateralValue * liqThresholdBps / BPS < debt, and
        // collateralValue is collateral * price / 1e30. Solve for the price that puts the
        // position exactly at the threshold, then step just under it.
        uint256 thresholdPrice =
            (debt * BPS * 1e30) / (uint256(plan.liqThresholdBps) * plan.collateralAmount);
        uint256 crashPrice = (thresholdPrice * 99) / 100;
        require(crashPrice > 0, "crash price underflowed");

        vm.startBroadcast(plan.deployerKey);
        pool.setPrice(assetAddress, crashPrice);
        require(pool.isLiquidatable(plan.tester, assetAddress), "position did not become liquidatable");
        pool.liquidate(plan.tester, assetAddress, type(uint256).max);
        pool.setPrice(assetAddress, plan.startingPrice);
        vm.stopBroadcast();

        (uint256 collateralAfter, uint256 debtAfter,) = pool.positions(plan.tester, assetAddress);
        console.log("--- liquidated ---");
        console.log("thresholdPrice1e18", thresholdPrice);
        console.log("crashPrice1e18", crashPrice);
        console.log("priceRestoredTo1e18", plan.startingPrice);
        console.log("positionCollateralAfter", collateralAfter);
        console.log("positionDebtAfter", debtAfter);
        console.log("poolTotalDeposits", pool.totalDeposits());
        console.log("poolAvailableLiquidity", pool.availableLiquidity());
    }
}
