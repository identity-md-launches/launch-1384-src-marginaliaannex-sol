// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockERC20} from "./helpers/Fixture.sol";
import {MarginaliaAnnex, IMarginaliaHookAnnex} from "../src/MarginaliaAnnex.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev The IMD launch factory's PoolInitializationGuard shape: beforeInitialize only (address bits 0x2000),
/// so the hook can never touch a swap. Etched at a flagged address.
contract GuardHook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
}

/// @dev An ERC-20 whose balanceOf reverts for a blocked holder (a blacklist), so the Annex's bounded read fails
/// for that holder while transfers and the pool still work.
contract BlockedReadToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocked", "BLK", 1_000_000_000 ether) {}

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function balanceOf(address who) public view override returns (uint256) {
        require(!blocked[who], "blocked");
        return super.balanceOf(who);
    }
}

/// @dev Stands in for the Intake: takes the price, records the body, and delivers an attestation back to the
/// consumer under the protocol's 200k callback stipend, reporting whether the callback succeeded.
contract AdmitIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public requests;
    bytes public lastBody;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        require(callback.target == msg.sender, "callback target");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        lastBody = body;
        requestId = keccak256(abi.encode(requests, body));
    }

    function deliver(
        address target,
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata sig
    ) external returns (bool ok) {
        (ok,) = target.call{gas: 200_000}(abi.encodeCall(MarginaliaAnnex.onOracleResult, (requestId, a, sig)));
    }
}

