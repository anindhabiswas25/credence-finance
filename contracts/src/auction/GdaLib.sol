// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Gda} from "../libraries/Types.sol";
import {ICredenceErrors} from "../libraries/Errors.sol";

/// @title Continuous GDA pricing of the pool's backstop inventory (F-4.5e, Paradigm 2022), with the S4 reserve floor.
/// @dev External library (linked, DELEGATECALL) so the AuctionHouse fits the 24 KB code-size limit.
library GdaLib {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice Cost of the next `qty` units in loan units, rounded up: max(GDA price, qty × floorPrice).
    /// @dev Continuous GDA: units are emitted at r per second from `start`; the unit emitted at s costs
    ///      k·e^{−λ(now − s)}. Buying q units takes the oldest unsold ones, whose age is T = now − start − sold / r:
    ///      P(q) = k · r · (e^{λq/r} − 1) · e^{−λT} / λ. Only emitted units can be bought. `floorPrice` (WAD per token)
    ///      = (1 − κ) × V_live: the pool never sells inventory below the reserve it bought it at (QA-03, ADR-0113).
    function cost(Gda storage g, uint256 qty, uint256 floorPrice, uint256 loanScale)
        external
        view
        returns (uint256)
    {
        if (qty == 0) return 0;
        uint256 elapsed = block.timestamp - g.start;
        uint256 emitted = Math.min(uint256(g.qty), elapsed * g.emissionPerSec);
        uint256 available = emitted > g.sold ? emitted - g.sold : 0;
        if (qty > available) revert ICredenceErrors.GdaInsufficient(available, qty);
        uint256 age = elapsed - uint256(g.sold) / g.emissionPerSec; // T ≥ 0 because sold ≤ emitted
        uint256 x = uint256(g.decay).mulDiv(qty, g.emissionPerSec); // λq/r, WAD
        uint256 growth = uint256(FixedPointMathLib.expWad(int256(x))) - WAD;
        uint256 decayF = uint256(FixedPointMathLib.expWad(-int256(uint256(g.decay) * age)));
        uint256 unit = 10 ** IERC20Metadata(g.token).decimals();
        // k (WAD per whole token) × r (units/s) / 10^cd → WAD value per second; / λ → WAD value
        uint256 perSec = uint256(g.k).mulDiv(g.emissionPerSec, unit);
        uint256 value = perSec.mulDiv(WAD, g.decay, Math.Rounding.Ceil)
            .mulDiv(growth, WAD, Math.Rounding.Ceil)
            .mulDiv(decayF, WAD, Math.Rounding.Ceil);
        uint256 floorValue = qty.mulDiv(floorPrice, unit, Math.Rounding.Ceil);
        return Math.max(value, floorValue).mulDiv(1, loanScale, Math.Rounding.Ceil);
    }
}
