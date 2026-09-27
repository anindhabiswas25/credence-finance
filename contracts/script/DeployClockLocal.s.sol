// SPDX-License-Identifier: BUSL-1.1
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
///      OUT                      output address book (default ../deployments/<chainid>.local.json)
contract DeployClockLocal is Script {
    bytes32 internal constant XNYS = bytes32("XNYS");
    bytes32 internal constant USBANK = bytes32("USBANK");

    struct Deployed {
        address calendar;
        address sequencerHealth;
        address clock;
        address feedA;
        address feedB;
        address navFeed;
        address oracle;
        address registry;
        address faucet;
        address usdc;
        address fund;
    }

    function run() external {
        require(block.chainid != 421614 && block.chainid != 42161, "local only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint8 threshold = uint8(vm.envOr("RELAYER_THRESHOLD", uint256(2)));
        address[] memory signersA = _sorted(vm.envAddress("RELAYER_A_SIGNERS", ","));
        address[] memory signersB = _sorted(vm.envAddress("RELAYER_B_SIGNERS", ","));
        string[] memory tickers = vm.envOr("ASSETS", ",", _defaultTickers());

        vm.startBroadcast(pk);
        Deployed memory d;
        CalendarStore cal = new CalendarStore(me);
        d.calendar = address(cal);
        SequencerHealth seq = new SequencerHealth();
        d.sequencerHealth = address(seq);
        AssetClock clock = new AssetClock(me, me, address(cal), address(seq));
        d.clock = address(clock);
        seq.setClock(address(clock));
        d.feedA = address(new CredencePriceFeed(me, signersA, threshold));
        d.feedB = address(new CredencePriceFeed(me, signersB, threshold));
        d.navFeed = address(new CredencePriceFeed(me, signersA, threshold));
        OracleAdapter oracle = new OracleAdapter(me);
        d.oracle = address(oracle);
        oracle.setClock(address(clock));
        clock.initializeWiring(address(oracle), address(0), address(0));

        _loadCalendar(cal, XNYS, vm.envString("XNYS_CALENDAR"));
        _loadCalendar(cal, USBANK, vm.envString("USBANK_CALENDAR"));

        ComplianceRegistry registry = new ComplianceRegistry(me);
        d.registry = address(registry);
        Faucet faucet = new Faucet(me);
        d.faucet = address(faucet);

        string memory json = "deployment";
        for (uint256 i; i < tickers.length; ++i) {
            CredenceStockToken t = new CredenceStockToken(
                string.concat("Credence Test ", tickers[i]), string.concat("t", tickers[i]), me, address(0)
            );
            bytes32 assetId = keccak256(bytes(string.concat(tickers[i], ":XNAS")));
            oracle.setAssetConfig(assetId, d.feedA, d.feedB, address(0), address(t), MarketKind.EQUITY, 250_000e18);
            clock.listAsset(assetId, XNYS, MarketKind.EQUITY);
            t.setMinter(address(faucet), type(uint128).max);
            faucet.configure(address(t), 50e18, false);
            vm.serializeAddress(json, string.concat("t", tickers[i]), address(t));
            vm.serializeBytes32(json, string.concat("assetId_", tickers[i]), assetId);
        }

        // NAV stack test asset: tTBILL on USBANK, priced by the NAV feed
        MockUSDC usdc = new MockUSDC();
        d.usdc = address(usdc);
        registry.setAllowed(me, true);
        CredenceTreasuryFund fund =
            new CredenceTreasuryFund("Credence Test T-Bill Fund", "tTBILL", me, address(registry), address(usdc), me, 1e18);
        d.fund = address(fund);
        bytes32 tbill = keccak256("TBILL:USBANK");
        oracle.setAssetConfig(tbill, d.navFeed, address(0), address(0), address(fund), MarketKind.NAV, 0);
        clock.listAsset(tbill, USBANK, MarketKind.NAV);
        fund.setMinter(address(faucet), type(uint128).max);
        faucet.configure(address(fund), 100_000e18, true);
        vm.stopBroadcast();

        vm.serializeBytes32(json, "assetId_TBILL", tbill);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "startBlock", block.number);
        vm.serializeAddress(json, "calendar", d.calendar);
        vm.serializeAddress(json, "sequencerHealth", d.sequencerHealth);
        vm.serializeAddress(json, "clock", d.clock);
        vm.serializeAddress(json, "feedA", d.feedA);
        vm.serializeAddress(json, "feedB", d.feedB);
        vm.serializeAddress(json, "navFeed", d.navFeed);
        vm.serializeAddress(json, "oracle", d.oracle);
        vm.serializeAddress(json, "registry", d.registry);
        vm.serializeAddress(json, "faucet", d.faucet);
        vm.serializeAddress(json, "usdc", d.usdc);
        string memory out = vm.serializeAddress(json, "tTBILL", d.fund);
        string memory path = vm.envOr(
            "OUT", string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".local.json")
        );
        vm.writeJson(out, path);
        console2.log("address book:", path);
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

    function _defaultTickers() internal pure returns (string[] memory t) {
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
