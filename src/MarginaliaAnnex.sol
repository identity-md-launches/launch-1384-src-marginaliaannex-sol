// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Lock} from "v4-core/src/libraries/Lock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";
import {MarginaliaPricer} from "./MarginaliaPricer.sol";
import {MarginaliaImpls} from "./MarginaliaImpls.sol";
import {HookFlags} from "./HookFlags.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";

interface IMarginaliaHookAnnex {
    function poolManager() external view returns (IPoolManager);
    function getPoolKey() external view returns (PoolKey memory);
    function imd() external view returns (address);
    function token() external view returns (address);
    function fundPot(uint256 amount) external;
    function noteOf(bytes32 id) external view returns (T.NoteView memory);
}

/// @notice The Annex: Marginalia calls on the Uniswap v4 pools the hook's router cannot accept. The router's
/// venue rule admits a v4 pool only when its hook is none or ours; nearly every token launched on IMD trades
/// in a pool with a hook (the launch factory's initialization guard, or a project's own), so those calls had
/// nowhere to go. This contract records the same call (side, target, horizon, bond, hold rule, permissionless
/// observations, the hook's settlement rule through the same stateless pricer) on any v4 pool quoted in IMD or
/// ETH whose hook either cannot touch a swap at all (read from the hook's address bits, so nothing to trust)
/// or has been admitted as open by the IMD oracle panel, which anyone can ask. The hook's economics with one
/// change: one 0.35 IMD swap on the launch pool buys MARG, of which the 0.25 IMD share goes to the author and
/// the 0.1 IMD stamp's share is burned (on the hook the stamp funds the pools); the bond is held here as IMD
/// and returned on RIGHT; forfeits go to the hook's pools, 10% to the settler. Its record is its own; a site
/// shows one record per wallet across both contracts. Theses and seals stay on the hook. No owner, no pause,
/// no upgrade.
contract MarginaliaAnnex is IUnlockCallback, ReentrancyGuard, OracleAttestationConsumer {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ constants (the hook's)

    uint256 public constant STAMP = 0.1 ether;
    uint256 public constant MARG_BUY = 0.25 ether;
    uint256 public constant BOND_MIN = 0.25 ether;
    uint256 public constant BOND_MAX = 10 ether;
    uint32 public constant MIN_TARGET_DELTA_BPS = 1000;
    uint16 public constant MAX_HORIZON_DAYS = 90;
    uint256 public constant TEXT_MAX = 280;
    uint256 public constant SETTLE_WINDOW = 6 hours;
    uint256 public constant OBS_MIN = 3;
    uint256 public constant OBS_MAX = 16;
    uint256 public constant OBS_GAP_BLOCKS = 20;
    uint256 public constant OBS_MIN_SPAN = 1 hours;
    uint256 public constant KEEPER_BPS = 1000;
    uint256 public constant BALANCE_READ_GAS = 100_000;
    /// @dev The most an admission question may cost, and the most hooks one question may name: the Intake
    /// delivers the answer under a 200k gas stipend, and each admission is a storage write.
    uint256 public constant MAX_PRICE = 1 ether;
    uint256 public constant MAX_ADMISSION_LIST = 4;
    uint16 public constant PANEL_SIZE = 5;
    uint16 public constant QUORUM = 4;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev A hook holding any of these permissions can act on a swap; one holding none of them cannot.
    uint160 public constant SWAP_FLAGS = HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    IMarginaliaHookAnnex public immutable hook;
    IIntake public immutable intake;
    bytes32 public immutable action;

    // ------------------------------------------------------------------ storage

    struct Record {
        int256 score;
        uint32 posted;
        uint32 right;
        uint32 wrong;
        uint32 broken;
        uint32 retracted;
    }

    uint256 public noteCount;
    mapping(bytes32 => T.Note) private notes;
    mapping(bytes32 => T.Observation[]) private observations;
    mapping(address => Record) public records;
    mapping(bytes32 => T.PriceWindow) public priceWindows;
    /// @dev v4 hooks the oracle panel admitted as open. Hooks without swap permissions need no entry.
    mapping(address => bool) public admittedHook;
    mapping(bytes32 => address[]) private admissionLists; // requestId → the hooks asked about

    // ------------------------------------------------------------------ errors / events

    error InvalidNote();
    error BadVenue();
    error NotOpen();
    error TooEarly();
    error TooLate();
    error ObservationTooSoon();
    error Unauthorized();
    error NothingToClaim();
    error Expired();
    error Slippage();
    error UnauthorizedCallback();
    error OnlyIntake();
    error BadAnswer();
    error BadList();
    error Unlocked();

    event NotePosted(
        bytes32 indexed id,
        address indexed author,
        address indexed x,
        uint8 class,
        T.Side side,
        uint32 targetBps,
        uint16 horizonDays,
        bytes32 parentId,
        string text
    );
    event Observed(bytes32 indexed id, uint256 xRead, uint256 balance);
    event Settled(
        bytes32 indexed id, T.Status status, uint256 settlePrice, int256 scoreDelta, address keeper
    );
    event Retracted(bytes32 indexed id, string text);
    event DepositClaimed(bytes32 indexed id, address indexed to, uint256 amount);
    event Burned(uint256 imdIn, uint256 marg);
    event VenueCheckpointed(bytes32 indexed venueId, uint64 startedAt);
    event AdmissionRequested(
        bytes32 indexed requestId, address indexed asker, address[] hooks, uint256 price
    );
    event HookAdmitted(address indexed hooks, bytes32 indexed requestId);

    /// @dev Reads no chain state: the launcher rehearses constructors in an empty EVM.
    constructor(IMarginaliaHookAnnex hook_, IIntake intake_, bytes32 action_, address signer_)
        OracleAttestationConsumer(signer_)
    {
        if (address(hook_) == address(0) || address(intake_) == address(0) || action_ == bytes32(0)) {
            revert InvalidNote();
        }
        hook = hook_;
        intake = intake_;
        action = action_;
    }

    function pricer() public pure returns (MarginaliaPricer) {
        return MarginaliaPricer(MarginaliaImpls.PRICER);
    }

    // ------------------------------------------------------------------ venues

    /// @notice Whether a v4 hook can touch a swap at all, read from its address bits.
    function hookCanTouchSwaps(address hooks) public pure returns (bool) {
        return uint160(hooks) & SWAP_FLAGS != 0;
    }

    /// @notice Whether this contract accepts a pool's hook: none, the Marginalia hook, one with no swap
    /// permission, or one the oracle panel admitted.
    function hookAllowed(address hooks) public view returns (bool) {
        return
            hooks == address(0) || hooks == address(hook) || !hookCanTouchSwaps(hooks) || admittedHook[hooks];
    }

    /// @notice The whole hook rule for one pool: `hookAllowed` plus the dynamic-fee exception. On a pool whose
    /// `fee` is the dynamic flag the hook sets the LP fee with no permission bit, so only the Marginalia hook or
    /// an admitted one passes there. This is the predicate `validateVenue` applies.
    function hookAllowedFor(address hooks, uint24 fee) public view returns (bool) {
        if (!hookAllowed(hooks)) return false;
        return fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || hooks == address(hook) || admittedHook[hooks];
    }

    /// @notice The venue check: a live v4 pool, allowed hook, X on one side, IMD / WETH / ETH on the other.
    /// Fills `xIsToken0` and `quote` from the key, as the router does. A DYNAMIC-fee pool passes only with our
    /// hook or an admitted one: its hook sets the LP fee with no permission bit at all, and a 100% exact-input
    /// fee freezes the price, so "no swap bits" proves nothing there.
    function validateVenue(T.NoteParams memory p, PoolKey memory key) public view returns (T.Venue memory v) {
        v = p.venue;
        address imd = hook.imd();
        if (p.x == address(0) || p.x == imd || p.x.code.length == 0) revert InvalidNote();
        if (v.kind != T.VenueKind.UniV4 || PoolId.unwrap(key.toId()) != v.ref) revert BadVenue();
        if (!hookAllowedFor(address(key.hooks), key.fee)) revert BadVenue();
        if (hook.poolManager().getLiquidity(PoolId.wrap(v.ref)) == 0) revert BadVenue();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (p.x == t0) {
            v.xIsToken0 = true;
            v.quote = t1;
        } else if (p.x == t1) {
            v.xIsToken0 = false;
            v.quote = t0;
        } else {
            revert BadVenue();
        }
        if (v.quote != imd && v.quote != WETH && v.quote != address(0)) revert BadVenue();
    }

    function venueId(T.Venue memory v) public pure returns (bytes32) {
        return keccak256(abi.encode(v));
    }

    /// @notice Anyone begins or extends a venue's price history. The first checkpoint must age for an hour;
    /// windows expire after six hours and cannot be reset while live.
    function checkpointVenue(T.NoteParams memory p, PoolKey memory key) external nonReentrant {
        T.Venue memory v = validateVenue(p, key);
        bytes32 id = venueId(v);
        T.PriceWindow memory w = pricer().checkpoint(_lockedManager(), v, hook.imd(), priceWindows[id]);
        priceWindows[id] = w;
        emit VenueCheckpointed(id, w.startedAt);
    }

    /// @notice The baseline a post would get now from this contract's own windows.
    function postPrice(T.Venue memory v, bool buy) public view returns (uint256) {
        return pricer().postPrice(hook.poolManager(), v, hook.imd(), buy, priceWindows[venueId(v)]);
    }

    // ------------------------------------------------------------------ posting

    /// @notice Post a call: `bond` IMD (0.25 to 10) plus the stamp and the MARG purchase are pulled from the
    /// author; one swap buys MARG with both, the purchase's share goes to the author and the stamp's share is
    /// burned, the bond stays here. `minMargOut` bounds the author's share. `p.venue` is the derived venue as
    /// `validateVenue` returns it (a site computes it the same way). `baselineBound` bounds the baseline the
    /// call is judged against, as `minMargOut` bounds the MARG leg: the most a BUY call's post price may be,
    /// the least a SELL call's may be (IMD per 1e18 of X; 0 = no bound). The baseline folds in this block's
    /// spot, so a pump landed just before the post would otherwise be recorded as the price to beat.
    function post(
        T.NoteParams calldata p,
        PoolKey calldata v4Key,
        uint256 bond,
        uint256 minMargOut,
        uint256 baselineBound,
        uint256 deadline
    ) external nonReentrant returns (bytes32 id) {
        if (block.timestamp > deadline) revert Expired();
        if (bond < BOND_MIN || bond > BOND_MAX) revert InvalidNote();
        if (p.targetBps == 0 || p.horizonDays == 0 || p.horizonDays > MAX_HORIZON_DAYS) revert InvalidNote();
        uint256 textLen = bytes(p.text).length;
        if (textLen == 0 || textLen > TEXT_MAX) revert InvalidNote();
        if (p.side == T.Side.Buy) {
            if (p.targetBps < 10_000 + MIN_TARGET_DELTA_BPS) revert InvalidNote();
        } else if (p.targetBps > 10_000 - MIN_TARGET_DELTA_BPS) {
            revert InvalidNote();
        }
        T.Venue memory v = validateVenue(p, v4Key);
        address author = msg.sender;
        IERC20(hook.imd()).safeTransferFrom(author, address(this), STAMP + MARG_BUY + bond);
        _buyMarg(STAMP + MARG_BUY, MARG_BUY, minMargOut, author);

        id = keccak256(abi.encode(address(this), ++noteCount));
        T.Note storage n = notes[id];
        n.author = author;
        n.x = p.x;
        n.venue = v;
        n.side = p.side;
        n.targetBps = p.targetBps;
        n.horizonDays = p.horizonDays;
        n.class = author.code.length > 0 ? uint8(T.Class.Agent) : uint8(T.Class.Declared);
        n.status = T.Status.Open;
        n.postedAt = uint64(block.timestamp);
        n.day = uint32(block.timestamp / 1 days);
        n.deposit = bond;
        n.parentId = p.parentId;
        // read AFTER the purchase: the author already holds the MARG (the hook adds it because it records inside
        // afterSwap, before the router's take; here the take has happened)
        n.postBalance = _balanceOf(p.x, author);
        // a BUY call whose balance cannot be read could only settle VoidSold: refused at post, as on the hook
        if (p.side == T.Side.Buy && n.postBalance == type(uint256).max) revert InvalidNote();
        n.postPrice = postPrice(v, p.side == T.Side.Buy);
        if (n.postPrice == 0) revert InvalidNote();
        if (
            baselineBound != 0
                && (p.side == T.Side.Buy ? n.postPrice > baselineBound : n.postPrice < baselineBound)
        ) revert Slippage();

        if (p.parentId != bytes32(0)) _checkCounter(p, author);
        records[author].posted += 1;
        emit NotePosted(id, author, p.x, n.class, p.side, p.targetBps, p.horizonDays, p.parentId, p.text);
    }

    /// @dev A counter argues against another author's open call on the same X from the other side. The target
    /// may live here or on the hook (read-only there). Deposits never change hands between them.
    function _checkCounter(T.NoteParams calldata p, address author) private view {
        T.Note storage t = notes[p.parentId];
        if (t.author != address(0)) {
            if (t.author == author || t.status != T.Status.Open || t.x != p.x || t.side == p.side) {
                revert InvalidNote();
            }
            return;
        }
        try hook.noteOf(p.parentId) returns (T.NoteView memory h) {
            if (h.author == author || h.status != T.Status.Open || h.x != p.x || h.side == p.side) {
                revert InvalidNote();
            }
        } catch {
            revert InvalidNote(); // unknown to both contracts
        }
    }

    // ------------------------------------------------------------------ observations and settlement (the hook's)

    function horizonEnd(bytes32 id) public view returns (uint256) {
        T.Note storage n = _note(id);
        return uint256(n.postedAt) + uint256(n.horizonDays) * 1 days;
    }

    /// @notice Anyone records a reading in the settlement window. Refused while the PoolManager is unlocked,
    /// so a reading cannot be taken between two swaps of one transaction (dump, observe, rebuy): a price has
    /// to be left standing for the next transaction to be read. A venue whose in-range liquidity has been
    /// pulled since the post has no price; that is recorded as a reading too (`xRead == 0`), adverse to the
    /// call, so emptying the pool for the window cannot turn a forfeit into a refund.
    function observe(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp < end) revert TooEarly();
        if (block.timestamp > end + SETTLE_WINDOW) revert TooLate();
        T.Observation[] storage obs = observations[id];
        IPoolManager manager = _lockedManager();
        uint256 xRead;
        uint256 quoteRead;
        if (manager.getLiquidity(PoolId.wrap(n.venue.ref)) != 0) {
            (xRead, quoteRead) = pricer().observe(manager, n.venue, hook.imd());
        }
        uint256 balance = _balanceOf(n.x, n.author);
        T.Observation memory o =
            T.Observation(uint64(block.timestamp), uint64(block.number), xRead, quoteRead, balance);
        uint256 len = obs.length;
        if (
            len > 0
                && (len >= OBS_MAX
                    || block.number < obs[len - 1].blockNumber + OBS_GAP_BLOCKS
                    || (len == OBS_MAX - 1 && block.timestamp < uint256(obs[0].timestamp) + OBS_MIN_SPAN))
        ) {
            if (!_moreAdverse(n, o, obs[len - 1])) revert ObservationTooSoon();
            o.blockNumber = obs[len - 1].blockNumber;
            obs[len - 1] = o;
        } else {
            obs.push(o);
        }
        emit Observed(id, xRead, balance);
    }

    function settle(bytes32 id) external nonReentrant {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp <= end + SETTLE_WINDOW) revert TooEarly();
        T.Observation[] memory obs = observations[id];
        uint256 count = obs.length;
        T.Status outcome;
        uint256 settlePrice;
        if (count < OBS_MIN || obs[count - 1].timestamp - obs[0].timestamp < OBS_MIN_SPAN) {
            outcome = T.Status.VoidNoData;
        } else {
            bool held = true;
            bool emptied; // a reading with no in-range liquidity: no price, adverse to either side
            for (uint256 i = 0; i < count; ++i) {
                if (_broken(n, obs[i].balance)) held = false;
                if (obs[i].xRead == 0) emptied = true;
            }
            if (!emptied) settlePrice = _settlementPrice(n, obs);
            if (settlePrice == 0 && !emptied) {
                outcome = T.Status.VoidNoData;
            } else if (!held) {
                outcome = T.Status.VoidSold;
            } else if (emptied) {
                outcome = T.Status.Wrong;
            } else if (n.side == T.Side.Buy) {
                outcome = settlePrice * 10_000 >= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            } else {
                outcome = settlePrice * 10_000 <= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            }
        }
        n.status = outcome;
        uint256 diff = _difficulty(n);
        int256 scoreDelta = -int256(diff);
        Record storage r = records[n.author];
        if (outcome == T.Status.Right) {
            scoreDelta = int256(diff);
            r.right += 1;
        } else if (outcome == T.Status.Wrong) {
            r.wrong += 1;
            _forfeit(n, msg.sender);
        } else if (outcome == T.Status.VoidSold) {
            r.broken += 1;
            _forfeit(n, msg.sender);
        }
        r.score += scoreDelta;
        emit Settled(id, outcome, settlePrice, scoreDelta, msg.sender);
    }

    function retract(bytes32 id, string calldata text) external nonReentrant {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.status != T.Status.Open) revert NotOpen();
        if (block.timestamp >= horizonEnd(id)) revert TooLate();
        n.status = T.Status.Retracted;
        int256 scoreDelta = -int256(_difficulty(n) / 2);
        Record storage r = records[n.author];
        r.retracted += 1;
        r.score += scoreDelta;
        _forfeit(n, address(0));
        emit Retracted(id, text);
        emit Settled(id, T.Status.Retracted, 0, scoreDelta, address(0));
    }

    /// @notice A right (or no-data) bond, returned in IMD.
    function claimDeposit(bytes32 id) external nonReentrant {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.status != T.Status.Right && n.status != T.Status.VoidNoData) revert NothingToClaim();
        uint256 amount = n.deposit;
        if (amount == 0) revert NothingToClaim();
        n.deposit = 0;
        IERC20(hook.imd()).safeTransfer(n.author, amount);
        emit DepositClaimed(id, n.author, amount);
    }

    function _forfeit(T.Note storage n, address keeper) private {
        uint256 amount = n.deposit;
        n.deposit = 0;
        if (amount == 0) return;
        uint256 reward = keeper == address(0) ? 0 : amount * KEEPER_BPS / 10_000;
        if (reward > 0) IERC20(hook.imd()).safeTransfer(keeper, reward);
        _toPools(amount - reward);
    }

    function _toPools(uint256 amount) private {
        IERC20(hook.imd()).forceApprove(address(hook), amount);
        hook.fundPot(amount);
    }

    /// @dev v4 venues are spot-read: the pricer prices each observation alone and the most adverse one settles.
    function _settlementPrice(T.Note storage n, T.Observation[] memory obs)
        private
        view
        returns (uint256 price)
    {
        bool buy = n.side == T.Side.Buy;
        T.Observation[] memory sample = new T.Observation[](1);
        for (uint256 i; i < obs.length; ++i) {
            sample[0] = obs[i];
            try pricer().settlePrice(n.venue, buy, sample) returns (uint256 p) {
                if (p == 0) return 0;
                if (i == 0 || (buy ? p < price : p > price)) price = p;
            } catch {
                return 0;
            }
        }
    }

    function _moreAdverse(T.Note storage n, T.Observation memory o, T.Observation memory last)
        private
        view
        returns (bool)
    {
        bool brokenNew = _broken(n, o.balance);
        bool brokenLast = _broken(n, last.balance);
        if (brokenLast && !brokenNew) return false;
        if (brokenNew && !brokenLast) return true;
        if (last.xRead == 0) return false; // nothing is more adverse than no price
        if (o.xRead == 0) return true;
        uint256 pn = FullMath.mulDiv(o.xRead, o.quoteRead, 1e18);
        uint256 pl = FullMath.mulDiv(last.xRead, last.quoteRead, 1e18);
        return n.side == T.Side.Buy ? pn < pl : pn > pl;
    }

    function _broken(T.Note storage n, uint256 balance) private view returns (bool) {
        if (n.side == T.Side.Sell) return false;
        return balance == type(uint256).max || balance < n.postBalance;
    }

    function _balanceOf(address x, address who) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            x.staticcall{gas: BALANCE_READ_GAS}(abi.encodeWithSelector(IERC20.balanceOf.selector, who));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    function _difficulty(T.Note storage n) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            n.x.staticcall{gas: BALANCE_READ_GAS}(abi.encodeWithSelector(IERC20.totalSupply.selector));
        uint256 supply = ok && ret.length >= 32 ? abi.decode(ret, (uint256)) : 0;
        uint256 mcap = supply <= type(uint256).max / n.postPrice ? n.postPrice * supply / 1e18 : 0;
        return pricer().difficulty(n.targetBps, n.side == T.Side.Buy, n.horizonDays, mcap);
    }

    function _note(bytes32 id) private view returns (T.Note storage n) {
        n = notes[id];
        if (n.author == address(0)) revert NotOpen();
    }

    /// @dev The hook's PoolManager, required to be locked: no price is read from inside anyone's unlock.
    function _lockedManager() private view returns (IPoolManager manager) {
        manager = hook.poolManager();
        if (manager.exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0)) revert Unlocked();
    }

    // ------------------------------------------------------------------ reads

    /// @notice A note, or `NotOpen` for an id this contract never issued (as the hook reverts on one).
    function noteOf(bytes32 id) external view returns (T.NoteView memory v) {
        T.Note storage n = _note(id);
        v = T.NoteView(
            n.author,
            n.x,
            n.side,
            n.targetBps,
            n.horizonDays,
            n.class,
            n.status,
            n.postPrice,
            n.postBalance,
            n.deposit,
            n.parentId,
            n.children
        );
    }

    function venueOf(bytes32 id) external view returns (T.Venue memory) {
        return notes[id].venue;
    }

    function observationsOf(bytes32 id) external view returns (T.Observation[] memory) {
        return observations[id];
    }

    // ------------------------------------------------------------------ oracle admission of v4 hooks

    /// @notice The oracle body for an admission question: deterministic from the list, so anyone can check it.
    /// The question asks for the hooks that leave the pool OPEN: any caller can swap, and nothing but the swaps
    /// and liquidity changes open to everyone can move the pool's price. A fixed fee taken from every trader
    /// alike is not a reason to refuse a hook; an allowlist, a pause, an owner-set fee or price, or an upgrade
    /// path is (an admission is permanent, so what the owner could do tomorrow counts).
    function admissionBody(address[] memory hooks) public view returns (string memory) {
        bytes memory list; // quoted, for guards.allow
        bytes memory named; // bare, for the question: a quote inside a JSON string value breaks the body
        for (uint256 i = 0; i < hooks.length; ++i) {
            bytes memory h = bytes(Strings.toHexString(hooks[i]));
            list = bytes.concat(list, i == 0 ? bytes('"') : bytes(',"'), h, bytes('"'));
            named = bytes.concat(named, i == 0 ? bytes("") : bytes(", "), h);
        }
        bytes memory chain = bytes(Strings.toString(block.chainid));
        return string(
            bytes.concat(
                bytes(
                    '{"v":1,"question":"Each address is a Uniswap v4 hook on this chain with verified source. Answer with the subset that keeps its pools OPEN: any caller may swap (no allowlist, selective refusal or selective pause) and the pool price moves only through swaps and liquidity changes any caller may make (no owner-set price, no privileged swap path). A fixed fee or tax charged to every trader alike does not exclude a hook; a hook whose owner can change the fee at will, pause swaps for everyone, or that is upgradeable, is NOT open. Read the source; never infer from names. Hooks: '
                ),
                named,
                bytes('","chainId":'),
                chain,
                bytes(',"window":{"hours":24},"answerType":"address[]","evidence":"panel","head":'),
                bytes(Strings.toString(hooks.length)),
                bytes(',"panelSize":'),
                bytes(Strings.toString(PANEL_SIZE)),
                bytes(',"quorum":'),
                bytes(Strings.toString(QUORUM)),
                bytes(',"validForSeconds":86400,"guards":{"allow":['),
                list,
                bytes('],"mustHaveCode":true},"consumer":{"chainId":'),
                chain,
                bytes(',"verifyingContract":"'),
                bytes(Strings.toHexString(address(this))),
                bytes('"}}')
            )
        );
    }

    /// @notice Anyone pays the Intake's price to ask the panel which of up to MAX_ADMISSION_LIST hooks keep
    /// their pools open. The signed answer admits each listed hook the panel named; nothing else changes.
    function requestAdmission(address[] calldata hooks) external nonReentrant returns (bytes32 requestId) {
        if (hooks.length == 0 || hooks.length > MAX_ADMISSION_LIST) revert BadList();
        for (uint256 i = 0; i < hooks.length; ++i) {
            if (hooks[i] == address(0) || hooks[i].code.length == 0) revert BadList();
        }
        address imd = hook.imd();
        uint256 price = intake.priceOf(action, imd);
        if (price == 0 || price > MAX_PRICE) revert BadList();
        IERC20(imd).safeTransferFrom(msg.sender, address(this), price);
        IERC20(imd).forceApprove(address(intake), price);
        requestId = intake.request(
            action,
            bytes(admissionBody(hooks)),
            IIntake.Callback(address(this), this.onOracleResult.selector),
            imd,
            price
        );
        IERC20(imd).forceApprove(address(intake), 0);
        if (requestId == bytes32(0) || admissionLists[requestId].length != 0) revert BadList();
        admissionLists[requestId] = hooks;
        emit AdmissionRequested(requestId, msg.sender, hooks, price);
    }

    function onOracleResult(
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external nonReentrant {
        if (msg.sender != address(intake)) revert OnlyIntake();
        address[] memory asked = admissionLists[requestId];
        if (asked.length == 0) revert BadList();
        _verifyAttestation(a, signature);
        if (
            a.chainId != block.chainid || a.agreed < a.quorum || a.quorum < QUORUM || a.panelSize < PANEL_SIZE
        ) {
            revert BadAnswer();
        }
        address[] memory open = decodeAddressList(a);
        _consume(a.requestId);
        delete admissionLists[requestId];
        for (uint256 i = 0; i < open.length; ++i) {
            for (uint256 k = 0; k < asked.length; ++k) {
                if (asked[k] == open[i] && !admittedHook[open[i]]) {
                    admittedHook[open[i]] = true;
                    emit HookAdmitted(open[i], requestId);
                }
            }
        }
    }

    // ------------------------------------------------------------------ the MARG purchase

    /// @dev One quiet buy of `imdIn` IMD on the launch pool: the `authorIn` share of the MARG goes to `to`,
    /// the rest is burned. Returns the author's share.
    function _buyMarg(uint256 imdIn, uint256 authorIn, uint256 minOut, address to) private returns (uint256) {
        bytes memory ret = hook.poolManager().unlock(abi.encode(imdIn, authorIn, minOut, to));
        return abi.decode(ret, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager manager = hook.poolManager();
        if (msg.sender != address(manager)) revert UnauthorizedCallback();
        (uint256 imdIn, uint256 authorIn, uint256 minOut, address to) =
            abi.decode(data, (uint256, uint256, uint256, address));
        PoolKey memory key = hook.getPoolKey();
        address imd = hook.imd();
        bool zeroForOne = Currency.unwrap(key.currency0) == imd;
        BalanceDelta d = manager.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(imdIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 inD = zeroForOne ? d.amount0() : d.amount1();
        int128 outD = zeroForOne ? d.amount1() : d.amount0();
        if (inD >= 0 || outD <= 0 || uint256(uint128(-inD)) != imdIn) revert UnauthorizedCallback();
        uint256 marg = uint256(uint128(outD));
        uint256 authorMarg = marg * authorIn / imdIn;
        if (authorMarg < minOut) revert Slippage();
        Currency pay = zeroForOne ? key.currency0 : key.currency1;
        Currency recv = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(pay);
        IERC20(imd).safeTransfer(address(manager), imdIn);
        manager.settle();
        if (authorMarg > 0) manager.take(recv, to, authorMarg);
        if (marg > authorMarg) {
            manager.take(recv, DEAD, marg - authorMarg);
            emit Burned(imdIn - authorIn, marg - authorMarg);
        }
        return abi.encode(authorMarg);
    }
}
