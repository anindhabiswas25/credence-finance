// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    Session,
    Report,
    ReportKind,
    FeedMarketStatus,
    MarketKind,
    ClockState,
    ClockData,
    ClosureType
} from "../../src/libraries/Types.sol";
import {CalendarStore} from "../../src/clock/CalendarStore.sol";
import {AssetClock} from "../../src/clock/AssetClock.sol";
import {SequencerHealth} from "../../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {CredenceStockToken} from "../../src/testnet/CredenceStockToken.sol";
import {MockTwapSource} from "../mocks/MockTwapSource.sol";

/// @dev Full clock + price stack on the real XNYS calendar (a slice of BE-backend's generator output), with a
///      2-of-3 relayer committee signing real EIP-712 reports.
abstract contract ClockFixture is Test {
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal auctionHouse = makeAddr("auctionHouse");
    address internal settlement = makeAddr("settlement");
    address internal issuer = makeAddr("issuer");

    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant USBANK = bytes32("USBANK");
    bytes32 internal constant NVDA = keccak256("NVDA:XNAS");

    CalendarStore internal calendar;
    SequencerHealth internal seqHealth;
    AssetClock internal clock;
    CredencePriceFeed internal feedA;
    CredencePriceFeed internal feedB;
    OracleAdapter internal oracle;
    CredenceStockToken internal token;
    MockTwapSource internal dex;

    uint256[3] internal signerKeys;
    address[] internal signers; // ascending
    mapping(address feed => mapping(bytes32 asset => uint64)) internal seqOf;

    Session[] internal sessions;

    function setUpStack() internal {
        _loadCalendarFixture("test/fixtures/XNYS-20261001-20270402.json");
        _deployStack();
    }

    function _deployStack() internal {
        calendar = new CalendarStore(timelock);
        vm.prank(timelock);
        calendar.appendSessions(XNYS, sessions);

        seqHealth = new SequencerHealth();
        clock = new AssetClock(timelock, guardian, address(calendar), address(seqHealth));
        seqHealth.setClock(address(clock));

        _makeCommittee();
        feedA = new CredencePriceFeed(timelock, signers, 2);
        feedB = new CredencePriceFeed(timelock, signers, 2);

        oracle = new OracleAdapter(timelock);
        oracle.setClock(address(clock));
        clock.initializeWiring(address(oracle), auctionHouse, settlement);

        token = new CredenceStockToken("Credence Test NVIDIA", "tNVDA", issuer, address(0));
        dex = new MockTwapSource();
        vm.prank(timelock);
        oracle.setAssetConfig(
            NVDA, address(feedA), address(feedB), address(dex), address(token), MarketKind.EQUITY, 250_000e18
        );
    }

    /// @dev A deterministic Mon–Fri calendar: `weeks` weeks from Monday 00:00 UTC `t0`. Per day: extOpen 00:00,
    ///      open 09:00, close 15:30, extClose 20:00. Fridays are followed by a WEEKEND closure (next Monday).
    function _syntheticSessions(uint40 t0, uint256 weeks_) internal {
        delete sessions;
        for (uint256 w; w < weeks_; ++w) {
            for (uint256 d; d < 5; ++d) {
                uint40 base = t0 + uint40(w * 7 days + d * 1 days);
                sessions.push(
                    Session(
                        base,
                        base + 9 hours,
                        base + 15 hours + 30 minutes,
                        base + 20 hours,
                        d == 4 ? ClosureType.WEEKEND : ClosureType.OVERNIGHT
                    )
                );
            }
        }
    }

    function _loadCalendarFixture(string memory path) internal {
        string memory json = vm.readFile(path);
        Session[] memory s = abi.decode(vm.parseJsonBytes(json, ".sessionsAbiEncoded"), (Session[]));
        delete sessions;
        for (uint256 i; i < s.length; ++i) {
            sessions.push(s[i]);
        }
    }

    function _makeCommittee() internal {
        uint256[3] memory keys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xC4A11)];
        address[3] memory addrs = [vm.addr(keys[0]), vm.addr(keys[1]), vm.addr(keys[2])];
        // sort ascending by address
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        delete signers;
        for (uint256 i; i < 3; ++i) {
            signers.push(addrs[i]);
            signerKeys[i] = keys[i];
        }
    }

    // ───────────── report helpers ─────────────

    function _sign(CredencePriceFeed feed, Report[] memory reports, uint256 nSigners)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 digest = feed.hashReports(reports);
        sigs = new bytes[](nSigners);
        for (uint256 i; i < nSigners; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _report(
        CredencePriceFeed feed,
        bytes32 asset,
        uint8 kind,
        uint256 price,
        uint40 at,
        uint40 sessionDate,
        uint8 status
    ) internal returns (Report memory r) {
        uint64 s = ++seqOf[address(feed)][asset];
        r = Report({
            assetId: asset,
            kind: kind,
            price: uint128(price),
            observedAt: at,
            sessionDate: sessionDate,
            marketStatus: status,
            seq: s
        });
    }

    function _submit(CredencePriceFeed feed, Report memory r) internal {
        Report[] memory rs = new Report[](1);
        rs[0] = r;
        feed.submit(rs, _sign(feed, rs, 2));
    }

    function _live(CredencePriceFeed feed, bytes32 asset, uint256 price, uint8 status) internal {
        _submit(feed, _report(feed, asset, ReportKind.LIVE, price, uint40(vm.getBlockTimestamp()), 0, status));
    }

    /// @dev Both feeds print the same live price now.
    function _liveBoth(uint256 price, uint8 status) internal {
        _live(feedA, NVDA, price, status);
        _live(feedB, NVDA, price, status);
    }

    function _openPrint(CredencePriceFeed feed, bytes32 asset, uint256 price, uint40 sessionOpen) internal {
        _submit(
            feed,
            _report(
                feed,
                asset,
                ReportKind.OPEN,
                price,
                sessionOpen,
                sessionOpen / 1 days,
                FeedMarketStatus.REGULAR
            )
        );
    }

    function _closePrint(CredencePriceFeed feed, bytes32 asset, uint256 price, uint40 sessionOpen, uint40 at)
        internal
    {
        _submit(
            feed,
            _report(feed, asset, ReportKind.CLOSE, price, at, sessionOpen / 1 days, FeedMarketStatus.POST)
        );
    }

    function _status(CredencePriceFeed feed, bytes32 asset, uint8 status) internal {
        _submit(feed, _report(feed, asset, ReportKind.STATUS, 0, uint40(vm.getBlockTimestamp()), 0, status));
    }

    // ───────────── clock helpers ─────────────

    function _list() internal {
        vm.prank(timelock);
        clock.listAsset(NVDA, XNYS, MarketKind.EQUITY);
    }

    function _warp(uint256 t) internal {
        vm.warp(t);
    }

    function _poke() internal returns (ClockState) {
        return clock.poke(NVDA);
    }

    function _info() internal view returns (ClockData memory) {
        return clock.closureInfo(NVDA);
    }

    /// @dev Index of the fixture session whose date string is `date` (YYYY-MM-DD).
    function _idx(string memory date) internal view returns (uint256) {
        string memory json = vm.readFile("test/fixtures/XNYS-20261001-20270402.json");
        string[] memory dates = vm.parseJsonStringArray(json, ".sessionDates");
        for (uint256 i; i < dates.length; ++i) {
            if (keccak256(bytes(dates[i])) == keccak256(bytes(date))) return i;
        }
        revert("date not in fixture");
    }
}
