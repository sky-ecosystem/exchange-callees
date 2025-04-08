// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.21;

import "lib/lockstake/lib/token-tests/lib/dss-test/src/DssTest.sol";
import "dss-interfaces/Interfaces.sol";

import { LockstakeDeploy } from "lib/lockstake/deploy/LockstakeDeploy.sol";
import { LockstakeInit, LockstakeConfig, LockstakeInstance } from "lib/lockstake/deploy/LockstakeInit.sol";
import { LockstakeSky } from "lib/lockstake/src/LockstakeSky.sol";
import { LockstakeEngine } from "lib/lockstake/src/LockstakeEngine.sol";
import { LockstakeClipper } from "lib/lockstake/src/LockstakeClipper.sol";
import { LockstakeUrn } from "lib/lockstake/src/LockstakeUrn.sol";
import { LockstakeMigrator } from "lib/lockstake/src/LockstakeMigrator.sol";
import { VoteDelegateFactoryMock, VoteDelegateMock } from "lib/lockstake/test/mocks/VoteDelegateMock.sol";
import { GemMock } from "lib/lockstake/test/mocks/GemMock.sol";
import { UsdsMock } from "lib/lockstake/test/mocks/UsdsMock.sol";
import { UsdsJoinMock } from "lib/lockstake/test/mocks/UsdsJoinMock.sol";
import { StakingRewardsMock } from "lib/lockstake/test/mocks/StakingRewardsMock.sol";
import { UniswapV2LockstakeCallee, TokenLike } from "src/UniswapV2LockstakeCallee.sol";

interface UsdsLike {
    function allowance(address, address) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

contract MockUniswapRouter02 is DssTest {
    uint256 fixedPrice;

    constructor(uint256 price_) {
        fixedPrice = price_;
    }

    // Hardcoded to simulate fixed price Uniswap
    /* uniRouter02.swapExactTokensForTokens(gemAmt, daiToJoin + minProfit, path, address(this), block.timestamp); */
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts) {
        deadline; // silence warning
        uint buyAmt = amountIn * fixedPrice;
        require(amountOutMin <= buyAmt, "Minimum Fill not reached");

        uint256 initialInBalance = DSTokenAbstract(path[0]).balanceOf(address(this));
        DSTokenAbstract(path[0]).transferFrom(msg.sender, address(this), amountIn);
        assertEq(DSTokenAbstract(path[0]).balanceOf(address(this)), initialInBalance + amountIn);

        uint256 initialOutBalance = DSTokenAbstract(path[path.length - 1]).balanceOf(to);
        GodMode.setBalance(path[path.length - 1], to, initialOutBalance + buyAmt);
        assertEq(DSTokenAbstract(path[path.length - 1]).balanceOf(to), initialOutBalance + buyAmt);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = buyAmt;
    }

}

