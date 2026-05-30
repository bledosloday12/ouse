// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ouse — codename quartz vane
/// @notice On-chain desk for AI trade bots: signal ticks, intent slots, backtest leaves, and risk envelopes.
/// @dev Registry-only orchestration; no external swap calls. Stray wei rejected except explicit tip paths.

library OuseTickMath {
    function clampBps(uint32 value, uint32 ceiling) internal pure returns (uint32) {
        if (value > ceiling) return ceiling;
        return value;
    }

    function blendSignal(bytes32 prior, bytes32 tick, uint32 confidence) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prior, tick, confidence));
    }

    function intentDigest(
        uint64 deskId,
        address agent,
        bytes32 pairHash,
        uint8 side,
        uint256 notionalCap,
        uint64 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(deskId, agent, pairHash, side, notionalCap, nonce));
    }

    function streakNext(uint32 current, uint32 cap) internal pure returns (uint32) {
        if (current >= cap) return cap;
        return current + 1;
    }
}

contract OuseNeuralTickDesk {
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    bytes32 private constant OUSE_DOMAIN_SALT = keccak256("OuseNeuralTickDesk.quartz_vane");
    bytes16 private constant OUSE_SEED = 0x6418a9a01188987f8aabff10bcfc7dad;
    uint64 public constant OUSE_BUILD_TAG = 0x777ac44b4bca7766;
    uint32 public constant OUSE_BUILD_STAMP = 1432446391;

    uint64 public constant MAX_DESK_ID = 1_203_847;
    uint32 public constant MAX_CONFIDENCE_BPS = 9_412;
    uint32 public constant MAX_DRAWNDOWN_BPS = 6_731;
    uint32 public constant MAX_POSITION_BPS = 8_904;
    uint32 public constant MAX_COOLDOWN_SEC = 97_331;
    uint32 public constant MAX_SIGNAL_BYTES = 512;
    uint32 public constant MAX_BATCH = 48;
    uint32 public constant STREAK_CAP = 117;
    uint256 public constant MIN_INTENT_TIP_WEI = 317;
    uint256 public constant BACKTEST_FEE_WEI = 1_847;
    uint8 public constant SIDE_BID = 1;
    uint8 public constant SIDE_ASK = 2;

    struct Desk {
        bytes32 modelRoot;
        bytes32 venueTag;
        bool open;
        bool sealed;
        uint64 openedAt;
        uint64 closesAt;
        uint32 signalCount;
        uint32 agentCount;
        uint256 tipPool;
    }

    struct AgentSeat {
        bytes32 personaHash;
        bytes32 policyHash;
        bool active;
        uint64 seatedAt;
        uint32 tickTotal;
        uint32 streak;
    }

    struct SignalTick {
        bytes32 featureHash;
        bytes32 inferenceHash;
        bytes32 blendHash;
        uint32 confidenceBps;
        uint64 postedAt;
    }

    struct IntentSlot {
        bytes32 pairHash;
        bytes32 routeHint;
        address filer;
        uint8 side;
        bool open;
        bool settled;
        uint256 notionalCap;
        uint64 filedAt;
        uint64 nonce;
    }

    struct BacktestLeaf {
        bytes32 reportHash;
        bytes32 benchmarkHash;
        address author;
        uint64 deskId;
        uint64 storedAt;
        bool revoked;
    }

    struct RiskEnvelope {
        uint32 maxDrawdownBps;
        uint32 maxPositionBps;
        uint32 cooldownSec;
        bool locked;
    }

    address public director;
    bool public deskFrozen;

    uint64 public genesisNonce;
    uint64 public deployChainId;
    uint64 public lastDeskId;
    uint256 public globalTickCount;
    uint256 public globalIntentCount;
    uint256 public backtestSeq;

    mapping(uint64 => Desk) private _desks;
    mapping(uint64 => mapping(address => AgentSeat)) private _seats;
    mapping(uint64 => mapping(address => bool)) private _isSeated;
    mapping(uint64 => mapping(address => SignalTick)) private _lastTick;
    mapping(uint64 => mapping(address => uint32)) private _agentStreak;
    mapping(uint64 => mapping(address => uint64)) private _intentNonce;
    mapping(uint64 => mapping(uint64 => IntentSlot)) private _intents;
    mapping(uint64 => RiskEnvelope) private _risk;
    mapping(uint256 => BacktestLeaf) private _backtests;
    mapping(bytes32 => bool) private _usedReport;

    uint256 private _guard = 1;


    error OUSE_NotDirector(address caller);
    error OUSE_DeskFrozen();
    error OUSE_DeskUnknown(uint64 deskId);
    error OUSE_DeskAlreadyOpen(uint64 deskId);
    error OUSE_DeskClosed(uint64 deskId);
    error OUSE_DeskSealed(uint64 deskId);
    error OUSE_DeskIdOutOfRange(uint64 deskId);
    error OUSE_ModelRootZero();
    error OUSE_VenueTagZero();
    error OUSE_PersonaZero();
    error OUSE_PolicyZero();
    error OUSE_FeatureZero();
    error OUSE_InferenceZero();
    error OUSE_AlreadySeated(uint64 deskId, address agent);
    error OUSE_NotSeated(uint64 deskId, address agent);
    error OUSE_SignalTooLong(uint256 len, uint256 maxLen);
    error OUSE_ConfidenceTooHigh(uint32 bps, uint32 maxBps);
    error OUSE_IntentTipTooSmall(uint256 sent, uint256 minWei);
    error OUSE_BacktestFeeShort(uint256 sent, uint256 required);
    error OUSE_ReportReplay(bytes32 reportHash);
    error OUSE_IntentUnknown(uint64 deskId, uint64 intentId);
    error OUSE_IntentClosed(uint64 deskId, uint64 intentId);
    error OUSE_IntentAlreadySettled(uint64 deskId, uint64 intentId);
    error OUSE_PairHashZero();
    error OUSE_SideInvalid(uint8 side);
    error OUSE_NotionalZero();
    error OUSE_RiskLocked(uint64 deskId);
    error OUSE_DrawdownTooHigh(uint32 bps, uint32 maxBps);
    error OUSE_PositionTooHigh(uint32 bps, uint32 maxBps);
    error OUSE_CooldownTooLong(uint32 sec, uint32 maxSec);
    error OUSE_BatchTooLarge(uint256 n, uint256 maxN);
    error OUSE_WithdrawZero();
    error OUSE_InsufficientTipPool(uint256 requested, uint256 available);
    error OUSE_TransferFailed();
    error OUSE_WindowInvalid(uint64 windowSec);
    error OUSE_Reentrant();
    error OUSE_StrayWei();
    error OUSE_FallbackBlocked();
    error OUSE_NotAuthorized(address caller);
    error OUSE_BacktestUnknown(uint256 leafId);

    event Booted(uint64 indexed genesisNonce, address indexed director, uint256 chainId, uint64 buildTag);
    event DirectorMoved(address indexed previous, address indexed next);
    event DeskFreezeSet(bool frozen);
    event DeskOpened(uint64 indexed deskId, bytes32 modelRoot, uint64 openedAt, uint64 closesAt);
    event DeskExtended(uint64 indexed deskId, uint64 newClosesAt);
    event DeskSealed(uint64 indexed deskId, uint32 signalCount, uint32 agentCount);
    event AgentSeated(uint64 indexed deskId, address indexed agent, bytes32 personaHash, bytes32 policyHash);
    event AgentVacated(uint64 indexed deskId, address indexed agent);
    event TickPosted(uint64 indexed deskId, address indexed agent, bytes32 inferenceHash, uint32 confidenceBps);
    event IntentFiled(uint64 indexed deskId, uint64 indexed intentId, address indexed filer, uint8 side, uint256 notionalCap);
    event IntentCanceled(uint64 indexed deskId, uint64 indexed intentId);
    event IntentSettled(uint64 indexed deskId, uint64 indexed intentId, bytes32 outcomeHash);
    event BacktestStored(uint256 indexed leafId, uint64 indexed deskId, address indexed author, bytes32 reportHash);
    event BacktestRevoked(uint256 indexed leafId, address indexed director);
    event RiskPinned(uint64 indexed deskId, uint32 maxDrawdownBps, uint32 maxPositionBps, uint32 cooldownSec);
    event RiskUnlocked(uint64 indexed deskId);
    event TipReceived(uint64 indexed deskId, address indexed from, uint256 amountWei, uint256 deskPool);
    event TipsWithdrawn(address indexed director, uint256 amountWei);
    event WeiPing(address indexed from, uint256 amountWei);

    constructor() {
        ADDRESS_A = 0xA508518A3B326f1eb8eE16B3BC08Dc35544bEBDf;
        ADDRESS_B = 0x6Dec6772505d899Fda48867074371A33aE36Fad3;
        ADDRESS_C = 0x982523F4c2C39110bA12d059FdC84E2fa5a8470b;

        deployChainId = uint64(block.chainid);
        director = msg.sender;
        genesisNonce = uint64(
            uint256(keccak256(abi.encodePacked(deployChainId, msg.sender, block.prevrandao, OUSE_SEED))) >> 192
        );

        emit Booted(genesisNonce, msg.sender, block.chainid, OUSE_BUILD_TAG);
    }

    receive() external payable {
        emit WeiPing(msg.sender, msg.value);
        revert OUSE_StrayWei();
    }

    fallback() external payable {
        revert OUSE_FallbackBlocked();
    }

    modifier onlyDirector() {
        if (msg.sender != director) revert OUSE_NotDirector(msg.sender);
        _;
    }

    modifier whenDeskLive() {
        if (deskFrozen) revert OUSE_DeskFrozen();
        _;
    }

    modifier nonReentrant() {
        if (_guard != 1) revert OUSE_Reentrant();
        _guard = 2;
        _;
        _guard = 1;
    }

    function moveDirector(address next) external onlyDirector {
        address prev = director;
        director = next;
        emit DirectorMoved(prev, next);
    }

    function setDeskFrozen(bool frozen) external onlyDirector {
        deskFrozen = frozen;
        emit DeskFreezeSet(frozen);
    }

    function openDesk(uint64 deskId, bytes32 modelRoot, bytes32 venueTag, uint64 windowSec) external onlyDirector whenDeskLive {
        if (deskId > MAX_DESK_ID) revert OUSE_DeskIdOutOfRange(deskId);
        if (modelRoot == bytes32(0)) revert OUSE_ModelRootZero();
        if (venueTag == bytes32(0)) revert OUSE_VenueTagZero();
        if (windowSec == 0 || windowSec > MAX_COOLDOWN_SEC) revert OUSE_WindowInvalid(windowSec);

        Desk storage d = _desks[deskId];
        if (d.openedAt != 0) revert OUSE_DeskAlreadyOpen(deskId);

        uint64 nowTs = uint64(block.timestamp);
        d.modelRoot = modelRoot;
        d.venueTag = venueTag;
        d.open = true;
        d.sealed = false;
        d.openedAt = nowTs;
        d.closesAt = nowTs + windowSec;
        d.signalCount = 0;
        d.agentCount = 0;
        d.tipPool = 0;

        if (deskId > lastDeskId) lastDeskId = deskId;
        emit DeskOpened(deskId, modelRoot, nowTs, d.closesAt);
    }

    function extendDesk(uint64 deskId, uint64 extraSec) external onlyDirector whenDeskLive {
        Desk storage d = _requireOpenDesk(deskId);
        if (extraSec == 0 || extraSec > MAX_COOLDOWN_SEC) revert OUSE_WindowInvalid(extraSec);
        d.closesAt += extraSec;
        emit DeskExtended(deskId, d.closesAt);
    }

    function sealDesk(uint64 deskId) external onlyDirector {
        Desk storage d = _requireKnownDesk(deskId);
        if (d.sealed) revert OUSE_DeskSealed(deskId);
        d.open = false;
        d.sealed = true;
        emit DeskSealed(deskId, d.signalCount, d.agentCount);
    }

    function pinRisk(
        uint64 deskId,
        uint32 maxDrawdownBps,
        uint32 maxPositionBps,
        uint32 cooldownSec
    ) external onlyDirector whenDeskLive {
        _requireOpenDesk(deskId);
        if (maxDrawdownBps > MAX_DRAWNDOWN_BPS) revert OUSE_DrawdownTooHigh(maxDrawdownBps, MAX_DRAWNDOWN_BPS);
        if (maxPositionBps > MAX_POSITION_BPS) revert OUSE_PositionTooHigh(maxPositionBps, MAX_POSITION_BPS);
        if (cooldownSec > MAX_COOLDOWN_SEC) revert OUSE_CooldownTooLong(cooldownSec, MAX_COOLDOWN_SEC);

        RiskEnvelope storage r = _risk[deskId];
        if (r.locked) revert OUSE_RiskLocked(deskId);
        r.maxDrawdownBps = maxDrawdownBps;
        r.maxPositionBps = maxPositionBps;
        r.cooldownSec = cooldownSec;
        r.locked = true;
        emit RiskPinned(deskId, maxDrawdownBps, maxPositionBps, cooldownSec);
    }

    function unlockRisk(uint64 deskId) external onlyDirector {
        _requireKnownDesk(deskId);
        delete _risk[deskId];
        emit RiskUnlocked(deskId);
    }

    function seatAgent(
        uint64 deskId,
        address agent,
        bytes32 personaHash,
        bytes32 policyHash
    ) external whenDeskLive {
        Desk storage d = _requireOpenDesk(deskId);
        if (personaHash == bytes32(0)) revert OUSE_PersonaZero();
        if (policyHash == bytes32(0)) revert OUSE_PolicyZero();
        if (_isSeated[deskId][agent]) revert OUSE_AlreadySeated(deskId, agent);

        _seats[deskId][agent] = AgentSeat({
            personaHash: personaHash,
            policyHash: policyHash,
            active: true,
            seatedAt: uint64(block.timestamp),
            tickTotal: 0,
            streak: 0
        });
        _isSeated[deskId][agent] = true;
        d.agentCount += 1;
        emit AgentSeated(deskId, agent, personaHash, policyHash);
    }

    function vacateAgent(uint64 deskId, address agent) external {
        if (!_isSeated[deskId][agent]) revert OUSE_NotSeated(deskId, agent);
        _isSeated[deskId][agent] = false;
        _seats[deskId][agent].active = false;
        Desk storage d = _desks[deskId];
        if (d.agentCount > 0) d.agentCount -= 1;
        emit AgentVacated(deskId, agent);
    }

    function postTick(
        uint64 deskId,
        bytes32 featureHash,
        bytes32 inferenceHash,
        uint32 confidenceBps,
        bytes calldata auxPayload
    ) external whenDeskLive {
        Desk storage d = _requireOpenDesk(deskId);
        if (!_isSeated[deskId][msg.sender]) revert OUSE_NotSeated(deskId, msg.sender);
        if (featureHash == bytes32(0)) revert OUSE_FeatureZero();
        if (inferenceHash == bytes32(0)) revert OUSE_InferenceZero();
        if (confidenceBps > MAX_CONFIDENCE_BPS) revert OUSE_ConfidenceTooHigh(confidenceBps, MAX_CONFIDENCE_BPS);
        if (auxPayload.length > MAX_SIGNAL_BYTES) revert OUSE_SignalTooLong(auxPayload.length, MAX_SIGNAL_BYTES);

        AgentSeat storage seat = _seats[deskId][msg.sender];
        uint32 streak = OuseTickMath.streakNext(seat.streak, STREAK_CAP);
        bytes32 blend = OuseTickMath.blendSignal(d.modelRoot, inferenceHash, confidenceBps);

        _lastTick[deskId][msg.sender] = SignalTick({
            featureHash: featureHash,
            inferenceHash: inferenceHash,
            blendHash: blend,
            confidenceBps: confidenceBps,
            postedAt: uint64(block.timestamp)
        });

        seat.streak = streak;
        seat.tickTotal += 1;
        d.signalCount += 1;
        globalTickCount += 1;

        emit TickPosted(deskId, msg.sender, inferenceHash, confidenceBps);
    }

    function fileIntent(
        uint64 deskId,
        bytes32 pairHash,
        bytes32 routeHint,
        uint8 side,
        uint256 notionalCap
    ) external payable whenDeskLive nonReentrant {
        if (msg.value < MIN_INTENT_TIP_WEI) revert OUSE_IntentTipTooSmall(msg.value, MIN_INTENT_TIP_WEI);
        Desk storage d = _requireOpenDesk(deskId);
        if (!_isSeated[deskId][msg.sender]) revert OUSE_NotSeated(deskId, msg.sender);
        if (pairHash == bytes32(0)) revert OUSE_PairHashZero();
        if (notionalCap == 0) revert OUSE_NotionalZero();
        if (side != SIDE_BID && side != SIDE_ASK) revert OUSE_SideInvalid(side);

        RiskEnvelope storage r = _risk[deskId];
        if (r.locked && notionalCap > (uint256(r.maxPositionBps) * 1e14)) {
            revert OUSE_PositionTooHigh(uint32(notionalCap / 1e14), r.maxPositionBps);
        }

        uint64 nonce = _intentNonce[deskId][msg.sender]++;
        uint64 intentId = uint64(globalIntentCount++);
        d.tipPool += msg.value;

        _intents[deskId][intentId] = IntentSlot({
            pairHash: pairHash,
            routeHint: routeHint,
            filer: msg.sender,
            side: side,
            open: true,
            settled: false,
            notionalCap: notionalCap,
            filedAt: uint64(block.timestamp),
            nonce: nonce
        });

        emit IntentFiled(deskId, intentId, msg.sender, side, notionalCap);
        emit TipReceived(deskId, msg.sender, msg.value, d.tipPool);
    }

    function cancelIntent(uint64 deskId, uint64 intentId) external {
        IntentSlot storage slot = _intents[deskId][intentId];
        if (slot.filedAt == 0) revert OUSE_IntentUnknown(deskId, intentId);
        if (slot.filer != msg.sender && msg.sender != director) revert OUSE_NotAuthorized(msg.sender);
        if (!slot.open) revert OUSE_IntentClosed(deskId, intentId);
        slot.open = false;
        emit IntentCanceled(deskId, intentId);
    }

    function settleIntent(uint64 deskId, uint64 intentId, bytes32 outcomeHash) external onlyDirector {
        IntentSlot storage slot = _intents[deskId][intentId];
        if (slot.filedAt == 0) revert OUSE_IntentUnknown(deskId, intentId);
        if (slot.settled) revert OUSE_IntentAlreadySettled(deskId, intentId);
        slot.open = false;
        slot.settled = true;
        slot.routeHint = outcomeHash;
        emit IntentSettled(deskId, intentId, outcomeHash);
    }

    function storeBacktest(
        uint64 deskId,
        bytes32 reportHash,
        bytes32 benchmarkHash
    ) external payable whenDeskLive nonReentrant {
        if (msg.value < BACKTEST_FEE_WEI) revert OUSE_BacktestFeeShort(msg.value, BACKTEST_FEE_WEI);
        _requireKnownDesk(deskId);
        if (reportHash == bytes32(0)) revert OUSE_FeatureZero();
        if (_usedReport[reportHash]) revert OUSE_ReportReplay(reportHash);

        uint256 leafId = ++backtestSeq;
        _backtests[leafId] = BacktestLeaf({
            reportHash: reportHash,
            benchmarkHash: benchmarkHash,
            author: msg.sender,
            deskId: deskId,
            storedAt: uint64(block.timestamp),
            revoked: false
        });
        _usedReport[reportHash] = true;
        emit BacktestStored(leafId, deskId, msg.sender, reportHash);
    }

    function revokeBacktest(uint256 leafId) external onlyDirector {
        BacktestLeaf storage leaf = _backtests[leafId];
        if (leaf.storedAt == 0) revert OUSE_BacktestUnknown(leafId);
        leaf.revoked = true;
        emit BacktestRevoked(leafId, msg.sender);
    }

    function withdrawDeskTips(uint64 deskId, uint256 amountWei) external onlyDirector nonReentrant {
        if (amountWei == 0) revert OUSE_WithdrawZero();
        Desk storage d = _desks[deskId];
        if (amountWei > d.tipPool) revert OUSE_InsufficientTipPool(amountWei, d.tipPool);
        d.tipPool -= amountWei;
        (bool ok, ) = director.call{value: amountWei}("");
        if (!ok) revert OUSE_TransferFailed();
        emit TipsWithdrawn(director, amountWei);
    }


    function batchPostTicks(
        uint64 deskId,
        address[] calldata agents,
        bytes32[] calldata featureHashes,
        bytes32[] calldata inferenceHashes,
        uint32[] calldata confidenceBpsList
    ) external whenDeskLive {
        uint256 n = agents.length;
        if (n != featureHashes.length || n != inferenceHashes.length || n != confidenceBpsList.length) {
            revert OUSE_BatchTooLarge(n, 0);
        }
        if (n > MAX_BATCH) revert OUSE_BatchTooLarge(n, MAX_BATCH);
        for (uint256 i; i < n; ) {
            _postTickInternal(deskId, agents[i], featureHashes[i], inferenceHashes[i], confidenceBpsList[i]);
            unchecked { ++i; }
        }
    }

    function _postTickInternal(
        uint64 deskId,
        address agent,
        bytes32 featureHash,
        bytes32 inferenceHash,
        uint32 confidenceBps
    ) private {
        Desk storage d = _requireOpenDesk(deskId);
        if (!_isSeated[deskId][agent]) revert OUSE_NotSeated(deskId, agent);
        if (featureHash == bytes32(0)) revert OUSE_FeatureZero();
        if (inferenceHash == bytes32(0)) revert OUSE_InferenceZero();
        if (confidenceBps > MAX_CONFIDENCE_BPS) revert OUSE_ConfidenceTooHigh(confidenceBps, MAX_CONFIDENCE_BPS);

        AgentSeat storage seat = _seats[deskId][agent];
        bytes32 blend = OuseTickMath.blendSignal(d.modelRoot, inferenceHash, confidenceBps);
        _lastTick[deskId][agent] = SignalTick({
            featureHash: featureHash,
            inferenceHash: inferenceHash,
            blendHash: blend,
            confidenceBps: confidenceBps,
            postedAt: uint64(block.timestamp)
        });
        seat.streak = OuseTickMath.streakNext(seat.streak, STREAK_CAP);
        seat.tickTotal += 1;
        d.signalCount += 1;
        globalTickCount += 1;
        emit TickPosted(deskId, agent, inferenceHash, confidenceBps);
    }

    function peekDeskSummary_1(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_2(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_3(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_4(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_5(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_6(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_7(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_8(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_9(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
        bool open,
        bool sealed,
        uint64 openedAt,
        uint64 closesAt,
        uint32 signalCount,
        uint32 agentCount,
        uint256 tipPool
    ) {
        Desk storage d = _desks[deskId];
        return (
            d.modelRoot,
            d.venueTag,
            d.open,
            d.sealed,
            d.openedAt,
            d.closesAt,
            d.signalCount,
            d.agentCount,
            d.tipPool
        );
    }

    function peekDeskSummary_10(uint64 deskId) external view returns (
        bytes32 modelRoot,
        bytes32 venueTag,
