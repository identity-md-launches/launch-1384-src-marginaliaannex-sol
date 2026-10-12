// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Fixture, MockERC20, TestSwapRouter, LiquidityHelper} from "./helpers/Fixture.sol";
import {GuardHook, AdmitIntake, FreeSwapper} from "./Annex.t.sol";
import {MarginaliaAnnex, IMarginaliaHookAnnex} from "../src/MarginaliaAnnex.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Drives the Annex with real posts, trades, observations, settlements, retractions, claims, oracle
/// admissions and the venue's LP pulling and refilling its positions, in random order, keeping its own ledger
/// of every bond. Nothing is injected into contract storage and no read is mocked: the ledger is what the
/// contract must agree with after every sequence.
contract AnnexHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MarginaliaAnnex public immutable annex;
    MarginaliaHook public immutable hook;
    IPoolManager public immutable manager;
    AdmitIntake public immutable intake;
    IERC20 public immutable imd;
    IERC20 public immutable marg;
    MockERC20 public immutable x;
    TestSwapRouter public immutable plain;
    LiquidityHelper public immutable liquidity;
    FreeSwapper public immutable freeSwapper;
    PoolKey internal xKey;
    PoolKey internal margKey;
    bool internal immutable xIs0;
    bool internal immutable margIs0;
    uint256 internal immutable signerKey;
    address[3] public actors;
    address public immutable keeper;

    struct Bond {
        address author;
        uint256 original;
        uint256 outstanding; // what the annex still owes the author
        T.Status status;
        uint256 postedAt;
    }

    bytes32[] public ids;
    mapping(bytes32 => Bond) public bonds;
    address[] public admitted;
    mapping(address => uint256) public postedBy;
    mapping(address => uint256) public rightBy;
    mapping(address => uint256) public wrongBy;
    mapping(address => uint256) public brokenBy;
    mapping(address => uint256) public retractedBy;
    mapping(address => uint256) public noDataBy;

    uint256 public bondsIn;
    uint256 public claimed;
    uint256 public keeperPaid;
    uint256 public toPools;
    uint256 public admissionsPaid;
    uint256 public calls;
    uint256 public posts;
    uint256 public settles;
    uint256 public boundedPosts;
    uint256 public standingReadings;
    uint256 public observationsLanded;
    uint256 public observationsRefused;
    uint256 public hookPoolsAtStart;
    uint256 internal admissionNonce;
    bool public venueEmptied; // the X venue's two positions are pulled (held by the helper until refilled)

    constructor(
        MarginaliaAnnex annex_,
        MarginaliaHook hook_,
        IPoolManager manager_,
        AdmitIntake intake_,
        IERC20 imd_,
        IERC20 marg_,
        MockERC20 x_,
        TestSwapRouter plain_,
        LiquidityHelper liquidity_,
        PoolKey memory xKey_,
        PoolKey memory margKey_,
        address[3] memory actors_,
        uint256 signerKey_
    ) {
        annex = annex_;
        hook = hook_;
        manager = manager_;
        intake = intake_;
        imd = imd_;
        marg = marg_;
        x = x_;
        plain = plain_;
        liquidity = liquidity_;
        freeSwapper = new FreeSwapper(manager_);
        xKey = xKey_;
        margKey = margKey_;
        xIs0 = Currency.unwrap(xKey_.currency0) == address(x_);
        margIs0 = Currency.unwrap(margKey_.currency0) == address(marg_);
        actors = actors_;
        keeper = makeAddr("annex keeper");
        signerKey = signerKey_;
        hookPoolsAtStart = manager.balanceOf(address(hook), uint256(uint160(address(imd))));
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _params(bool onMarg, bool buy, uint32 targetBps, uint16 horizonDays)
        internal
        view
        returns (T.NoteParams memory p, PoolKey memory k)
    {
        k = onMarg ? margKey : xKey;
        p.x = onMarg ? address(marg) : address(x);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(k.toId()), address(0), false);
        p.side = buy ? T.Side.Buy : T.Side.Sell;
        p.targetBps = targetBps;
        p.horizonDays = horizonDays;
        p.class = uint8(T.Class.Declared);
        p.text = "handler";
    }

    /// @dev Brings a venue's window into the 1..6 hour band a post needs (expired windows restart and age).
    function _ensureWindow(T.NoteParams memory p, PoolKey memory k) internal returns (bool) {
        T.Venue memory v;
        try annex.validateVenue(p, k) returns (T.Venue memory got) {
            v = got;
        } catch {
            return false;
        }
        (uint64 startedAt,,,,,,) = annex.priceWindows(annex.venueId(v));
        if (startedAt == 0 || vm.getBlockTimestamp() > uint256(startedAt) + 6 hours) {
            try annex.checkpointVenue(p, k) {}
            catch {
                return false;
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
            vm.roll(vm.getBlockNumber() + 300);
        } else if (vm.getBlockTimestamp() < uint256(startedAt) + 1 hours) {
            vm.warp(uint256(startedAt) + 1 hours);
            vm.roll(vm.getBlockNumber() + 300);
        }
        return true;
    }

    function _open(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 n = ids.length;
        if (n == 0) return (bytes32(0), false);
        for (uint256 i = 0; i < n; ++i) {
            id = ids[(seed % n + i) % n];
            if (bonds[id].status == T.Status.Open) return (id, true);
        }
        return (bytes32(0), false);
    }

    /// @dev An open note whose settlement window can still be reached: not yet past the horizon when
    /// `beforeEnd` (a full series needs the whole window), not yet past the window otherwise.
    function _observable(uint256 seed, bool beforeEnd, bool preferX)
        internal
        view
        returns (bytes32 id, bool found)
    {
        uint256 n = ids.length;
        if (n == 0) return (bytes32(0), false);
        bytes32 other;
        for (uint256 i = 0; i < n; ++i) {
            id = ids[(seed % n + i) % n];
            if (bonds[id].status != T.Status.Open) continue;
            uint256 end = annex.horizonEnd(id);
            if (vm.getBlockTimestamp() > (beforeEnd ? end : end + 6 hours)) continue;
            if (!preferX || annex.noteOf(id).x == address(x)) return (id, true);
            if (other == bytes32(0)) other = id;
        }
        return other == bytes32(0) ? (bytes32(0), false) : (other, true);
    }

    function _claimable(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 n = ids.length;
        if (n == 0) return (bytes32(0), false);
        for (uint256 i = 0; i < n; ++i) {
            id = ids[(seed % n + i) % n];
            Bond storage b = bonds[id];
            if ((b.status == T.Status.Right || b.status == T.Status.VoidNoData) && b.outstanding > 0) {
                return (id, true);
            }
        }
        return (bytes32(0), false);
    }

    // ------------------------------------------------------------------ actions

    /// @dev `bounded` quotes the baseline the contract itself would use and passes it as `baselineBound`: a
    /// bound at the quoted baseline must never be refused as slippage (the check is inclusive), and the note
    /// must then carry exactly that baseline. On the MARG venue the post's own 0.35 IMD purchase moves the
    /// spot before the baseline is read, so there the quote gets the 1% an agent is told to allow and the
    /// recorded baseline must sit inside it.
    function post(
        uint256 actorSeed,
        bool onMarg,
        bool buy,
        uint32 targetSeed,
        uint16 horizonSeed,
        uint256 bondSeed,
        bool bounded
    ) external {
        calls++;
        address who = _actor(actorSeed);
        uint32 targetBps =
            buy ? uint32(bound(targetSeed, 11_000, 40_000)) : uint32(bound(targetSeed, 2_500, 9_000));
        uint16 horizonDays = uint16(bound(horizonSeed, 1, 5));
        uint256 bond = bound(bondSeed, 0.25 ether, 10 ether);
        (T.NoteParams memory p, PoolKey memory k) = _params(onMarg, buy, targetBps, horizonDays);
        if (!_ensureWindow(p, k)) return;
        uint256 baselineBound;
        if (bounded) {
            try annex.postPrice(annex.validateVenue(p, k), buy) returns (uint256 quoted) {
                baselineBound = !onMarg ? quoted : buy ? quoted * 101 / 100 : quoted * 99 / 100;
            } catch {
                return;
            }
        }
        uint256 before = imd.balanceOf(address(annex));
        vm.prank(who);
        try annex.post(p, k, bond, 0, baselineBound, vm.getBlockTimestamp()) returns (bytes32 id) {
            posts++;
            ids.push(id);
            bonds[id] = Bond(who, bond, bond, T.Status.Open, vm.getBlockTimestamp());
            bondsIn += bond;
            postedBy[who] += 1;
            assertEq(imd.balanceOf(address(annex)) - before, bond, "a post leaves exactly the bond behind");
            assertEq(annex.noteOf(id).deposit, bond);
            assertTrue(annex.noteOf(id).status == T.Status.Open);
            if (bounded) {
                boundedPosts++;
                uint256 recorded = annex.noteOf(id).postPrice;
                if (!onMarg) {
                    assertEq(recorded, baselineBound, "the quoted baseline is the recorded one");
                } else if (buy) {
                    assertLe(recorded, baselineBound, "a BUY baseline inside the bound");
                } else {
                    assertGe(recorded, baselineBound, "a SELL baseline inside the bound");
                }
            }
        } catch (bytes memory reason) {
            assertEq(imd.balanceOf(address(annex)), before, "a failed post moves nothing");
            if (bounded) {
                assertTrue(
                    bytes4(reason) != MarginaliaAnnex.Slippage.selector,
                    "a bound at the quoted baseline is never slippage"
                );
            }
        }
    }

    /// @dev One reading inside the window of a note that can still be observed; `pullFirst` has the venue's LP
    /// pull its positions before the reading, so standing prices without liquidity are exercised too.
    function observe(uint256 idSeed, uint256 dtSeed, bool pullFirst) external {
        calls++;
        (bytes32 id, bool found) = _observable(idSeed, false, pullFirst);
        if (!found) return;
        if (pullFirst && !venueEmptied) this.pullOrRefillVenue(false);
        uint256 end = annex.horizonEnd(id);
        uint256 target = end + bound(dtSeed, 0, 6 hours);
        if (target > vm.getBlockTimestamp()) vm.warp(target);
        vm.roll(vm.getBlockNumber() + 25);
        _observeAndCheck(id);
    }

    /// @dev Both generated observation paths check the price against the PoolManager's standing slot0.
    /// The pricer is the immutable dependency, not the Annex implementation of its empty-pool fallback.
    function _observeAndCheck(bytes32 id) internal {
        T.Venue memory venue = annex.venueOf(id);
        bool empty = manager.getLiquidity(PoolId.wrap(venue.ref)) == 0;
        (uint160 sqrtP,,,) = manager.getSlot0(PoolId.wrap(venue.ref));
        if (empty && sqrtP < 1e20) sqrtP = 1e20;
        else if (empty && sqrtP > 7e37) sqrtP = 7e37;
        uint256 expected = annex.pricer().fromSqrt(sqrtP, venue.xIsToken0);
        try annex.observe(id) {
            observationsLanded++;
            T.Observation[] memory obs = annex.observationsOf(id);
            T.Observation memory last = obs[obs.length - 1];
            assertGt(last.xRead, 0, "an observed empty pool is not missing data");
            assertEq(last.xRead, expected, "the reading is the standing price, clamped at extremes");
            assertEq(last.quoteRead, 1e18, "both generated venues are quoted in IMD");
            if (empty) standingReadings++;
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason), MarginaliaAnnex.ObservationTooSoon.selector, "unexpected observation refusal"
            );
            observationsRefused++;
        }
    }

    /// @dev The X venue's LP pulls both positions, or puts them back: posts on it are refused meanwhile, open
    /// calls retain the standing price, and the bond ledger must still balance whatever that does to outcomes.
    function pullOrRefillVenue(bool refill) external {
        calls++;
        if (refill != venueEmptied) return; // nothing to refill, or nothing left to pull
        if (refill) {
            liquidity.add(xKey, -6000, 6000, 10_000_000 ether);
            liquidity.add(xKey, -887_220, 887_220, 1_000_000 ether);
            venueEmptied = false;
            assertGt(manager.getLiquidity(xKey.toId()), 0);
        } else {
            liquidity.add(xKey, -6000, 6000, -10_000_000 ether);
            liquidity.add(xKey, -887_220, 887_220, -1_000_000 ether);
            venueEmptied = true;
            assertEq(manager.getLiquidity(xKey.toId()), 0);
        }
    }

    /// @dev A pulled pool can move for free. Exercise changing standing prices between observations,
    /// staying inside the original LP range so refilling remains affordable for this finite fixture.
    function pushEmptyPrice(int24 tickSeed) external {
        calls++;
        if (!venueEmptied) return;
        int24 tick = int24(bound(int256(tickSeed), -5000, 5000));
        uint160 next = TickMath.getSqrtPriceAtTick(xIs0 ? tick : -tick);
        (uint160 current,,,) = manager.getSlot0(xKey.toId());
        if (next == current) return;
        freeSwapper.push(xKey, next);
        assertEq(manager.getLiquidity(xKey.toId()), 0);
    }

    /// @dev A keeper's full series: three readings 25 blocks apart spanning an hour, so settlement has data.
    function observeSeries(uint256 idSeed) external {
        calls++;
        (bytes32 id, bool found) = _observable(idSeed, true, false);
        if (!found) return;
        uint256 end = annex.horizonEnd(id);
        vm.warp(end);
        vm.roll(vm.getBlockNumber() + 25);
        _observeAndCheck(id);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.roll(vm.getBlockNumber() + 25);
        _observeAndCheck(id);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.roll(vm.getBlockNumber() + 25);
        _observeAndCheck(id);
    }

    function settle(uint256 idSeed) external {
        calls++;
        (bytes32 id, bool found) = _open(idSeed);
        if (!found) return;
        uint256 end = annex.horizonEnd(id);
        if (vm.getBlockTimestamp() <= end + 6 hours) vm.warp(end + 6 hours + 1);
        uint256 keeperBefore = imd.balanceOf(keeper);
        uint256 hookBefore = _hookClaims();
        T.Status expected = _expectedOutcome(id);
        vm.prank(keeper);
        try annex.settle(id) {
            settles++;
            Bond storage b = bonds[id];
            T.Status s = annex.noteOf(id).status;
            assertTrue(s == expected, "settlement must follow the observed prices and hold rule");
            b.status = s;
            if (s == T.Status.Right) {
                rightBy[b.author] += 1;
            } else if (s == T.Status.VoidNoData) {
                noDataBy[b.author] += 1;
            } else {
                if (s == T.Status.Wrong) wrongBy[b.author] += 1;
                else if (s == T.Status.VoidSold) brokenBy[b.author] += 1;
                else revert("unexpected outcome");
                uint256 reward = b.original * 1000 / 10_000;
                keeperPaid += reward;
                toPools += b.original - reward;
                b.outstanding = 0;
                assertEq(imd.balanceOf(keeper) - keeperBefore, reward, "the settler earns 10% of a forfeit");
                assertEq(_hookClaims() - hookBefore, b.original - reward, "the rest reaches the hook's pools");
            }
            if (s == T.Status.Right || s == T.Status.VoidNoData) {
                assertEq(_hookClaims(), hookBefore, "a returned bond funds nothing");
                assertEq(imd.balanceOf(keeper), keeperBefore, "and pays no keeper");
            }
        } catch {
            fail("an open note past its window must settle");
        }
    }

    /// @dev Each sample must meet the target. An empty pool contributes a price on the same terms as any
    /// other sample; it cannot force WRONG or a refund by itself. Hold breaches still dominate price.
    function _expectedOutcome(bytes32 id) internal view returns (T.Status) {
        T.Observation[] memory obs = annex.observationsOf(id);
        if (obs.length < 3 || obs[obs.length - 1].timestamp - obs[0].timestamp < 1 hours) {
            return T.Status.VoidNoData;
        }
        T.NoteView memory n = annex.noteOf(id);
        bool meetsTarget = true;
        for (uint256 i; i < obs.length; ++i) {
            assertGt(obs[i].xRead, 0, "every sample is priceable in the generated IMD venues");
            assertEq(obs[i].quoteRead, 1e18);
            if (n.side == T.Side.Buy && obs[i].balance < n.postBalance) return T.Status.VoidSold;
            if (n.side == T.Side.Buy) {
                if (obs[i].xRead * 10_000 < n.postPrice * n.targetBps) meetsTarget = false;
            } else {
                if (obs[i].xRead * 10_000 > n.postPrice * n.targetBps) meetsTarget = false;
            }
        }
        return meetsTarget ? T.Status.Right : T.Status.Wrong;
    }

    function _hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(address(imd))));
    }

    function retract(uint256 idSeed) external {
        calls++;
        (bytes32 id, bool found) = _open(idSeed);
        if (!found) return;
        Bond storage b = bonds[id];
        uint256 hookBefore = _hookClaims();
        vm.prank(b.author);
        try annex.retract(id, "handler retract") {
            assertTrue(annex.noteOf(id).status == T.Status.Retracted);
            assertEq(_hookClaims() - hookBefore, b.original, "the whole bond, no keeper cut");
            b.status = T.Status.Retracted;
            toPools += b.original;
            b.outstanding = 0;
            retractedBy[b.author] += 1;
        } catch {}
    }

    function claim(uint256 idSeed) external {
        calls++;
        (bytes32 id, bool found) = _claimable(idSeed);
        if (!found) return;
        Bond storage b = bonds[id];
        uint256 before = imd.balanceOf(b.author);
        vm.prank(b.author);
        annex.claimDeposit(id); // a right or no-data bond must always come back: no try here
        assertEq(imd.balanceOf(b.author) - before, b.outstanding, "the whole bond, once");
        claimed += b.outstanding;
        b.outstanding = 0;
        vm.prank(b.author);
        vm.expectRevert(MarginaliaAnnex.NothingToClaim.selector);
        annex.claimDeposit(id);
    }

    /// @dev A stranger cannot claim or retract anyone's bond.
    function strangerClaim(uint256 idSeed, uint256 actorSeed) external {
        calls++;
        if (ids.length == 0) return;
        bytes32 id = ids[idSeed % ids.length];
        address who = _actor(actorSeed);
        if (who == bonds[id].author) who = keeper;
        vm.prank(who);
        vm.expectRevert(MarginaliaAnnex.Unauthorized.selector);
        annex.claimDeposit(id);
        vm.prank(who);
        vm.expectRevert(MarginaliaAnnex.Unauthorized.selector);
        annex.retract(id, "not mine");
    }

    function tradeX(uint256 actorSeed, bool pump, uint256 amountSeed) external {
        calls++;
        address who = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1 ether, 300_000 ether);
        if (pump) {
            if (imd.balanceOf(who) < amount) return;
            try plain.swap(xKey, !xIs0, amount, who) {} catch {}
        } else {
            if (x.balanceOf(who) < amount) return;
            vm.prank(who);
            try plain.swap(xKey, xIs0, amount, who) {} catch {}
        }
    }

    function tradeMarg(uint256 actorSeed, bool pump, uint256 amountSeed) external {
        calls++;
        address who = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1 ether, 100_000 ether);
        if (pump) {
            if (imd.balanceOf(who) < amount) return;
            try plain.swap(margKey, !margIs0, amount, who) {} catch {}
        } else {
            if (marg.balanceOf(who) < amount) return;
            vm.prank(who);
            try plain.swap(margKey, margIs0, amount, who) {} catch {}
        }
    }

    /// @dev An author moving a little X out breaks any open BUY hold; a gift never does.
    function moveX(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        calls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 1, 10 ether);
        if (x.balanceOf(from) < amount) return;
        vm.prank(from);
        x.transfer(to, amount);
    }

    function warp(uint256 dtSeed) external {
        calls++;
        vm.warp(vm.getBlockTimestamp() + bound(dtSeed, 1, 2 days));
        vm.roll(vm.getBlockNumber() + 100);
    }

    /// @dev Anyone pays the Intake and the panel's signed answer admits only what was asked and named.
    function admission(uint256 actorSeed, uint256 listSeed, uint256 nameSeed) external {
        calls++;
        address who = _actor(actorSeed);
        uint256 n = bound(listSeed, 1, 4);
        address[] memory asked = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            asked[i] = address(
                uint160(0x7000000000000000000000000000000000004000)
                    + uint160(((listSeed >> (8 * i)) % 8) * 0x100 + 0xcc)
            );
            if (asked[i].code.length == 0) vm.etch(asked[i], address(new GuardHook()).code);
        }
        uint256 annexBefore = imd.balanceOf(address(annex));
        vm.prank(who);
        bytes32 requestId;
        try annex.requestAdmission(asked) returns (bytes32 r) {
            requestId = r;
            admissionsPaid += intake.price();
        } catch {
            return;
        }
        assertEq(imd.balanceOf(address(annex)), annexBefore, "the asker pays, never the bonds");
        // the panel names a subset
        uint256 named;
        address[] memory open = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            if ((nameSeed >> i) & 1 == 1) open[named++] = asked[i];
        }
        assembly ("memory-safe") {
            mstore(open, named)
        }
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("uuid", ++admissionNonce));
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        a.answer = abi.encode(open);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, annex.attestationDigest(a));
        bool ok = intake.deliver(address(annex), requestId, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "a well-formed answer always lands under the stipend");
        for (uint256 i = 0; i < named; ++i) {
            assertTrue(annex.admittedHook(open[i]), "named and asked: admitted");
            admitted.push(open[i]);
        }
        assertEq(imd.balanceOf(address(annex)), annexBefore, "the answer moves no IMD");
        assertFalse(intake.deliver(address(annex), requestId, a, abi.encodePacked(r, s, v)), "replay refused");
    }

    // ------------------------------------------------------------------ views for the invariants

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function admittedCount() external view returns (uint256) {
        return admitted.length;
    }

    function outstandingSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < ids.length; ++i) {
            sum += bonds[ids[i]].outstanding;
        }
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract AnnexInvariantTest is Fixture {
    using PoolIdLibrary for PoolKey;

    MarginaliaAnnex annex;
    AdmitIntake intake;
    MockERC20 x;
    PoolKey xKey;
    AnnexHandler handler;
    uint256 constant SIGNER_KEY = 0x5E7;
    address constant GUARD = 0x7000000000000000000000000000000000002000;

    function setUp() public {
        _setup();
        intake = new AdmitIntake();
        annex = new MarginaliaAnnex(
            IMarginaliaHookAnnex(address(hook)),
            intake,
            bytes32("oracle.request@oracle-1"),
            vm.addr(SIGNER_KEY)
        );
        vm.etch(GUARD, address(new GuardHook()).code);
        x = new MockERC20("Launched", "X", 1_000_000_000 ether);
        bool xIs0 = address(x) < address(imd);
        (address c0, address c1) = xIs0 ? (address(x), address(imd)) : (address(imd), address(x));
        xKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(GUARD));
        manager.initialize(xKey, uint160(1 << 96));
        x.transfer(address(liquidity), 100_000_000 ether);
        imd.transfer(address(liquidity), 50_000_000 ether);
        liquidity.add(xKey, -6000, 6000, 10_000_000 ether);
        liquidity.add(xKey, -887_220, 887_220, 1_000_000 ether); // full range: the price can always be read
        _fundCarol();
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            x.transfer(actors[i], 1_000_000 ether);
            token.transfer(actors[i], 100_000 ether);
            vm.startPrank(actors[i]);
            imd.approve(address(annex), type(uint256).max);
            imd.approve(address(plain), type(uint256).max);
            x.approve(address(plain), type(uint256).max);
            token.approve(address(plain), type(uint256).max);
            vm.stopPrank();
        }
        handler = new AnnexHandler(
            annex,
            hook,
            manager,
            intake,
            IERC20(address(imd)),
            IERC20(address(token)),
            x,
            plain,
            liquidity,
            xKey,
            key,
            actors,
            SIGNER_KEY
        );
        targetContract(address(handler));
    }

    /// @dev Visible with -vv: how far the random sequences actually reached.
    function afterInvariant() public view {
        console.log("posts", handler.posts(), "settles", handler.settles());
        console.log("claimed", handler.claimed(), "forfeited to pools", handler.toPools());
        console.log("keeper paid", handler.keeperPaid(), "admitted hooks", handler.admittedCount());
        console.log("bounded posts", handler.boundedPosts(), "standing readings", handler.standingReadings());
    }

    /// @dev Pin the LP-pull path so a campaign with no observable notes cannot provide its only coverage.
    function testHandlerPulledPoolDistinguishesWrongFromMissingObservations() public {
        handler.post(0, false, true, 12_000, 1, 1 ether, true);
        handler.post(1, false, false, 8_000, 1, 1 ether, true);
        assertEq(handler.posts(), 2);
        handler.observe(0, 0, true);
        handler.observeSeries(0);
        handler.observe(1, 30 minutes, false);
        // The second call has only one reading, so it refunds for insufficient data, independently of LP state.
        handler.settle(0);
        handler.settle(1);
        assertTrue(annex.noteOf(handler.ids(0)).status == T.Status.Wrong);
        assertTrue(annex.noteOf(handler.ids(1)).status == T.Status.VoidNoData);
        assertEq(handler.keeperPaid(), 0.1 ether);
        assertEq(handler.toPools(), 0.9 ether);
        assertGe(handler.standingReadings(), 4);
        handler.claim(1);
        assertEq(handler.claimed(), 1 ether);
        handler.pullOrRefillVenue(true);
        invariant_imdHeldEqualsBondsOwed();
        invariant_bondsConserved();
        invariant_noMargRetained();
        invariant_statusesAreFinalAndDepositsMatch();
        invariant_recordsCountOutcomes();
    }

    function testHandlerStandingPricesCanReturnARightBond() public {
        handler.post(0, false, true, 12_000, 1, 10 ether, true);
        assertEq(handler.posts(), 1);
        handler.pullOrRefillVenue(false);
        handler.pushEmptyPrice(3000); // X at about 1.35 IMD, above the +20% target
        handler.observeSeries(0);
        assertEq(handler.standingReadings(), 3);
        handler.settle(0);
        assertTrue(annex.noteOf(handler.ids(0)).status == T.Status.Right);
        handler.claim(0);
        assertEq(handler.claimed(), 10 ether);
        assertEq(handler.keeperPaid(), 0);
        assertEq(handler.toPools(), 0);
        invariant_imdHeldEqualsBondsOwed();
        invariant_bondsConserved();
        invariant_statusesAreFinalAndDepositsMatch();
        invariant_recordsCountOutcomes();
    }

    /// @dev What the annex holds is exactly what it still owes: every open, right or no-data bond, nothing else.
    function invariant_imdHeldEqualsBondsOwed() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            owed += annex.noteOf(handler.ids(i)).deposit;
        }
        assertEq(imd.balanceOf(address(annex)), owed, "IMD held != deposits recorded");
        assertEq(owed, handler.outstandingSum(), "deposits recorded != ledger");
        assertEq(_claims(address(annex), address(imd)), 0, "the annex never keeps IMD claims");
    }

    /// @dev Every bond in is accounted for once: still held, returned, paid to a settler, or in the hook's pools.
    function invariant_bondsConserved() public view {
        assertEq(
            handler.bondsIn(),
            handler.outstandingSum() + handler.claimed() + handler.keeperPaid() + handler.toPools(),
            "bonds in != held + claimed + keeper + pools"
        );
        assertEq(imd.balanceOf(handler.keeper()), handler.keeperPaid(), "the keeper holds exactly its cuts");
        // the hook's pool claims also grow with its own quiet-swap fees, so forfeits are matched per call in
        // the handler; here they can only have added to the pools
        assertGe(
            _claims(address(hook), address(imd)) - handler.hookPoolsAtStart(),
            handler.toPools(),
            "the hook's pools grew by at least the forfeits"
        );
    }

    /// @dev The MARG bought on a post never stays: the author's share goes out, the stamp's share burns.
    function invariant_noMargRetained() public view {
        assertEq(token.balanceOf(address(annex)), 0);
        assertEq(_claims(address(annex), address(token)), 0);
    }

    /// @dev A closed note never reopens, and its deposit matches its status.
    function invariant_statusesAreFinalAndDepositsMatch() public view {
        for (uint256 i = 0; i < handler.idCount(); ++i) {
            bytes32 id = handler.ids(i);
            (address author, uint256 original, uint256 outstanding, T.Status status,) = handler.bonds(id);
            T.NoteView memory n = annex.noteOf(id);
            assertEq(n.author, author);
            assertTrue(n.status == status, "a status moved without the ledger seeing it");
            assertEq(n.deposit, outstanding);
            if (status == T.Status.Open) assertEq(outstanding, original);
            if (status == T.Status.Wrong || status == T.Status.VoidSold || status == T.Status.Retracted) {
                assertEq(outstanding, 0);
            }
            assertTrue(status != T.Status.ThesisOpen && status != T.Status.ThesisClosed, "no theses here");
        }
    }

    /// @dev Records count what happened, once each, and no-data settlements move no counter.
    function invariant_recordsCountOutcomes() public view {
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            (, uint32 posted, uint32 right, uint32 wrong, uint32 broken, uint32 retracted) =
                annex.records(actors[i]);
            assertEq(posted, handler.postedBy(actors[i]));
            assertEq(right, handler.rightBy(actors[i]));
            assertEq(wrong, handler.wrongBy(actors[i]));
            assertEq(broken, handler.brokenBy(actors[i]));
            assertEq(retracted, handler.retractedBy(actors[i]));
            assertLe(right + wrong + broken + retracted + handler.noDataBy(actors[i]), posted);
        }
        assertEq(annex.noteCount(), handler.idCount());
    }

    /// @dev Admission is permanent.
    function invariant_admissionIsPermanent() public view {
        for (uint256 i = 0; i < handler.admittedCount(); ++i) {
            assertTrue(annex.admittedHook(handler.admitted(i)));
            assertTrue(annex.hookAllowed(handler.admitted(i)));
        }
    }
}