contract UniswapV2LockstakeCalleeTest is DssTest {
    using stdStorage for StdStorage;

    DssInstance             dss;
    address                 oldLsmkr;
    address                 oldEngine;
    address                 oldClip;
    address                 oldCalc;
    address                 pauseProxy;
    DSTokenAbstract         sky;
    LockstakeSky            lssky;
    LockstakeEngine         engine;
    LockstakeClipper        clip;
    address                 calc;
    LockstakeMigrator       migrator;
    OsmAbstract             pip;
    VoteDelegateFactoryMock voteDelegateFactory;
    UsdsLike                usds;
    address                 usdsJoin;
    GemMock                 rTok;
    StakingRewardsMock      farm;
    StakingRewardsMock      farm2;
    bytes32                 ilk = "LSEV2-A";
    address                 voter;
    address                 voteDelegate;
    LockstakeConfig         cfg;
    uint256                 prevLine;
    address constant        LOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    // Callee-specific variables
    DSTokenAbstract          dai;
    address                  daiJoin;
    MockUniswapRouter02      uniRouter02;
    uint256                  uniV2Price = 1;
    address[]                uniV2Path = new address[](2);
    UniswapV2LockstakeCallee callee;

    event OnKick(address indexed urn, uint256 wad);

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L96-L181
    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        dss = MCD.loadFromChainlog(LOG);

        oldLsmkr = dss.chainlog.getAddress("LOCKSTAKE_MKR");
        oldEngine = dss.chainlog.getAddress("LOCKSTAKE_ENGINE");
        oldClip = dss.chainlog.getAddress("LOCKSTAKE_CLIP");
        oldCalc = dss.chainlog.getAddress("LOCKSTAKE_CLIP_CALC");

        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        pip = OsmAbstract(dss.chainlog.getAddress("PIP_MKR"));
        sky = DSTokenAbstract(dss.chainlog.getAddress("SKY"));
        usds = UsdsLike(dss.chainlog.getAddress("USDS"));
        usdsJoin = dss.chainlog.getAddress("USDS_JOIN");
        rTok = new GemMock(0);

        voteDelegateFactory = new VoteDelegateFactoryMock(address(sky));
        voter = address(123);
        vm.prank(voter); voteDelegate = voteDelegateFactory.create();

        vm.prank(pauseProxy); pip.kiss(address(this));
        _setMedianPrice(1_500 * 10**18);

        LockstakeInstance memory instance = LockstakeDeploy.deployLockstake(
            address(this),
            pauseProxy,
            address(voteDelegateFactory),
            ilk,
            15 * WAD / 100,
            bytes4(abi.encodeWithSignature("newLinearDecrease(address)")),
            dss.chainlog.getAddress("MKR_SKY")
        );

        engine = LockstakeEngine(instance.engine);
        clip = LockstakeClipper(instance.clipper);
        calc = instance.clipperCalc;
        migrator = LockstakeMigrator(instance.migrator);
        lssky = LockstakeSky(instance.lssky);
        farm = new StakingRewardsMock(address(rTok), address(lssky));
        farm2 = new StakingRewardsMock(address(rTok), address(lssky));

        address[] memory farms = new address[](2);
        farms[0] = address(farm);
        farms[1] = address(farm2);

        cfg = LockstakeConfig({
            ilk: ilk,
            farms: farms,
            fee: 15 * WAD / 100,
            maxLine: 10_000_000 * 10**45,
            gap: 1_000_000 * 10**45,
            ttl: 1 days,
            dust: 50,
            duty: 100000001 * 10**27 / 100000000,
            mat: 3 * 10**27,
            buf: 1.25 * 10**27, // 25% Initial price buffer
            tail: 3600, // 1 hour before reset
            cusp: 0.2 * 10**27, // 80% drop before reset
            chip: 2 * WAD / 100,
            tip: 3,
            stopped: 0,
            chop: 1 ether,
            hole: 10_000 * 10**45,
            tau: 100,
            cut: 0,
            step: 0,
            lineMom: true,
            tolerance: 0.5 * 10**27,
            name: "LOCKSTAKE",
            symbol: "LSSKY"
        });

        prevLine = dss.vat.Line();

        vm.startPrank(pauseProxy);
        dss.chainlog.setAddress("VOTE_DELEGATE_FACTORY", address(voteDelegateFactory));
        dss.chainlog.setAddress("PIP_SKY", address(pip));
        LockstakeInit.initLockstake(dss, instance, cfg);
        vm.stopPrank();

        deal(address(sky), address(this), 100_000 * 10**18, true);

        // Add some existing DAI assigned to usdsJoin to avoid a particular error
        stdstore.target(address(dss.vat)).sig("dai(address)").with_key(address(usdsJoin)).depth(0).checked_write(100_000 * RAD);
    }

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L183-L185
    function _ink(bytes32 ilk_, address urn) internal view returns (uint256 ink) {
        (ink,) = dss.vat.urns(ilk_, urn);
    }

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L187-L189
    function _art(bytes32 ilk_, address urn) internal view returns (uint256 art) {
        (, art) = dss.vat.urns(ilk_, urn);
    }

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L922-L951
    function _urnSetUp(bool withDelegate, bool withStaking) internal returns (address urn) {
        urn = engine.open(0);
        if (withDelegate) {
            engine.selectVoteDelegate(address(this), 0, voteDelegate);
        }
        if (withStaking) {
            engine.selectFarm(address(this), 0, address(farm), 0);
        }
        sky.approve(address(engine), 100_000 * 10**18);
        engine.lock(address(this), 0, 100_000 * 10**18, 5);
        engine.draw(address(this), 0, address(this), 2_000 * 10**18);
        assertEq(_ink(ilk, urn), 100_000 * 10**18);
        assertEq(_art(ilk, urn), 2_000 * 10**18);

        if (withDelegate) {
            assertEq(engine.urnVoteDelegates(urn), voteDelegate);
            assertEq(sky.balanceOf(voteDelegate), 100_000 * 10**18);
            assertEq(sky.balanceOf(address(engine)), 0);
        } else {
            assertEq(engine.urnVoteDelegates(urn), address(0));
            assertEq(sky.balanceOf(address(engine)), 100_000 * 10**18);
        }
        if (withStaking) {
            assertEq(lssky.balanceOf(address(urn)), 0);
            assertEq(lssky.balanceOf(address(farm)), 100_000 * 10**18);
            assertEq(farm.balanceOf(address(urn)), 100_000 * 10**18);
        } else {
            assertEq(lssky.balanceOf(address(urn)), 100_000 * 10**18);
        }
    }

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L953-L965
    function _forceLiquidation(address urn) internal returns (uint256 id) {
        _setMedianPrice(0.05 * 10**18); // Force liquidation
        dss.spotter.poke(ilk);
        assertEq(clip.kicks(), 0);
        assertEq(engine.urnAuctions(urn), 0);
        (,, uint256 hole,) = dss.dog.ilks(ilk);
        uint256 kicked = hole < 2_000 * 10**45 ? 100_000 * 10**18 * hole / (2_000 * 10**45) : 100_000 * 10**18;
        vm.expectEmit(true, true, true, true);
        emit OnKick(urn, kicked);
        id = dss.dog.bark(ilk, address(urn), address(this));
        assertEq(clip.kicks(), 1);
        assertEq(engine.urnAuctions(urn), 1);
    }

    // Match https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L88-L94
    function _setMedianPrice(uint256 price) internal {
        vm.store(pip.src(), bytes32(uint256(1)), bytes32(price));
        vm.warp(block.timestamp + 1 hours);
        pip.poke();
        vm.warp(block.timestamp + 1 hours);
        pip.poke();
    }

    // Callee-specific setup function
    function setUpCallee() internal {
        // set up additional global variables
        dai = DSTokenAbstract(dss.chainlog.getAddress("MCD_DAI"));
        daiJoin = dss.chainlog.getAddress("MCD_JOIN_DAI");

        // Setup mock of the uniswap router
        uniRouter02 = new MockUniswapRouter02(uniV2Price);

        // Deploy callee contract
        callee = new UniswapV2LockstakeCallee(address(uniRouter02), daiJoin, address(usdsJoin), address(sky));
    }

    // Test is based on the `_testOnTake` https://github.com/makerdao/lockstake/blob/5c065eee4b048691c09a99cf5158b582eaf41ee8/test/LockstakeEngine.t.sol#L1064-L1162
    function _testCalleeTake(bool withDelegate, bool withStaking, address[] memory path, uint256 exchangeRate) internal {
        // Setup urn and force its liquidation
        address urn = _urnSetUp(withDelegate, withStaking);
        uint256 id = _forceLiquidation(urn);

        // Determine destination token
        TokenLike dst = TokenLike(path[path.length - 1]);

        // Setup buyer
        address buyer1 = address(111);
        vm.prank(buyer1); dss.vat.hope(address(clip));
        assertEq(sky.balanceOf(buyer1), 0, 'unexpected-initial-buyer1-sky-balance');
        assertEq(dst.balanceOf(buyer1), 0, 'unexpected-initial-buyer1-dst-balance');

        // Partial profit
        uint256 amtToBuy = 20_000;
        uint256 expectedProfit = (amtToBuy * 10**18) * exchangeRate - amtToBuy * uint256(pip.read()) * clip.buf() / RAY;

        // Expect revert if minimumDaiProfit set too high
        bytes memory flashData = abi.encode(
            address(buyer1),    // Address of the user (where profits are sent)
            expectedProfit + 1, // Minimum DAI/USDS profit [wad]
            path                // Uniswap v2 path
        );
        vm.expectRevert("Minimum Fill not reached");
        vm.prank(buyer1); clip.take(
            id,                 // Auction id
            amtToBuy * 10**18,  // Upper limit on amount of collateral to buy  [wad]
            type(uint256).max,  // Maximum acceptable price (DAI / collateral) [ray]
            address(callee),    // Receiver of collateral and external call address
            flashData           // Data to pass in external call; if length 0, no call is done
        );

        // Partially take auction with callee
        flashData = abi.encode(
            address(buyer1),   // Address of the user (where profits are sent)
            expectedProfit,    // Minimum DAI/USDS profit [wad]
            path               // Uniswap v2 path
        );
        vm.prank(buyer1); clip.take(
            id,                // Auction id
            amtToBuy * 10**18, // Upper limit on amount of collateral to buy  [wad]
            type(uint256).max, // Maximum acceptable price (DAI / collateral) [ray]
            address(callee),   // Receiver of collateral and external call address
            flashData          // Data to pass in external call; if length 0, no call is done
        );
        assertEq(sky.balanceOf(address(callee)), 0, "invalid-callee-sky-balance");
        assertEq(dst.balanceOf(address(callee)), 0, "invalid-callee-dst-balance");
        assertEq(sky.balanceOf(buyer1), 0, "invalid-final-buyer1-sky-balance");
        assertEq(dst.balanceOf(buyer1), expectedProfit, "invalid-final-buyer1-dst-balance");

        // Setup different buyer to take the rest of the auction
        address buyer2 = address(222);
        vm.prank(buyer2); dss.vat.hope(address(clip));
        assertEq(sky.balanceOf(buyer2), 0, "unexpected-initial-buyer2-sky-balance");
        assertEq(dst.balanceOf(buyer2), 0, "unexpected-initial-buyer2-dst-balance");
        address profitAddress = address(333);
        assertEq(dst.balanceOf(profitAddress), 0, "unexpected-initial-profit-dst-balance");

        // Take the rest of the auction with callee
        amtToBuy = 12_000;
        expectedProfit = (amtToBuy * 10**18) * exchangeRate - amtToBuy * uint256(pip.read()) * clip.buf() / RAY;
        flashData = abi.encode(
            address(profitAddress), // Address of the user (where profits are sent)
            expectedProfit,         // Minimum dai profit [wad]
            path                    // Uniswap v2 path
        );
        vm.prank(buyer2); clip.take(
            id,                // Auction id
            type(uint256).max, // Upper limit on amount of collateral to buy  [wad]
            type(uint256).max, // Maximum acceptable price (DAI / collateral) [ray]
            address(callee),   // Receiver of collateral and external call address
            flashData          // Data to pass in external call; if length 0, no call is done
        );
        assertEq(sky.balanceOf(address(callee)), 0, "invalid-callee-sky-balance");
        assertEq(dst.balanceOf(address(callee)), 0, "invalid-callee-dst-balance");
        assertEq(sky.balanceOf(buyer2), 0, "invalid-final-buyer2-sky-balance");
        assertEq(dst.balanceOf(profitAddress), expectedProfit, "invalid-final-profit");
    }

    // --- Callee tests using SKY/USDS path ---

    function testCalleeTake_NoDelegate_NoStaking_SkyUsds() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(usds);
        _testCalleeTake(false, false, uniV2Path, uniV2Price);
    }

    function testCalleeTake_WithDelegate_NoStaking_SkyUsds() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(usds);
        _testCalleeTake(true, false, uniV2Path, uniV2Price);
    }

    function testCalleeTake_NoDelegate_WithStaking_SkyUsds() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(usds);
        _testCalleeTake(false, true, uniV2Path, uniV2Price);
    }

    function testCalleeTake_WithDelegate_WithStaking_SkyUsds() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(usds);
        _testCalleeTake(true, true, uniV2Path, uniV2Price);
    }

    // --- Callee tests using SKY/DAI path ---

    function testCalleeTake_NoDelegate_NoStaking_SkyDai() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(dai);
        _testCalleeTake(false, false, uniV2Path, uniV2Price);
    }

    function testCalleeTake_WithDelegate_NoStaking_SkyDai() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(dai);
        _testCalleeTake(true, false, uniV2Path, uniV2Price);
    }

    function testCalleeTake_NoDelegate_WithStaking_SkyDai() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(dai);
        _testCalleeTake(false, true, uniV2Path, uniV2Price);
    }

    function testCalleeTake_WithDelegate_WithStaking_SkyDai() public {
        setUpCallee();
        uniV2Path[0] = address(sky);
        uniV2Path[1] = address(dai);
        _testCalleeTake(true, true, uniV2Path, uniV2Price);
    }
}
