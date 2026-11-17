// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";

/// @notice Harness smoke test: proves the fork setup works before any
/// candidate PoC is written. Forks Ethereum mainnet at a pinned block and
/// asserts deployed code exists at the DepositPool implementation
/// (0xdB10dAEF167eA2233Ba6811457dD24D676FbD670, shared by all 5 proxies).
/// No state changes, no privileged accounts, read-only.
contract HarnessSmokeTest is Test {
    address constant DEPOSIT_POOL_IMPL =
        0xdB10dAEF167eA2233Ba6811457dD24D676FbD670;
    uint256 constant FORK_BLOCK = 26432468; // Ethereum, 17 Nov 2026

    function setUp() public {
        vm.createSelectFork("eth", FORK_BLOCK);
    }

    function test_forkBlockPinned() public view {
        assertEq(block.number, FORK_BLOCK);
        assertGt(block.chainid, 0);
        assertEq(block.chainid, 1);
    }

    function test_depositPoolImplHasCode() public view {
        uint256 size;
        address target = DEPOSIT_POOL_IMPL;
        assembly {
            size := extcodesize(target)
        }
        assertGt(size, 0, "DepositPool impl has no code at fork block");
    }
}
