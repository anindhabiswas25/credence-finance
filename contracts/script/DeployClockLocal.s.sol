// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Session, MarketKind} from "../src/libraries/Types.sol";
import {CalendarStore} from "../src/clock/CalendarStore.sol";
import {AssetClock} from "../src/clock/AssetClock.sol";
import {SequencerHealth} from "../src/oracle/SequencerHealth.sol";
import {CredencePriceFeed} from "../src/oracle/CredencePriceFeed.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {CredenceStockToken} from "../src/testnet/CredenceStockToken.sol";
import {CredenceTreasuryFund} from "../src/testnet/CredenceTreasuryFund.sol";
import {ComplianceRegistry} from "../src/testnet/ComplianceRegistry.sol";
import {Faucet} from "../src/testnet/Faucet.sol";
import {LocalBook} from "./utils/LocalBook.sol";

/// @title Local (anvil / nitro-devnode) deployment of the S1 clock + price stack and the test assets.
/// @notice LOCAL ONLY. The deployer acts as timelock, guardian and issuer so that a dev loop can list assets and
///         load calendars without a Safe. It refuses to run on Arbitrum Sepolia (421614) or Arbitrum One (42161).
/// @dev Env:
///      PRIVATE_KEY              deployer key (the nitro-devnode dev key by default in mk/contracts.mk)
///      RELAYER_A_SIGNERS        comma-separated committee of feed A (≥ 3 recommended), ascending order not required
///      RELAYER_B_SIGNERS        committee of feed B
///      RELAYER_THRESHOLD        default 2
///      XNYS_CALENDAR            path to BE-backend's XNYS calendar JSON (relative to contracts/)
///      USBANK_CALENDAR          path to the USBANK calendar JSON
///      ASSETS                   comma-separated tickers listed on XNYS as "<TICKER>:XNAS" (default NVDA)
///      OUT                      output address book (default ../deployments/<chainid>.local.json, ADR-0105)
///      START_BLOCK              indexer start block (default: the block number the script runs at)
contract DeployClockLocal is Script {
    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant USBANK = bytes32("USBANK");

    /// @notice Handles of the clock + price stack (for scripts that build on it, e.g. DeployCoreLocal).
    struct ClockStack {
        CalendarStore calendar;
        SequencerHealth sequencerHealth;
        AssetClock clock;
        CredencePriceFeed feedA;
        CredencePriceFeed feedB;
        CredencePriceFeed navFeed;
        OracleAdapter oracle;
        ComplianceRegistry registry;
        Faucet faucet;
        MockUSDC usdc;
        CredenceTreasuryFund fund;
        CredenceStockToken[] stocks;
        string[] tickers;
        bytes32[] assetIds; // stocks, in `tickers` order
        bytes32 tbill;
    }

    function run() external virtual {
        _requireLocal();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        ClockStack memory c = _deployClockStack(me, me);
        // clock-only stack: no auction house / settlement adapter yet (DeployCoreLocal wires its own)
        c.clock.initializeWiring(address(c.oracle), address(0), address(0));
        vm.stopBroadcast();
        string memory path = vm.envOr("OUT", LocalBook.defaultPath());
        LocalBook.Book memory b = _book(c, me, me);
        LocalBook.carryEngine(b, path);
        LocalBook.write(b, path);
        console2.log("address book:", path);
    }

    function _requireLocal() internal view {
        require(block.chainid != 421614 && block.chainid != 42161, "local only");
    }

    /// @dev Deploys the S1 stack. `guardian` is the AssetClock guardian (the deployer, or a CredenceGuardian).
    function _deployClockStack(address me, address guardian) internal returns (ClockStack memory c) {
        uint8 threshold = uint8(vm.envOr("RELAYER_THRESHOLD", uint256(2)));
        address[] memory signersA = _sorted(vm.envAddress("RELAYER_A_SIGNERS", ","));
        address[] memory signersB = _sorted(vm.envAddress("RELAYER_B_SIGNERS", ","));
        c.tickers = vm.envOr("ASSETS", ",", _defaultTickers());

        c.calendar = new CalendarStore(me);
        c.sequencerHealth = new SequencerHealth();
        c.clock = new AssetClock(me, guardian, address(c.calendar), address(c.sequencerHealth));
        c.sequencerHealth.setClock(address(c.clock));
        c.feedA = new CredencePriceFeed(me, signersA, threshold);
        c.feedB = new CredencePriceFeed(me, signersB, threshold);
        c.navFeed = new CredencePriceFeed(me, signersA, threshold);
        c.oracle = new OracleAdapter(me);
        c.oracle.setClock(address(c.clock));

        _loadCalendar(c.calendar, XNYS, vm.envString("XNYS_CALENDAR"));
        _loadCalendar(c.calendar, USBANK, vm.envString("USBANK_CALENDAR"));

        c.registry = new ComplianceRegistry(me);
        c.faucet = new Faucet(me);
        c.stocks = new CredenceStockToken[](c.tickers.length);
        c.assetIds = new bytes32[](c.tickers.length);
        for (uint256 i; i < c.tickers.length; ++i) {
            CredenceStockToken t = new CredenceStockToken(
                string.concat("Credence Test ", c.tickers[i]),
                string.concat("t", c.tickers[i]),
                me,
                address(0)
            );
            bytes32 assetId = keccak256(bytes(string.concat(c.tickers[i], ":XNAS")));
            c.oracle
                .setAssetConfig(
                    assetId,
                    address(c.feedA),
                    address(c.feedB),
                    address(0),
                    address(t),
                    MarketKind.EQUITY,
                    250_000e18
                );
            c.clock.listAsset(assetId, XNYS, MarketKind.EQUITY);
            t.setMinter(address(c.faucet), type(uint128).max);
            c.faucet.configure(address(t), 50e18, false);
            c.stocks[i] = t;
            c.assetIds[i] = assetId;
        }

        // NAV stack test asset: tTBILL on USBANK, priced by the NAV feed
        c.usdc = new MockUSDC();
        c.registry.setAllowed(me, true);
        c.fund = new CredenceTreasuryFund(
            "Credence Test T-Bill Fund", "tTBILL", me, address(c.registry), address(c.usdc), me, 1e18
        );
        c.tbill = keccak256("TBILL:USBANK");
        c.oracle
            .setAssetConfig(
                c.tbill, address(c.navFeed), address(0), address(0), address(c.fund), MarketKind.NAV, 0
            );
        c.clock.listAsset(c.tbill, USBANK, MarketKind.NAV);
        c.fund.setMinter(address(c.faucet), type(uint128).max);
        c.faucet.configure(address(c.fund), 100_000e18, true);
    }

    /// @dev The book of the clock stack; scripts that deploy more fill in the rest.
    function _book(ClockStack memory c, address timelock, address guardian)
        internal
        view
        returns (LocalBook.Book memory b)
    {
        b.chainId = block.chainid;
        b.startBlock = vm.envOr("START_BLOCK", vm.getBlockNumber());
        b.shared = LocalBook.Shared({
            timelock: timelock,
            guardian: guardian,
            calendar: address(c.calendar),
            clock: address(c.clock),
            oracle: address(c.oracle),
            feedA: address(c.feedA),
            feedB: address(c.feedB),
            feedNav: address(c.navFeed),
            riskEngine: address(0),
            sigmaOracle: address(0),
            sequencerHealth: address(c.sequencerHealth),
            registry: address(c.registry),
            faucet: address(c.faucet)
        });
        uint256 n = c.tickers.length;
        b.tokenNames = new string[](n + 2);
        b.tokenAddrs = new address[](n + 2);
        b.assetNames = new string[](n + 1);
        b.assetIds = new bytes32[](n + 1);
        for (uint256 i; i < n; ++i) {
            b.tokenNames[i] = string.concat("t", c.tickers[i]);
            b.tokenAddrs[i] = address(c.stocks[i]);
            b.assetNames[i] = c.tickers[i];
            b.assetIds[i] = c.assetIds[i];
        }
        b.tokenNames[n] = "tTBILL";
        b.tokenAddrs[n] = address(c.fund);
        b.tokenNames[n + 1] = "usdc";
        b.tokenAddrs[n + 1] = address(c.usdc);
        b.assetNames[n] = "TBILL";
        b.assetIds[n] = c.tbill;
    }

    function _loadCalendar(CalendarStore cal, bytes32 venue, string memory path) internal {
        string memory json = vm.readFile(path);
        Session[] memory s = abi.decode(vm.parseJsonBytes(json, ".sessionsAbiEncoded"), (Session[]));
        // chunks keep each tx far below the block gas limit
        uint256 chunk = 60;
        for (uint256 i; i < s.length; i += chunk) {
            uint256 n = s.length - i < chunk ? s.length - i : chunk;
            Session[] memory part = new Session[](n);
            for (uint256 j; j < n; ++j) {
                part[j] = s[i + j];
            }
            cal.appendSessions(venue, part);
        }
    }

    function _sorted(address[] memory a) internal pure returns (address[] memory) {
        for (uint256 i; i < a.length; ++i) {
            for (uint256 j = i + 1; j < a.length; ++j) {
                if (a[j] < a[i]) (a[i], a[j]) = (a[j], a[i]);
            }
        }
        return a;
    }

    function _defaultTickers() internal pure virtual returns (string[] memory t) {
        t = new string[](1);
        t[0] = "NVDA";
    }
}

/// @dev Local stand-in for Circle test USDC (6 decimals, open mint). Never deployed outside a local chain.
contract MockUSDC {
    string public constant name = "Local USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