/// @dev The Annex against the local hook: venue rule by hook bits and by oracle admission, the hook's economics
/// (stamp burned as MARG, MARG to the author, bond held and returned or forfeited), observation and settlement
/// parity, counters against hook notes, and the Intake callback stipend.
contract AnnexTest is Fixture {
    using PoolIdLibrary for PoolKey;

    MarginaliaAnnex annex;
    AdmitIntake intake;
    MockERC20 x;
    PoolKey xKey;
    bool xIs0;
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    address signerAddr;
    address constant GUARD = 0x7000000000000000000000000000000000002000; // beforeInitialize only
    address constant TAXER = 0x70000000000000000000000000000000000000cc; // swap + return-delta bits (the Kiln shape)
    address constant OTHER = 0x70000000000000000000000000000000000100Cc;

    function setUp() public {
        _setup();
        signerAddr = vm.addr(SIGNER_KEY);
        intake = new AdmitIntake();
        annex = new MarginaliaAnnex(IMarginaliaHookAnnex(address(hook)), intake, ACTION, signerAddr);
        vm.etch(GUARD, address(new GuardHook()).code);
        vm.etch(TAXER, address(new GuardHook()).code);
        vm.etch(OTHER, address(new GuardHook()).code);
        // an IMD-launched token: X / IMD behind the guard hook, 1:1, wide range
        x = new MockERC20("Launched", "X", 1_000_000_000 ether);
        xIs0 = address(x) < address(imd);
        (address c0, address c1) = xIs0 ? (address(x), address(imd)) : (address(imd), address(x));
        xKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(xKey, uint160(1 << 96));
        x.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(xKey, -6000, 6000, 10_000_000 ether);
        x.transfer(alice, 1_000 ether);
        _fundCarol();
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            vm.startPrank(who[i]);
            imd.approve(address(annex), type(uint256).max);
            x.approve(address(plain), type(uint256).max);
            vm.stopPrank();
        }
        // the annex keeps its own price windows: checkpoint both venues an hour before the tests post
        annex.checkpointVenue(_xNote(T.Side.Buy, 12_000, 1, "cp"), xKey);
        annex.checkpointVenue(_margNote(T.Side.Buy, 12_000, 1, "cp"), key);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    function _xNote(T.Side side, uint32 targetBps, uint16 horizonDays, string memory text)
        internal
        view
        returns (T.NoteParams memory p)
    {
        p.x = address(x);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(xKey.toId()), address(0), false);
        p.side = side;
        p.targetBps = targetBps;
        p.horizonDays = horizonDays;
        p.class = uint8(T.Class.Declared);
        p.text = text;
    }

    function _pools() internal view returns (uint256) {
        return hook.refundPool(hook.today()) + hook.thesisPool(hook.week());
    }

    function _post(address who, T.NoteParams memory p, uint256 bond) internal returns (bytes32 id) {
        vm.prank(who);
        id = annex.post(p, p.x == address(x) ? xKey : key, bond, 1, vm.getBlockTimestamp() + 1);
    }

    function _arec(address who) internal view returns (MarginaliaAnnex.Record memory r) {
        (r.score, r.posted, r.right, r.wrong, r.broken, r.retracted) = annex.records(who);
    }

    /// @dev Three spaced observations across an hour inside the window, then past it.
    function _observeAll(bytes32 id) internal {
        vm.warp(annex.horizonEnd(id));
        annex.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        annex.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        annex.observe(id);
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
    }

    function _pumpX(uint256 imdIn) internal {
        plain.swap(xKey, !xIs0, imdIn, bob); // IMD in, X out
    }

    // ------------------------------------------------------------------ venue rule

    function testHookBitsDecideWithoutAnOracle() public view {
        assertEq(HookFlags.flagsOf(GUARD), HookFlags.BEFORE_INITIALIZE);
        assertFalse(annex.hookCanTouchSwaps(GUARD));
        assertTrue(annex.hookAllowed(GUARD), "the launch guard cannot touch a swap: allowed by arithmetic");
        assertTrue(annex.hookCanTouchSwaps(TAXER));
        assertFalse(annex.hookAllowed(TAXER), "a hook with swap permissions waits for the panel");
        assertTrue(annex.hookAllowed(address(0)));
        assertTrue(annex.hookAllowed(address(hook)), "the Marginalia pool itself");
        T.Venue memory v = annex.validateVenue(_xNote(T.Side.Buy, 12_000, 1, "t"), xKey);
        assertEq(v.quote, address(imd));
        assertEq(v.xIsToken0, xIs0);
    }

    function testRefusesWhatTheRouterAlreadyTakesAndBadKeys() public {
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.kind = T.VenueKind.UniV3;
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, xKey);
        // a key whose hook has swap bits and no admission
        PoolKey memory taxed = PoolKey(xKey.currency0, xKey.currency1, 3000, 60, IHooks(TAXER));
        p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.ref = PoolId.unwrap(taxed.toId());
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, taxed);
        // the key must match the venue ref
        p = _xNote(T.Side.Buy, 12_000, 1, "t");
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, key);
        // X may not be IMD
        p = _margNote(T.Side.Buy, 12_000, 1, "t");
        p.x = address(imd);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.validateVenue(p, key);
    }

    // ------------------------------------------------------------------ posting economics

    function testPostPaysTheStampBuysMargAndHoldsTheBond() public {
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 margBefore = token.balanceOf(alice);
        uint256 poolsBefore = _pools();
        uint256 deadBefore = token.balanceOf(annex.DEAD());
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 3, "guarded pool, +20% in 3d"), 1 ether);
        assertEq(imdBefore - imd.balanceOf(alice), annex.STAMP() + annex.MARG_BUY() + 1 ether);
        assertEq(_pools(), poolsBefore, "nothing from a post reaches the pools until a forfeit");
        assertGt(token.balanceOf(alice), margBefore, "the author receives the MARG bought with 0.25 IMD");
        assertGt(token.balanceOf(annex.DEAD()) - deadBefore, 0, "the stamp bought MARG and burned it");
        assertApproxEqRel(
            token.balanceOf(alice) - margBefore,
            (token.balanceOf(annex.DEAD()) - deadBefore) * 5 / 2,
            0.001e18,
            "25 : 10 split"
        );
        assertEq(imd.balanceOf(address(annex)), 1 ether, "the annex holds exactly the bond");
        T.NoteView memory n = annex.noteOf(id);
        assertEq(n.author, alice);
        assertEq(n.x, address(x));
        assertTrue(n.status == T.Status.Open);
        assertEq(n.class, uint8(T.Class.Declared));
        assertEq(n.deposit, 1 ether);
        assertGt(n.postPrice, 0);
        assertEq(_arec(alice).posted, 1);
        assertEq(annex.noteCount(), 1);
        // bond band and target rules are the hook's
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(_xNote(T.Side.Buy, 12_000, 3, "t"), xKey, 0.1 ether, 1, vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(_xNote(T.Side.Buy, 10_500, 3, "t"), xKey, 1 ether, 1, vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(_xNote(T.Side.Buy, 0, 3, "no theses here"), xKey, 1 ether, 1, vm.getBlockTimestamp() + 1);
    }

    function testAgentClassForContractAuthors() public {
        AdmitIntake agent = new AdmitIntake(); // any contract wallet
        imd.transfer(address(agent), 10 ether);
        vm.prank(address(agent));
        imd.approve(address(annex), type(uint256).max);
        vm.prank(address(agent));
        bytes32 id = annex.post(
            _xNote(T.Side.Sell, 8_000, 1, "agent"), xKey, 0.25 ether, 1, vm.getBlockTimestamp() + 1
        );
        assertEq(annex.noteOf(id).class, uint8(T.Class.Agent));
    }

    // ------------------------------------------------------------------ settlement parity

    function testRightCallReturnsTheBond() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "up 20%"), 2 ether);
        _pumpX(1_500_000 ether); // the price of X in IMD rises ~30%, inside the range
        _observeAll(id);
        vm.prank(bob);
        annex.settle(id);
        T.NoteView memory n = annex.noteOf(id);
        assertTrue(n.status == T.Status.Right);
        MarginaliaAnnex.Record memory r = _arec(alice);
        assertEq(r.right, 1);
        assertGt(r.score, 0);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        annex.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - before, 2 ether, "a right bond comes back in IMD");
        assertEq(imd.balanceOf(address(annex)), 0);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NothingToClaim.selector);
        annex.claimDeposit(id);
    }

    function testWrongCallForfeitsToThePoolsWithTheSettlerCut() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "up 20%"), 2 ether);
        _observeAll(id); // nothing moved
        uint256 poolsBefore = _pools();
        uint256 bobBefore = imd.balanceOf(bob);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Wrong);
        assertEq(imd.balanceOf(bob) - bobBefore, 0.2 ether, "10% of the forfeit to the settler");
        assertEq(_pools() - poolsBefore, 1.8 ether, "the rest to the hook's pools");
        assertEq(imd.balanceOf(address(annex)), 0);
        MarginaliaAnnex.Record memory r = _arec(alice);
        assertEq(r.wrong, 1);
        assertLt(r.score, 0);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NothingToClaim.selector);
        annex.claimDeposit(id);
    }

    function testHoldRuleVoidsASoldBuyCall() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "holding 1000 X"), 1 ether);
        assertEq(annex.noteOf(id).postBalance, 1_000 ether);
        _pumpX(1_500_000 ether); // right on price...
        vm.prank(alice);
        plain.swap(xKey, xIs0, 100 ether, alice); // ...but she sold some
        _observeAll(id);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.VoidSold);
        assertEq(_arec(alice).broken, 1);
        assertEq(imd.balanceOf(address(annex)), 0, "forfeited");
    }

    function testNoObservationsVoidAndReturnTheBond() public {
        bytes32 id = _post(alice, _xNote(T.Side.Sell, 8_000, 1, "down"), 1 ether);
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.VoidNoData);
        assertLt(_arec(alice).score, 0, "no data scores as wrong");
        vm.prank(alice);
        annex.claimDeposit(id);
        assertEq(imd.balanceOf(address(annex)), 0, "but the bond comes back");
    }

    function testObservationWindowAndSpacing() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        vm.expectRevert(MarginaliaAnnex.TooEarly.selector);
        annex.observe(id);
        vm.warp(annex.horizonEnd(id));
        annex.observe(id);
        vm.expectRevert(MarginaliaAnnex.ObservationTooSoon.selector);
        annex.observe(id); // same block, nothing more adverse
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
        vm.expectRevert(MarginaliaAnnex.TooLate.selector);
        annex.observe(id);
        assertEq(annex.observationsOf(id).length, 1);
    }

    function testRetractHalvesTheScoreAndForfeitsWithoutAKeeperCut() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 5, "t"), 1 ether);
        uint256 poolsBefore = _pools();
        vm.prank(bob);
        vm.expectRevert(MarginaliaAnnex.Unauthorized.selector);
        annex.retract(id, "not mine");
        vm.prank(alice);
        annex.retract(id, "changed my mind");
        assertTrue(annex.noteOf(id).status == T.Status.Retracted);
        assertEq(_pools() - poolsBefore, 1 ether, "the whole bond to the pools");
        MarginaliaAnnex.Record memory r = _arec(alice);
        assertEq(r.retracted, 1);
        assertLt(r.score, 0);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.retract(id, "twice");
    }

    /// @dev F1 (review 2026-10-12): the author already holds the purchased MARG when the balance is read, so a
    /// BUY call on the MARG pool must not count it twice: it settles RIGHT when held, never VOID_SOLD.
    function testBuyCallOnMargCountsThePurchaseOnce() public {
        bytes32 id = _post(alice, _margNote(T.Side.Buy, 12_000, 1, "marg up, holding"), 1 ether);
        assertEq(annex.noteOf(id).postBalance, token.balanceOf(alice), "post balance is the real balance");
        _buy(bob, 1_500_000 ether); // MARG rises ~30%
        _observeAll(id);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Right, "held and right, not VoidSold");
        vm.prank(alice);
        annex.claimDeposit(id);
        assertEq(imd.balanceOf(address(annex)), 0);
    }

    /// @dev F2: a dynamic-fee pool's hook sets the LP fee with no permission bit (a 100% exact-input fee freezes
    /// the price), so "no swap bits" admits nothing there; only our hook or an admitted one passes.
    function testDynamicFeePoolNeedsAdmissionEvenWithoutSwapBits() public {
        PoolKey memory dyn = PoolKey(xKey.currency0, xKey.currency1, 0x800000, 60, IHooks(GUARD));
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.ref = PoolId.unwrap(dyn.toId());
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, dyn);
        // the same pool behind the Marginalia hook would pass the fee gate (and fail later on liquidity)
        PoolKey memory ours = PoolKey(xKey.currency0, xKey.currency1, 0x800000, 60, IHooks(address(hook)));
        p.venue.ref = PoolId.unwrap(ours.toId());
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector); // no liquidity: the gate itself let it through
        annex.validateVenue(p, ours);
        assertTrue(annex.hookAllowed(GUARD), "the static-fee guard pool is still a venue by bits");
        // audit 71a5281f: the public predicate answers with the pool's fee, as validateVenue decides
        assertTrue(annex.hookAllowedFor(GUARD, 3000));
        assertFalse(annex.hookAllowedFor(GUARD, 0x800000), "dynamic fee: bits prove nothing");
        assertFalse(
            annex.hookAllowedFor(address(0), 0x800000), "a hookless pool cannot be dynamic-fee anyway"
        );
        assertTrue(annex.hookAllowedFor(address(hook), 0x800000));
        assertFalse(annex.hookAllowedFor(TAXER, 3000));
        assertFalse(annex.hookAllowedFor(TAXER, 0x800000));
    }

    function testAnAdmittedHookPassesTheDynamicFeeGate() public {
        address[] memory asked = new address[](1);
        asked[0] = TAXER;
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a = _att(requestId, asked);
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(a)));
        assertTrue(annex.hookAllowedFor(TAXER, 0x800000), "admitted: the panel read the fee logic too");
        PoolKey memory dyn = PoolKey(xKey.currency0, xKey.currency1, 0x800000, 60, IHooks(TAXER));
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.ref = PoolId.unwrap(dyn.toId());
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector); // the gate let it through; no liquidity
        annex.validateVenue(p, dyn);
    }

    /// @dev Audit 102ff796 (2026-10-12): a BUY call whose balanceOf read fails must be refused at post, as the
    /// hook refuses it, instead of storing the unverifiable sentinel and taking a bond that can only be forfeited
    /// VoidSold. A SELL call holds nothing and still posts.
    function testBuyCallOnAnUnreadableBalanceIsRefusedLikeTheHook() public {
        BlockedReadToken blk = new BlockedReadToken();
        bool is0 = address(blk) < address(imd);
        (address c0, address c1) = is0 ? (address(blk), address(imd)) : (address(imd), address(blk));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(k, uint160(1 << 96));
        blk.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(k, -6000, 6000, 10_000_000 ether);
        blk.transfer(alice, 1_000 ether);
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "blocked read");
        p.x = address(blk);
        p.venue.ref = PoolId.unwrap(k.toId());
        annex.checkpointVenue(p, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        blk.setBlocked(alice, true);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        assertEq(imd.balanceOf(alice), imdBefore, "nothing taken");
        assertEq(annex.noteCount(), 0);
        // a SELL call on the same token holds nothing and posts
        p.side = T.Side.Sell;
        p.targetBps = 8_000;
        vm.prank(alice);
        bytes32 id = annex.post(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        assertTrue(annex.noteOf(id).status == T.Status.Open);
        // and once the read works again, the BUY call posts with the real balance
        blk.setBlocked(alice, false);
        p.side = T.Side.Buy;
        p.targetBps = 12_000;
        vm.prank(alice);
        id = annex.post(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        assertEq(annex.noteOf(id).postBalance, 1_000 ether);
    }

    function testEmptyTextIsRefusedLikeTheHook() public {
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(_xNote(T.Side.Buy, 12_000, 3, ""), xKey, 1 ether, 1, vm.getBlockTimestamp() + 1);
    }

    // ------------------------------------------------------------------ counters and seals

    function testCounterAgainstAHookNoteAndAgainstAnAnnexNote() public {
        // alice's call on MARG lives on the hook (posted through the router)
        (bytes32 hookId,) = _note(alice, _margNote(T.Side.Buy, 12_000, 3, "marg up"), 1 ether);
        T.NoteParams memory p = _margNote(T.Side.Sell, 8_000, 3, "no it won't");
        p.parentId = hookId;
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector); // not against yourself
        annex.post(p, key, 1 ether, 1, vm.getBlockTimestamp() + 1);
        p.side = T.Side.Buy;
        p.targetBps = 12_000;
        vm.prank(bob);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector); // same side is not a counter
        annex.post(p, key, 1 ether, 1, vm.getBlockTimestamp() + 1);
        p.side = T.Side.Sell;
        p.targetBps = 8_000;
        bytes32 counter = _post(bob, p, 1 ether);
        assertEq(annex.noteOf(counter).parentId, hookId);
        // and a counter against an annex note
        T.NoteParams memory q = _xNote(T.Side.Buy, 12_000, 3, "x up");
        q.parentId = counter;
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector); // different X
        annex.post(q, xKey, 1 ether, 1, vm.getBlockTimestamp() + 1);
        q = _margNote(T.Side.Buy, 12_000, 3, "yes it will");
        q.parentId = counter;
        bytes32 c2 = _post(carol, q, 1 ether);
        assertEq(annex.noteOf(c2).parentId, counter);
        q.parentId = keccak256("nowhere");
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.post(q, key, 1 ether, 1, vm.getBlockTimestamp() + 1);
    }

    // ------------------------------------------------------------------ oracle admission

    function _att(bytes32 requestId, address[] memory open)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = requestId;
        a.chainId = block.chainid;
        a.questionHash = keccak256("question");
        a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        a.answer = abi.encode(open);
        a.fromBlock = 1;
        a.toBlock = 2;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("job");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, annex.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function testAdmissionAsksThePanelAndAdmitsOnlyWhatItNamed() public {
        address[] memory asked = new address[](2);
        asked[0] = TAXER;
        asked[1] = OTHER;
        uint256 before = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        assertEq(before - imd.balanceOf(carol), 0.5 ether, "the asker pays the Intake's price");
        string memory body = string(intake.lastBody());
        assertTrue(_contains(body, "0x70000000000000000000000000000000000000cc"), "the body names the hooks");
        assertTrue(_contains(body, '"answerType":"address[]"'));
        assertTrue(_contains(body, '"head":2'));
        assertTrue(
            _contains(
                body,
                "A fixed fee or tax charged to every trader alike does not exclude a hook; a hook whose owner can change the fee at will"
            )
        );
        // the panel names TAXER and a hook nobody asked about
        address[] memory open = new address[](2);
        open[0] = TAXER;
        open[1] = GUARD;
        OracleAttestation.Attestation memory a = _att(requestId, open);
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(a)), "fits the 200k stipend");
        assertTrue(annex.admittedHook(TAXER));
        assertFalse(annex.admittedHook(OTHER), "not named: not admitted");
        assertFalse(annex.admittedHook(GUARD), "not asked: nothing recorded (it needs no entry anyway)");
        assertTrue(annex.hookAllowed(TAXER), "an admitted taxing hook is a venue now");
        assertFalse(intake.deliver(address(annex), requestId, a, _sign(a)), "replay refused");
    }

    /// @dev Audit f662669c (2026-10-12): the body must be strict JSON (the Intake refuses anything else with the
    /// price spent), so it is parsed here, not substring-checked: the question names every hook without raw
    /// quotes, guards.allow carries the same list, and the question stays inside the door's 2000 characters at
    /// the full list.
    function testAdmissionBodyIsStrictJson() public view {
        address[] memory hooks = new address[](2);
        hooks[0] = TAXER;
        hooks[1] = OTHER;
        string memory body = annex.admissionBody(hooks);
        string memory q = vm.parseJsonString(body, ".question");
        assertTrue(
            _contains(q, "0x70000000000000000000000000000000000000cc"), "question names the first hook"
        );
        assertTrue(_contains(q, "0x70000000000000000000000000000000000100cc"), "and the second");
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), block.chainid);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 24);
        assertEq(vm.parseJsonString(body, ".answerType"), "address[]");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".head"), 2);
        assertEq(vm.parseJsonUint(body, ".panelSize"), annex.PANEL_SIZE());
        assertEq(vm.parseJsonUint(body, ".quorum"), annex.QUORUM());
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86400);
        address[] memory allow = vm.parseJsonAddressArray(body, ".guards.allow");
        assertEq(allow.length, 2);
        assertEq(allow[0], TAXER);
        assertEq(allow[1], OTHER);
        assertTrue(vm.parseJsonBool(body, ".guards.mustHaveCode"));
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(annex));
        // one hook, and the full list
        address[] memory one = new address[](1);
        one[0] = TAXER;
        body = annex.admissionBody(one);
        assertEq(vm.parseJsonAddressArray(body, ".guards.allow").length, 1);
        assertEq(vm.parseJsonUint(body, ".head"), 1);
        address[] memory four = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            four[i] = address(uint160(TAXER) + uint160(i));
        }
        body = annex.admissionBody(four);
        assertEq(vm.parseJsonAddressArray(body, ".guards.allow").length, 4);
        assertLe(bytes(vm.parseJsonString(body, ".question")).length, 2000, "the door's question limit");
    }

    function testAdmissionRefusesBadAnswersAndBadLists() public {
        address[] memory asked = new address[](1);
        asked[0] = TAXER;
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a = _att(requestId, asked);
        bytes memory sig = _sign(a);
        vm.expectRevert(MarginaliaAnnex.OnlyIntake.selector);
        annex.onOracleResult(requestId, a, sig);
        a.figure = 1; // tampered
        assertFalse(intake.deliver(address(annex), requestId, a, sig));
        a.figure = 0;
        a.chainId = 999;
        assertFalse(intake.deliver(address(annex), requestId, a, _sign(a)));
        a.chainId = block.chainid;
        a.agreed = 3;
        assertFalse(intake.deliver(address(annex), requestId, a, _sign(a)));
        a.agreed = 5;
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(TAXER);
        assertFalse(intake.deliver(address(annex), requestId, a, _sign(a)));
        a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        a.answer = abi.encode(asked);
        assertFalse(intake.deliver(address(annex), keccak256("unknown"), a, _sign(a)));
        assertFalse(annex.admittedHook(TAXER));
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(a)), "a good answer still lands");
        assertTrue(annex.admittedHook(TAXER));
        // list rules
        address[] memory five = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            five[i] = TAXER;
        }
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(five);
        address[] memory eoa = new address[](1);
        eoa[0] = alice;
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(eoa);
        intake.setPrice(2 ether);
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(asked);
    }

    function testFullListFitsTheCallbackStipend() public {
        address[] memory asked = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            asked[i] =
                address(uint160(0x7000000000000000000000000000000000001000) + uint160(i * 0x100 + 0xcc));
            vm.etch(asked[i], address(new GuardHook()).code);
        }
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a = _att(requestId, asked);
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(a)), "four cold admissions under 200k");
        for (uint256 i = 0; i < 4; ++i) {
            assertTrue(annex.admittedHook(asked[i]));
        }
    }
}
