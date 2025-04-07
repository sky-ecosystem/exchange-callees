// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
// Copyright (C) 2024 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

interface TokenLike {
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

interface UniswapV2Router02Like {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256) external returns (uint256[] memory);
}

interface DaiJoinLike {
    function dai() external view returns (address);
    function join(address, uint256) external;
}

interface UsdsJoinLike {
    function usds() external view returns (address);
    function join(address, uint256) external;
}

interface MkrSky {
    function mkr() external view returns (address);
    function sky() external view returns (address);
    function rate() external view returns (uint256);
    function mkrToSky(address, uint256) external;
}

contract UniswapV2LockstakeCallee {
    UniswapV2Router02Like   public immutable uniRouter02;
    DaiJoinLike             public immutable daiJoin;
    TokenLike               public immutable dai;
    UsdsJoinLike            public immutable usdsJoin;
    TokenLike               public immutable usds;
    MkrSky                  public immutable mkrSky;
    TokenLike               public immutable mkr;
    TokenLike               public immutable sky;
    uint256                 public constant RAY = 10 ** 27;

    constructor(address uniRouter02_, address daiJoin_, address usdsJoin_, address mkrSky_) {
        uniRouter02 = UniswapV2Router02Like(uniRouter02_);

        daiJoin = DaiJoinLike(daiJoin_);
        dai = TokenLike(daiJoin.dai());
        dai.approve(daiJoin_, type(uint256).max);

        usdsJoin = UsdsJoinLike(usdsJoin_);
        usds = TokenLike(usdsJoin.usds());
        usds.approve(usdsJoin_, type(uint256).max);

        mkrSky = MkrSky(mkrSky_);
        mkr = TokenLike(mkrSky.mkr());
        sky = TokenLike(mkrSky.sky());
    }

    function divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x != 0 ? ((x - 1) / y) + 1 : 0;
    }

    function clipperCall(
        address sender,     // Clipper Caller and DAI/USDS delivery address
        uint256 dstAmt,     // DAI/USDS amount to payback [rad]
        uint256 gemAmt,     // Gem amount received [wad]
        bytes calldata data // Extra data needed
    ) external {
        (
            address to,           // Address to send remaining DAI/USDS to
            uint256 minProfit,    // Minimum profit in DAI/USDS to make [wad]
            address[] memory path // Uniswap pool path
        ) = abi.decode(data, (address, uint256, address[]));

        // Support SKY
        TokenLike gem = mkr;
        if (path[0] == address(sky)) {
            gem = sky;
            mkr.approve(address(mkrSky), gemAmt);
            mkrSky.mkrToSky(address(this), gemAmt);
            gemAmt = gemAmt * mkrSky.rate();
        }

        // Approve uniRouter02 to take gem
        gem.approve(address(uniRouter02), gemAmt);

        // Calculate amount of tokens to Join (as erc20 WAD value)
        uint256 amtToJoin = divup(dstAmt, RAY);

        // Exchange tokens based on the path (checking the profit is achieved)
        uniRouter02.swapExactTokensForTokens(
            gemAmt,
            amtToJoin + minProfit,
            path,
            address(this),
            block.timestamp
        );

        // Although Uniswap will accept all gems, this check is a sanity check, just in case
        if (gem.balanceOf(address(this)) > 0) {
            // Transfer any lingering gem to specified address
            gem.transfer(to, gem.balanceOf(address(this)));
        }

        // Determine destination token
        TokenLike dst = TokenLike(path[path.length - 1]);

        // Convert tokens bought to internal vat value of the msg.sender of Clipper.take
        if (address(dst) == address(dai)) {
            daiJoin.join(sender, amtToJoin);
        } else if (address(dst) == address(usds)) {
            usdsJoin.join(sender, amtToJoin);
        }

        // Transfer remaining tokens to specified address
        dst.transfer(to, dst.balanceOf(address(this)));
    }
}

