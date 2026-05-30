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
