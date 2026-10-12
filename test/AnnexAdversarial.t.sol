// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {Fixture, MockERC20} from "./helpers/Fixture.sol";
import {GuardHook, AdmitIntake, BlockedReadToken} from "./Annex.t.sol";
import {MarginaliaAnnex, IMarginaliaHookAnnex} from "../src/MarginaliaAnnex.sol";
import {MarginaliaPricer} from "../src/MarginaliaPricer.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev A stranger holding the PoolManager's lock who tries to drive the Annex's unlockCallback from inside it.
contract StrangerUnlocker is IUnlockCallback {
    IPoolManager immutable manager;
    MarginaliaAnnex immutable annex;
    bytes public lastRevert;

    constructor(IPoolManager m, MarginaliaAnnex a) {
        manager = m;
        annex = a;
    }

    function attack(bytes memory data) external {
        manager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        try annex.unlockCallback(data) {
            lastRevert = "";
        } catch (bytes memory r) {
            lastRevert = r;
        }
        return "";
    }
}

/// @dev The inputs the delivered suite did not try: exact boundaries, the same call twice, callers who are not
/// who the code assumed, closed parents, every attestation field at its refusal edge, the protocol's own
/// signing vector, and the shape the launcher rehearses (an empty-chain constructor under EIP-170).
contract AnnexAdversarialTest is Fixture {
    using PoolIdLibrary for PoolKey;

    MarginaliaAnnex annex;
    AdmitIntake intake;
    MockERC20 x;
    PoolKey xKey;
    bool xIs0;
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    address signerAddr;
    address constant GUARD = 0x7000000000000000000000000000000000002000;
    address constant TAXER = 0x70000000000000000000000000000000000000cc;
    address constant OTHER = 0x70000000000000000000000000000000000100Cc;

    // the protocol's signing vector (oracle-consumer reference); never changed
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant VECTOR_SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    function setUp() public {
        _setup();
        signerAddr = vm.addr(SIGNER_KEY);
        intake = new AdmitIntake();
        annex = new MarginaliaAnnex(IMarginaliaHookAnnex(address(hook)), intake, ACTION, signerAddr);
        vm.etch(GUARD, address(new GuardHook()).code);
        vm.etch(TAXER, address(new GuardHook()).code);
        vm.etch(OTHER, address(new GuardHook()).code);
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
        annex.checkpointVenue(_xNote(T.Side.Buy, 12_000, 1, "cp"), xKey);
        annex.checkpointVenue(_margNote(T.Side.Buy, 12_000, 1, "cp"), key);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    // ------------------------------------------------------------------ helpers

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

    function _post(address who, T.NoteParams memory p, uint256 bond) internal returns (bytes32 id) {
        vm.prank(who);
        id = annex.post(p, p.x == address(x) ? xKey : key, bond, 1, vm.getBlockTimestamp() + 1);
    }

    function _postExpect(address who, T.NoteParams memory p, uint256 bond, bytes4 err) internal {
        _postExpectWith(who, p, p.x == address(x) ? xKey : key, bond, err);
    }

    function _postWith(address who, T.NoteParams memory p, PoolKey memory k, uint256 bond)
        internal
        returns (bytes32 id)
    {
        vm.prank(who);
        id = annex.post(p, k, bond, 1, vm.getBlockTimestamp() + 1);
    }

    function _postExpectWith(address who, T.NoteParams memory p, PoolKey memory k, uint256 bond, bytes4 err)
        internal
    {
        vm.prank(who);
        vm.expectRevert(err);
        annex.post(p, k, bond, 1, vm.getBlockTimestamp() + 1);
    }

    /// @dev Reopens the X venue's window after a long warp (windows expire after six hours).
    function _refreshX() internal {
        annex.checkpointVenue(_xNote(T.Side.Buy, 12_000, 1, "cp"), xKey);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    function _arec(address who) internal view returns (MarginaliaAnnex.Record memory r) {
        (r.score, r.posted, r.right, r.wrong, r.broken, r.retracted) = annex.records(who);
    }

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

    function _dumpX(address who, uint256 xIn) internal {
        vm.prank(who);
        plain.swap(xKey, xIs0, xIn, who); // X in, IMD out
    }

    function _hookPools() internal view returns (uint256) {
        return _claims(address(hook), address(imd));
    }

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

    function _sign(uint256 pk, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, annex.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliverRaw(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory sig)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(address(intake));
        (ok, ret) = address(annex).call{gas: 200_000}(
            abi.encodeCall(MarginaliaAnnex.onOracleResult, (requestId, a, sig))
        );
    }

    // ------------------------------------------------------------------ deployment shape

    /// @dev The launcher rehearses the constructor in an empty EVM: it must store four values without reading
    /// anything, refuse the empty ones, and the runtime must sit under EIP-170 with the repository's settings.
    function testConstructorStoresFourValuesWithoutReadingTheChain() public {
        address noCode = makeAddr("no code here");
        address noIntake = makeAddr("no intake here");
        assertEq(noCode.code.length, 0);
        MarginaliaAnnex fresh =
            new MarginaliaAnnex(IMarginaliaHookAnnex(noCode), IIntake(noIntake), ACTION, signerAddr);
        assertEq(address(fresh.hook()), noCode);
        assertEq(address(fresh.intake()), noIntake);
        assertEq(fresh.action(), ACTION);
        assertEq(fresh.oracleSigner(), signerAddr);
        assertLe(address(fresh).code.length, 24_576, "runtime exceeds EIP-170");
        assertLe(address(annex).code.length, 24_576, "runtime exceeds EIP-170");
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        new MarginaliaAnnex(IMarginaliaHookAnnex(address(0)), IIntake(noIntake), ACTION, signerAddr);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        new MarginaliaAnnex(IMarginaliaHookAnnex(noCode), IIntake(address(0)), ACTION, signerAddr);
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        new MarginaliaAnnex(IMarginaliaHookAnnex(noCode), IIntake(noIntake), bytes32(0), signerAddr);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new MarginaliaAnnex(IMarginaliaHookAnnex(noCode), IIntake(noIntake), ACTION, address(0));
        // the constants the brief fixes
        assertEq(annex.STAMP(), 0.1 ether);
        assertEq(annex.MARG_BUY(), 0.25 ether);
        assertEq(annex.BOND_MIN(), 0.25 ether);
        assertEq(annex.BOND_MAX(), 10 ether);
        assertEq(annex.MAX_PRICE(), 1 ether);
        assertEq(annex.MAX_ADMISSION_LIST(), 4);
        assertEq(annex.PANEL_SIZE(), 5);
        assertEq(annex.QUORUM(), 4);
        assertEq(annex.KEEPER_BPS(), 1000);
        assertEq(address(annex.pricer()), 0xEaff9B262341A0cB05579227e662BFE768A71cfb);
    }

    // ------------------------------------------------------------------ posting edges

    function testPostBoundariesExactly() public {
        // the smallest BUY target and the largest SELL target post; one basis point inside is refused
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 11_000, 1, "+10%"), 0.25 ether);
        assertEq(id, keccak256(abi.encode(address(annex), uint256(1))), "ids are keccak(annex, n)");
        _postExpect(
            alice, _xNote(T.Side.Buy, 10_999, 1, "t"), 0.25 ether, MarginaliaAnnex.InvalidNote.selector
        );
        _post(alice, _xNote(T.Side.Sell, 9_000, 90, "-10%, 90 days"), 10 ether);
        _postExpect(alice, _xNote(T.Side.Sell, 9_001, 1, "t"), 1 ether, MarginaliaAnnex.InvalidNote.selector);
        _postExpect(
            alice, _xNote(T.Side.Sell, 0, 1, "sell thesis"), 1 ether, MarginaliaAnnex.InvalidNote.selector
        );
        // horizon and bond bands
        _postExpect(alice, _xNote(T.Side.Buy, 12_000, 91, "t"), 1 ether, MarginaliaAnnex.InvalidNote.selector);
        _postExpect(alice, _xNote(T.Side.Buy, 12_000, 0, "t"), 1 ether, MarginaliaAnnex.InvalidNote.selector);
        _postExpect(
            alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 10 ether + 1, MarginaliaAnnex.InvalidNote.selector
        );
        _postExpect(
            alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 0.25 ether - 1, MarginaliaAnnex.InvalidNote.selector
        );
        _postExpect(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 0, MarginaliaAnnex.InvalidNote.selector);
        // text: 280 bytes posts, 281 does not
        bytes memory longText = new bytes(280);
        for (uint256 i = 0; i < 280; ++i) {
            longText[i] = "a";
        }
        _post(alice, _xNote(T.Side.Buy, 12_000, 1, string(longText)), 1 ether);
        _postExpect(
            alice,
            _xNote(T.Side.Buy, 12_000, 1, string(bytes.concat(longText, "b"))),
            1 ether,
            MarginaliaAnnex.InvalidNote.selector
        );
        // deadline: now is fine, a second ago is not
        vm.prank(alice);
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "now"), xKey, 1 ether, 1, vm.getBlockTimestamp());
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.Expired.selector);
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "late"), xKey, 1 ether, 1, vm.getBlockTimestamp() - 1);
        assertEq(annex.noteCount(), 4);
        assertEq(_arec(alice).posted, 4);
    }

    function testSlippageAndUnfundedAuthorsTakeNothing() public {
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 margBefore = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.Slippage.selector);
        annex.post(
            _xNote(T.Side.Buy, 12_000, 1, "t"), xKey, 1 ether, type(uint128).max, vm.getBlockTimestamp()
        );
        assertEq(imd.balanceOf(alice), imdBefore);
        assertEq(token.balanceOf(alice), margBefore);
        assertEq(annex.noteCount(), 0);
        assertEq(imd.balanceOf(address(annex)), 0);
        // minMargOut == 0 is the author's choice and posts
        vm.prank(alice);
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "t"), xKey, 1 ether, 0, vm.getBlockTimestamp());
        // a wallet with no IMD, or no allowance, cannot post
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "t"), xKey, 1 ether, 1, vm.getBlockTimestamp());
        imd.transfer(poor, 10 ether);
        vm.prank(poor);
        vm.expectRevert();
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "t"), xKey, 1 ether, 1, vm.getBlockTimestamp());
        vm.prank(poor);
        imd.approve(address(annex), 1.35 ether - 1);
        vm.prank(poor);
        vm.expectRevert();
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "t"), xKey, 1 ether, 1, vm.getBlockTimestamp());
        vm.prank(poor);
        imd.approve(address(annex), 1.35 ether);
        vm.prank(poor);
        annex.post(_xNote(T.Side.Buy, 12_000, 1, "exactly 1.35"), xKey, 1 ether, 1, vm.getBlockTimestamp());
        assertEq(imd.balanceOf(poor), 10 ether - 1.35 ether);
    }

    /// @dev The 25:10 split is exact arithmetic on one swap's output, the Annex keeps no MARG, and the burn
    /// share lands at 0xdEaD.
    function testSplitIsExactAndNothingStaysInTheAnnex() public {
        uint256 margBefore = token.balanceOf(alice);
        uint256 deadBefore = token.balanceOf(annex.DEAD());
        vm.recordLogs();
        _post(alice, _xNote(T.Side.Sell, 8_000, 1, "t"), 0.25 ether);
        uint256 authorMarg = token.balanceOf(alice) - margBefore;
        uint256 burned = token.balanceOf(annex.DEAD()) - deadBefore;
        assertEq(authorMarg, (authorMarg + burned) * 25 / 35, "author share = marg * 0.25 / 0.35, floor");
        assertEq(token.balanceOf(address(annex)), 0, "no MARG retained");
        assertEq(imd.balanceOf(address(annex)), 0.25 ether, "only the bond");
        assertEq(_claims(address(annex), address(imd)), 0, "no IMD claims");
        assertEq(_claims(address(annex), address(token)), 0, "no MARG claims");
        // the Burned event carries the stamp and the burned share
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].topics[0] == keccak256("Burned(uint256,uint256)") && logs[i].emitter == address(annex)
            ) {
                (uint256 imdIn, uint256 marg) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(imdIn, 0.1 ether);
                assertEq(marg, burned);
                seen = true;
            }
        }
        assertTrue(seen, "Burned emitted");
    }

    function testUnlockCallbackAcceptsOnlyThePoolManager() public {
        bytes memory data = abi.encode(uint256(0.35 ether), uint256(0.25 ether), uint256(0), alice);
        imd.transfer(address(annex), 1 ether); // pretend bonds are held
        vm.expectRevert(MarginaliaAnnex.UnauthorizedCallback.selector);
        annex.unlockCallback(data);
        vm.prank(address(hook));
        vm.expectRevert(MarginaliaAnnex.UnauthorizedCallback.selector);
        annex.unlockCallback(data);
        // a stranger holding the manager's lock is still not the manager
        StrangerUnlocker s = new StrangerUnlocker(manager, annex);
        s.attack(data);
        assertEq(s.lastRevert(), abi.encodeWithSelector(MarginaliaAnnex.UnauthorizedCallback.selector));
        assertEq(imd.balanceOf(address(annex)), 1 ether, "nothing left the annex");
    }

    // ------------------------------------------------------------------ price windows

    function testCheckpointWindowAgesAndExpiresLikeTheRouter() public {
        MockERC20 y = new MockERC20("Y", "Y", 1_000_000_000 ether);
        bool is0 = address(y) < address(imd);
        (address c0, address c1) = is0 ? (address(y), address(imd)) : (address(imd), address(y));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        T.NoteParams memory p = _xNote(T.Side.Sell, 8_000, 1, "y");
        p.x = address(y);
        p.venue.ref = PoolId.unwrap(k.toId());
        // no liquidity yet: not a venue
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.checkpointVenue(p, k);
        manager.initialize(k, uint160(1 << 96));
        y.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(k, -6000, 6000, 10_000_000 ether);
        // no window at all
        _postExpectWith(alice, p, k, 1 ether, MarginaliaPricer.PriceHistoryUnavailable.selector);
        annex.checkpointVenue(p, k);
        T.Venue memory v = annex.validateVenue(p, k);
        (uint64 startedAt,,,,,,) = annex.priceWindows(annex.venueId(v));
        assertEq(startedAt, vm.getBlockTimestamp());
        // younger than an hour
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        vm.roll(vm.getBlockNumber() + 10);
        _postExpectWith(alice, p, k, 1 ether, MarginaliaPricer.PriceHistoryUnavailable.selector);
        vm.expectRevert(MarginaliaPricer.PriceHistoryUnavailable.selector);
        annex.postPrice(v, false);
        // an hour old: posts
        vm.warp(vm.getBlockTimestamp() + 1);
        assertGt(annex.postPrice(v, false), 0);
        _postWith(alice, p, k, 1 ether);
        // a second checkpoint extends without resetting the start
        annex.checkpointVenue(p, k);
        (uint64 again,,,,,,) = annex.priceWindows(annex.venueId(v));
        assertEq(again, startedAt, "a live window keeps its start");
        // older than six hours: expired
        vm.warp(uint256(startedAt) + 6 hours + 1);
        vm.roll(vm.getBlockNumber() + 10);
        _postExpectWith(alice, p, k, 1 ether, MarginaliaPricer.PriceHistoryUnavailable.selector);
        // a new checkpoint restarts the clock and needs its own hour
        annex.checkpointVenue(p, k);
        (uint64 restarted,,,,,,) = annex.priceWindows(annex.venueId(v));
        assertEq(restarted, vm.getBlockTimestamp());
        vm.roll(vm.getBlockNumber() + 10);
        _postExpectWith(alice, p, k, 1 ether, MarginaliaPricer.PriceHistoryUnavailable.selector);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _postWith(alice, p, k, 1 ether);
        // a window that restarted in this very block never prices in it, however old the clock says it is
        vm.warp(uint256(restarted) + 6 hours + 1);
        annex.checkpointVenue(p, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _postExpectWith(alice, p, k, 1 ether, MarginaliaPricer.PriceHistoryUnavailable.selector);
        vm.roll(vm.getBlockNumber() + 1);
        _postWith(alice, p, k, 1 ether);
    }

    function testVenueQuoteRule() public {
        // an X / MARG pool is quoted in neither IMD, WETH nor ETH
        bool is0 = address(x) < address(token);
        (address c0, address c1) = is0 ? (address(x), address(token)) : (address(token), address(x));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(k, uint160(1 << 96));
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.ref = PoolId.unwrap(k.toId());
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, k);
        // X must be in the pool
        p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.x = address(token);
        vm.expectRevert(MarginaliaAnnex.BadVenue.selector);
        annex.validateVenue(p, xKey);
        // X must have code
        p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.x = makeAddr("eoa token");
        vm.expectRevert(MarginaliaAnnex.InvalidNote.selector);
        annex.validateVenue(p, xKey);
        // a WETH-quoted pool is a venue by shape, and prices only through the mainnet hub leg
        address weth = annex.WETH();
        vm.etch(weth, address(new MockERC20("W", "W", 0)).code);
        MockERC20(weth).mint(address(liquidity), 50_000_000 ether);
        bool xIsLower = address(x) < weth;
        (c0, c1) = xIsLower ? (address(x), weth) : (weth, address(x));
        PoolKey memory wk = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(wk, uint160(1 << 96));
        liquidity.add(wk, -6000, 6000, 1_000_000 ether);
        p = _xNote(T.Side.Buy, 12_000, 1, "t");
        p.venue.ref = PoolId.unwrap(wk.toId());
        T.Venue memory v = annex.validateVenue(p, wk);
        assertEq(v.quote, weth);
        assertEq(v.xIsToken0, xIsLower);
        vm.expectRevert(MarginaliaPricer.QuoteNotPriceable.selector); // not mainnet: no hub pool
        annex.checkpointVenue(p, wk);
    }

    // ------------------------------------------------------------------ settlement: the paths not yet walked

    function testSellCallSettlesRightAndMaySellThroughTheHorizon() public {
        x.transfer(alice, 3_000_000 ether);
        bytes32 id = _post(alice, _xNote(T.Side.Sell, 8_000, 1, "down 20%"), 3 ether);
        _dumpX(alice, 2_000_000 ether); // the author sells X: no hold rule on SELL, and the price drops ~30%
        _observeAll(id);
        uint256 poolsBefore = _hookPools();
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Right);
        assertEq(_arec(alice).right, 1);
        assertEq(_arec(alice).broken, 0);
        assertEq(_hookPools(), poolsBefore, "nothing forfeited");
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        annex.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - before, 3 ether);
    }

    function testSellCallWrongWhenThePriceRises() public {
        bytes32 id = _post(alice, _xNote(T.Side.Sell, 8_000, 1, "down 20%"), 1 ether);
        _pumpX(1_500_000 ether);
        _observeAll(id);
        uint256 poolsBefore = _hookPools();
        uint256 bobBefore = imd.balanceOf(bob);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Wrong);
        assertEq(imd.balanceOf(bob) - bobBefore, 0.1 ether);
        assertEq(_hookPools() - poolsBefore, 0.9 ether, "the rest reached the hook's pool claims");
        assertEq(annex.noteOf(id).deposit, 0);
    }

    function testSettlementTakesTheMostAdverseReading() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "up 20%"), 1 ether);
        _pumpX(1_500_000 ether); // +30%: right on two readings...
        vm.warp(annex.horizonEnd(id));
        annex.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        annex.observe(id);
        // ...then an honest observer catches a dip below the target
        _dumpX(bob, 1_000_000 ether);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        annex.observe(id);
        _pumpX(1_000_000 ether); // the pump returns, too late to help
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Wrong, "the lowest reading decides a BUY call");
    }

    function testThreeReadingsInsideAnHourAreNoData() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        _pumpX(1_500_000 ether);
        vm.warp(annex.horizonEnd(id));
        annex.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        annex.observe(id);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        annex.observe(id);
        assertEq(annex.observationsOf(id).length, 3);
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
        int256 scoreBefore = _arec(alice).score;
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.VoidNoData, "a 40-minute series proves nothing");
        MarginaliaAnnex.Record memory r = _arec(alice);
        assertLt(r.score, scoreBefore);
        assertEq(r.right + r.wrong + r.broken + r.retracted, 0, "no counter moves on no data");
        vm.prank(alice);
        annex.claimDeposit(id);
        assertEq(imd.balanceOf(address(annex)), 0);
    }

    function testMoreAdverseReadingReplacesTheLastInTheSameBlock() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        _pumpX(1_500_000 ether);
        vm.warp(annex.horizonEnd(id));
        annex.observe(id);
        uint256 first = annex.observationsOf(id)[0].xRead;
        _dumpX(bob, 500_000 ether); // lower price, same block
        annex.observe(id);
        T.Observation[] memory obs = annex.observationsOf(id);
        assertEq(obs.length, 1, "replaced, not appended");
        assertLt(obs[0].xRead, first);
        _pumpX(1_000_000 ether); // higher again: not adverse
        vm.expectRevert(MarginaliaAnnex.ObservationTooSoon.selector);
        annex.observe(id);
        // a hold breach is always more adverse than a price
        _dumpX(alice, 1 ether);
        annex.observe(id);
        obs = annex.observationsOf(id);
        assertEq(obs.length, 1);
        assertLt(obs[0].balance, 1_000 ether);
        // and a breach is never replaced by a non-breach, however low the price
        x.transfer(alice, 1 ether);
        _dumpX(bob, 1_000_000 ether);
        vm.expectRevert(MarginaliaAnnex.ObservationTooSoon.selector);
        annex.observe(id);
    }

    function testSixteenReadingsAtMostAndTheLastSlotWaitsForTheHour() public {
        x.transfer(bob, 1_000_000 ether);
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        vm.warp(annex.horizonEnd(id));
        // fifteen quick readings, 25 blocks and a minute apart
        for (uint256 i = 0; i < 15; ++i) {
            annex.observe(id);
            vm.roll(vm.getBlockNumber() + 25);
            vm.warp(vm.getBlockTimestamp() + 1 minutes);
        }
        assertEq(annex.observationsOf(id).length, 15);
        vm.expectRevert(MarginaliaAnnex.ObservationTooSoon.selector); // the 16th slot is reserved
        annex.observe(id);
        vm.warp(annex.horizonEnd(id) + 1 hours);
        annex.observe(id);
        assertEq(annex.observationsOf(id).length, 16);
        vm.roll(vm.getBlockNumber() + 25);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectRevert(MarginaliaAnnex.ObservationTooSoon.selector); // full: only a worse reading lands
        annex.observe(id);
        _dumpX(bob, 500_000 ether);
        annex.observe(id);
        assertEq(annex.observationsOf(id).length, 16);
        vm.warp(annex.horizonEnd(id) + annex.SETTLE_WINDOW() + 1);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Wrong);
    }

    function testLifecycleRefusalsOnUnknownClosedAndForeignNotes() public {
        // a hook note id is not an annex note
        (bytes32 hookId,) = _note(alice, _margNote(T.Side.Buy, 12_000, 3, "on the hook"), 1 ether);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.observe(hookId);
        assertEq(annex.noteOf(hookId).author, address(0));
        bytes32 none = keccak256("nowhere");
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.horizonEnd(none);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.observe(none);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.settle(none);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.retract(none, "x");
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.claimDeposit(none);
        assertEq(annex.noteOf(none).author, address(0));
        assertEq(annex.observationsOf(none).length, 0);

        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NothingToClaim.selector);
        annex.claimDeposit(id); // open
        vm.prank(bob);
        vm.expectRevert(MarginaliaAnnex.Unauthorized.selector);
        annex.claimDeposit(id);
        vm.expectRevert(MarginaliaAnnex.TooEarly.selector);
        annex.settle(id);
        uint256 end = annex.horizonEnd(id);
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.TooLate.selector); // retract closes at the horizon
        annex.retract(id, "too late");
        vm.warp(end + annex.SETTLE_WINDOW());
        vm.expectRevert(MarginaliaAnnex.TooEarly.selector); // the window's last second still observes
        annex.settle(id);
        vm.warp(end + annex.SETTLE_WINDOW() + 1);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.VoidNoData);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.settle(id); // twice
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.observe(id);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NotOpen.selector);
        annex.retract(id, "settled");
        vm.prank(bob);
        vm.expectRevert(MarginaliaAnnex.Unauthorized.selector);
        annex.claimDeposit(id);
        vm.prank(alice);
        annex.claimDeposit(id);
        vm.prank(alice);
        vm.expectRevert(MarginaliaAnnex.NothingToClaim.selector);
        annex.claimDeposit(id); // twice
    }

    function testHoldRuleGiftsCountAsHeldAndAReadFailureAsBroken() public {
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 1 ether);
        _pumpX(1_500_000 ether);
        x.transfer(alice, 5 ether); // a stranger's gift raises the balance: still held
        _observeAll(id);
        vm.prank(bob);
        annex.settle(id);
        assertTrue(annex.noteOf(id).status == T.Status.Right);

        // a token whose balanceOf starts failing after the post: the sentinel counts as not held
        BlockedReadToken blk = new BlockedReadToken();
        bool is0 = address(blk) < address(imd);
        (address c0, address c1) = is0 ? (address(blk), address(imd)) : (address(imd), address(blk));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(k, uint160(1 << 96));
        blk.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(k, -6000, 6000, 10_000_000 ether);
        blk.transfer(alice, 1_000 ether);
        T.NoteParams memory p = _xNote(T.Side.Buy, 12_000, 1, "blocked later");
        p.x = address(blk);
        p.venue.ref = PoolId.unwrap(k.toId());
        annex.checkpointVenue(p, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        vm.prank(alice);
        bytes32 id2 = annex.post(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        blk.setBlocked(alice, true);
        plain.swap(k, !is0, 1_500_000 ether, bob); // price is right...
        _observeAll(id2);
        assertEq(annex.observationsOf(id2)[0].balance, type(uint256).max, "the sentinel is recorded");
        uint256 poolsBefore = _hookPools();
        vm.prank(bob);
        annex.settle(id2);
        assertTrue(annex.noteOf(id2).status == T.Status.VoidSold, "...but the hold cannot be verified");
        assertEq(_arec(alice).broken, 1);
        assertEq(_hookPools() - poolsBefore, 0.9 ether);
    }

    function testScoreIsDifficultyWeightedAndRetractIsHalf() public {
        // same X, same horizon: a bolder target scores more when right and costs more when wrong
        bytes32 timid = _post(alice, _xNote(T.Side.Buy, 11_000, 1, "+10%"), 1 ether);
        bytes32 bold = _post(bob, _xNote(T.Side.Buy, 12_000, 1, "+20%"), 1 ether);
        bytes32 slow = _post(carol, _xNote(T.Side.Buy, 12_000, 4, "+20% in 4 days"), 1 ether);
        _pumpX(1_500_000 ether);
        _observeAll(timid);
        _observeAll(bold);
        vm.prank(bob);
        annex.settle(timid);
        vm.prank(bob);
        annex.settle(bold);
        assertGt(_arec(bob).score, _arec(alice).score, "bold and right beats timid and right");
        // the retract costs exactly half the pricer's difficulty at the post's market cap
        uint256 mcap = annex.noteOf(slow).postPrice * x.totalSupply() / 1e18;
        uint256 diff = annex.pricer().difficulty(12_000, true, 4, mcap);
        assertGt(diff, 0);
        vm.prank(carol);
        annex.retract(slow, "never mind");
        assertEq(_arec(carol).score, -int256(diff / 2));
        assertLt(_arec(carol).score, 0);
        assertGt(
            _arec(carol).score, -_arec(bob).score, "a slower, retracted call costs less than a fast wrong one"
        );
        // the 1-day right calls scored exactly their difficulty
        mcap = annex.noteOf(bold).postPrice * x.totalSupply() / 1e18;
        assertEq(_arec(bob).score, int256(annex.pricer().difficulty(12_000, true, 1, mcap)));
        // a bond does not weight the score: alice's 1 IMD and a 10 IMD bond score the same
        _refreshX();
        bytes32 big = _post(alice, _xNote(T.Side.Buy, 11_000, 1, "+10% again"), 10 ether);
        int256 before = _arec(alice).score;
        _pumpX(1_500_000 ether);
        _observeAll(big);
        vm.prank(bob);
        annex.settle(big);
        assertTrue(annex.noteOf(big).status == T.Status.Right);
        assertEq(_arec(alice).score - before, before, "the second right call adds the same difficulty");
    }

    // ------------------------------------------------------------------ counters

    function testCountersRefuseClosedParentsAndTheses() public {
        // a retracted annex note is no longer open
        bytes32 gone = _post(alice, _xNote(T.Side.Buy, 12_000, 3, "x up"), 1 ether);
        vm.prank(alice);
        annex.retract(gone, "gone");
        T.NoteParams memory p = _xNote(T.Side.Sell, 8_000, 3, "against a retracted call");
        p.parentId = gone;
        _postExpect(bob, p, 1 ether, MarginaliaAnnex.InvalidNote.selector);
        // a settled annex note is not open either
        bytes32 done = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "x up"), 1 ether);
        vm.warp(annex.horizonEnd(done) + annex.SETTLE_WINDOW() + 1);
        annex.settle(done);
        _refreshX();
        p.parentId = done;
        _postExpect(bob, p, 1 ether, MarginaliaAnnex.InvalidNote.selector);
        // a hook thesis is not a call: no counter-call against it here
        router.checkpointVenue(_margNote(T.Side.Buy, 11_000, 1, "cp"), key);
        annex.checkpointVenue(_margNote(T.Side.Buy, 12_000, 1, "cp"), key);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        (bytes32 thesis,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "a thesis on MARG"), 1 ether);
        assertTrue(hook.noteOf(thesis).status == T.Status.ThesisOpen);
        T.NoteParams memory q = _margNote(T.Side.Sell, 8_000, 3, "against a thesis");
        q.parentId = thesis;
        _postExpect(bob, q, 1 ether, MarginaliaAnnex.InvalidNote.selector);
        // a hook call that has been retracted
        (bytes32 hookCall,) = _note(alice, _margNote(T.Side.Buy, 12_000, 3, "marg up"), 1 ether);
        vm.prank(alice);
        hook.retract(hookCall, "gone");
        q.parentId = hookCall;
        _postExpect(bob, q, 1 ether, MarginaliaAnnex.InvalidNote.selector);
        // the counter's own bond settles on its own terms; the parent's is untouched
        (bytes32 live,) = _note(alice, _margNote(T.Side.Buy, 12_000, 3, "marg up"), 1 ether);
        q.parentId = live;
        bytes32 counter = _post(bob, q, 2 ether);
        vm.prank(bob);
        annex.retract(counter, "fold");
        assertTrue(hook.noteOf(live).status == T.Status.Open, "the parent is untouched");
        assertEq(hook.noteOf(live).children, 0, "and records no child");
    }

    // ------------------------------------------------------------------ admission: every refusal edge

    function testAttestationEdgesAreRefusedOneByOne() public {
        address[] memory asked = new address[](1);
        asked[0] = TAXER;
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a;
        bool ok;
        bytes memory ret;
        // expired
        a = _att(requestId, asked);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.AttestationExpired.selector);
        // issued too far in the future
        a = _att(requestId, asked);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.AttestationNotYetValid.selector);
        // another key
        a = _att(requestId, asked);
        (ok, ret) = _deliverRaw(requestId, a, _sign(0xBAD, a));
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.BadSignature.selector);
        // a signature for a different consumer's domain (same key, another chain id in the domain)
        a = _att(requestId, asked);
        bytes memory sig = _sign(SIGNER_KEY, a);
        vm.chainId(999);
        a.chainId = 999;
        (ok, ret) = _deliverRaw(requestId, a, sig);
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.BadSignature.selector);
        vm.chainId(31337);
        // the panel below the floor, on each of the three fields
        a = _att(requestId, asked);
        a.panelSize = 4;
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), MarginaliaAnnex.BadAnswer.selector);
        a = _att(requestId, asked);
        a.quorum = 3;
        a.agreed = 5;
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), MarginaliaAnnex.BadAnswer.selector);
        a = _att(requestId, asked);
        a.quorum = 5;
        a.agreed = 4;
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), MarginaliaAnnex.BadAnswer.selector);
        // a bytes32[] answer, even well signed
        a = _att(requestId, asked);
        a.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.WrongAnswerType.selector);
        // a bool "yes" is not a list
        a = _att(requestId, asked);
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        (ok, ret) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertFalse(ok);
        // the exact floor passes: panel 5, quorum 4, agreed 4
        a = _att(requestId, asked);
        a.agreed = 4;
        (ok,) = _deliverRaw(requestId, a, _sign(SIGNER_KEY, a));
        assertTrue(ok);
        assertTrue(annex.admittedHook(TAXER));
        assertTrue(annex.consumed(a.requestId));
    }

    function testAnEmptyAnswerIsStoredNotReverted() public {
        address[] memory asked = new address[](2);
        asked[0] = TAXER;
        asked[1] = OTHER;
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a = _att(requestId, new address[](0));
        assertTrue(
            intake.deliver(address(annex), requestId, a, _sign(SIGNER_KEY, a)), "a 'none' answer lands"
        );
        assertFalse(annex.admittedHook(TAXER));
        assertFalse(annex.admittedHook(OTHER));
        assertTrue(annex.consumed(a.requestId));
        // the request is spent: a second, generous answer for the same id is refused
        OracleAttestation.Attestation memory b = _att(requestId, asked);
        b.requestId = keccak256("another oracle uuid");
        (bool ok, bytes memory ret) = _deliverRaw(requestId, b, _sign(SIGNER_KEY, b));
        assertFalse(ok);
        assertEq(bytes4(ret), MarginaliaAnnex.BadList.selector);
        assertFalse(annex.admittedHook(TAXER));
    }

    function testOneOracleUuidServesOneRequestOnly() public {
        address[] memory one = new address[](1);
        one[0] = TAXER;
        address[] memory two = new address[](1);
        two[0] = OTHER;
        vm.prank(carol);
        bytes32 r1 = annex.requestAdmission(one);
        vm.prank(carol);
        bytes32 r2 = annex.requestAdmission(two);
        assertTrue(r1 != r2);
        OracleAttestation.Attestation memory a = _att(r1, one);
        assertTrue(intake.deliver(address(annex), r1, a, _sign(SIGNER_KEY, a)));
        // the same oracle uuid presented for the second intake request: consumed already
        OracleAttestation.Attestation memory b = _att(r2, two);
        b.requestId = a.requestId;
        (bool ok, bytes memory ret) = _deliverRaw(r2, b, _sign(SIGNER_KEY, b));
        assertFalse(ok);
        assertEq(bytes4(ret), OracleAttestationConsumer.AlreadyConsumed.selector);
        assertFalse(annex.admittedHook(OTHER));
        // a fresh uuid answers it
        b.requestId = keccak256("fresh");
        assertTrue(intake.deliver(address(annex), r2, b, _sign(SIGNER_KEY, b)));
        assertTrue(annex.admittedHook(OTHER));
    }

    function testAdmissionListRulesAndPrice() public {
        address[] memory none = new address[](0);
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(none);
        address[] memory withZero = new address[](2);
        withZero[0] = TAXER;
        withZero[1] = address(0);
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(withZero);
        address[] memory asked = new address[](1);
        asked[0] = TAXER;
        intake.setPrice(0);
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(asked);
        intake.setPrice(1 ether + 1);
        vm.prank(carol);
        vm.expectRevert(MarginaliaAnnex.BadList.selector);
        annex.requestAdmission(asked);
        // exactly MAX_PRICE is paid, by the asker, and never from the bonds the annex holds
        intake.setPrice(1 ether);
        bytes32 id = _post(alice, _xNote(T.Side.Buy, 12_000, 1, "t"), 2 ether);
        uint256 carolBefore = imd.balanceOf(carol);
        uint256 intakeBefore = imd.balanceOf(address(intake));
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        assertEq(carolBefore - imd.balanceOf(carol), 1 ether);
        assertEq(imd.balanceOf(address(intake)) - intakeBefore, 1 ether);
        assertEq(imd.balanceOf(address(annex)), 2 ether, "the bond is untouched");
        assertEq(imd.allowance(address(annex), address(intake)), 0, "no allowance left behind");
        // a wallet without IMD cannot ask
        vm.prank(makeAddr("broke"));
        vm.expectRevert();
        annex.requestAdmission(asked);
        // the answer changes nothing about the bonds either
        OracleAttestation.Attestation memory a = _att(requestId, asked);
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(SIGNER_KEY, a)));
        assertEq(imd.balanceOf(address(annex)), 2 ether);
        assertEq(annex.noteOf(id).deposit, 2 ether);
        // duplicates in one list admit once
        address[] memory dup = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            dup[i] = OTHER;
        }
        vm.prank(carol);
        requestId = annex.requestAdmission(dup);
        a = _att(requestId, dup);
        assertTrue(intake.deliver(address(annex), requestId, a, _sign(SIGNER_KEY, a)));
        assertTrue(annex.admittedHook(OTHER));
    }

    /// @dev The write-set at the full list is what the stipend pays for: four cold admissions, one consumed id,
    /// the list cleared. Measured directly, with headroom under 200k, warm and cold.
    function testCallbackGasAtTheFullListStaysUnderTheStipend() public {
        address[] memory asked = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            asked[i] =
                address(uint160(0x7000000000000000000000000000000000001000) + uint160(i * 0x100 + 0xcc));
            vm.etch(asked[i], address(new GuardHook()).code);
        }
        vm.prank(carol);
        bytes32 requestId = annex.requestAdmission(asked);
        OracleAttestation.Attestation memory a = _att(requestId, asked);
        bytes memory sig = _sign(SIGNER_KEY, a);
        bytes memory data = abi.encodeCall(MarginaliaAnnex.onOracleResult, (requestId, a, sig));
        // the cold full list (four admissions, one consumed id, the list cleared) lands inside 180k: 20k of
        // headroom under the Intake's 200k stipend, so one more storage write in the callback would show here
        vm.prank(address(intake));
        (bool ok,) = address(annex).call{gas: 180_000}(data);
        assertTrue(ok, "cold full-list callback must fit 180k");
        for (uint256 i = 0; i < 4; ++i) {
            assertTrue(annex.admittedHook(asked[i]));
        }
        // asked again about hooks already admitted: nothing to admit, and it still lands
        vm.prank(carol);
        requestId = annex.requestAdmission(asked);
        a = _att(requestId, asked);
        a.requestId = keccak256("second uuid");
        sig = _sign(SIGNER_KEY, a);
        data = abi.encodeCall(MarginaliaAnnex.onOracleResult, (requestId, a, sig));
        vm.prank(address(intake));
        (ok,) = address(annex).call{gas: 180_000}(data);
        assertTrue(ok);
        assertTrue(annex.consumed(a.requestId));
    }

    /// @dev The protocol's own vector: the digest the annex verifies is the one the oracle signs, the callback
    /// selector is the one the intake calls, and the vector's signature verifies before the application's own
    /// checks refuse its chain.
    function testProtocolVectorDigestSelectorAndSignature() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(1_800_000_000);
        deployCodeTo(
            "MarginaliaAnnex.sol:MarginaliaAnnex",
            abi.encode(address(hook), address(intake), ACTION, VECTOR_SIGNER),
            VECTOR_CONSUMER
        );
        MarginaliaAnnex vec = MarginaliaAnnex(VECTOR_CONSUMER);
        OracleAttestation.Attestation memory a = _vector();
        assertEq(vec.attestationDigest(a), VECTOR_DIGEST, "struct, type string or domain differs");
        assertEq(vec.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
        assertEq(vec.onOracleResult.selector, bytes4(0x510379c7));
        // a request of its own, then the vector as delivered: the signature holds, the chain does not match
        vm.prank(carol);
        imd.approve(VECTOR_CONSUMER, type(uint256).max);
        address[] memory asked = new address[](1);
        asked[0] = TAXER;
        vm.prank(carol);
        bytes32 requestId = vec.requestAdmission(asked);
        vm.prank(address(intake));
        vm.expectRevert(MarginaliaAnnex.BadAnswer.selector);
        vec.onOracleResult(requestId, a, VECTOR_SIGNATURE);
        // one flipped byte in the answer: the signature no longer holds
        a.answer = abi.encode(new bytes32[](0));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vec.onOracleResult(requestId, a, VECTOR_SIGNATURE);
    }

    function _vector() private pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }
}
