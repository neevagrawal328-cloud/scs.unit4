// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {SavingsVault} from "../contracts/SavingsVault.sol";
import {VaultAttacker, FeeSetterHelper, GasHungryReceiver} from "./helpers/TestHelpers.sol";

contract SavingsVaultTest is Test {
    SavingsVault vault;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner); // next call (the deployment) comes from owner
        vault = new SavingsVault();
        vm.deal(alice, 10 ether); // give alice 10 ETH
    }

    // ---------------------------------------------------------------
    // Part C: given tests
    // ---------------------------------------------------------------

    function test_DepositCreditsSender() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        assertEq(vault.balances(alice), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_WithdrawAllPaysAmountMinusFee() public {
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        uint256 fee = (1 ether * vault.feeBps()) / 10_000;
        assertEq(alice.balance, 10 ether - fee);
        assertEq(vault.balances(alice), 0);
        assertEq(vault.collectedFees(), fee);
    }

    function test_RevertWhen_NonOwnerClaimsFees() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        vault.claimFees(payable(alice));
    }

    /// Fuzz test: Hardhat calls this many times with random `amount` values.
    function testFuzz_FeePlusPayoutEqualsDeposit(uint96 amount) public {
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(alice, amount);

        vm.startPrank(alice);
        vault.deposit{value: amount}();
        vault.withdrawAll();
        vm.stopPrank();

        assertLe(vault.collectedFees(), amount);
        assertEq(alice.balance + vault.collectedFees(), amount);
    }

    // ---------------------------------------------------------------
    // Part C: your turn
    // ---------------------------------------------------------------

    function test_RevertWhen_DepositIsZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero deposit"));
        vault.deposit{value: 0}();
    }

    function test_OwnerClaimsExactFees() public {
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        address treasury = makeAddr("treasury");
        uint256 fees = vault.collectedFees();
        uint256 before = treasury.balance;

        vm.prank(owner);
        vault.claimFees(payable(treasury));

        assertEq(treasury.balance, before + fees);
        assertEq(fees, 0.005 ether);
        assertEq(vault.collectedFees(), 0);
    }

    /// EXPECTED TO FAIL on SavingsVault (evidence for SV-01).
    /// vm.prank(owner) only sets msg.sender. tx.origin stays the default
    /// test sender, so `require(tx.origin == owner)` reverts with "not owner".
    function test_OwnerCanSetFee() public {
        vm.prank(owner);
        vault.setFee(100);
        assertEq(vault.feeBps(), 100);
    }

    /// Passes: the second argument also sets tx.origin to owner.
    /// setFee authenticates the transaction originator, not the caller.
    function test_OwnerCanSetFee_WhenOriginIsOwner() public {
        vm.prank(owner, owner);
        vault.setFee(100);
        assertEq(vault.feeBps(), 100);
    }

    // ---------------------------------------------------------------
    // Evidence tests for Part F / Part H (impact, not just reverts)
    // ---------------------------------------------------------------

    /// SV-01 impact: owner is tricked into calling a malicious contract.
    /// It sets the fee to 100%, and alice withdraws nothing.
    function test_Exploit_TxOriginPhishingSetsFeeTo100Percent() public {
        FeeSetterHelper phishing = new FeeSetterHelper();

        vm.prank(owner, owner); // owner's own transaction, into the phishing contract
        phishing.setFeeOn(address(vault), 10_000);
        assertEq(vault.feeBps(), 10_000);

        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        assertEq(alice.balance, 9 ether); // she lost her whole 1 ETH deposit
        assertEq(vault.collectedFees(), 1 ether);
    }

    /// SV-02 impact: re-entrancy drains other users' deposits.
    /// Each entry pays 0.995 ETH; 11 entries -> 10.945 ETH from a 1 ETH deposit.
    function test_Exploit_ReentrancyDrainsVault() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();

        VaultAttacker attacker = new VaultAttacker(address(vault));
        address eve = makeAddr("eve");
        vm.deal(eve, 1 ether);

        vm.prank(eve);
        attacker.attack{value: 1 ether}();

        assertGt(address(attacker).balance, 1 ether); // profit
        assertEq(attacker.reentries(), 10); // 11 entries in total
        assertEq(address(attacker).balance, 10.945 ether);
        assertEq(address(vault).balance, 0.055 ether);
        assertLt(address(vault).balance, vault.balances(alice)); // insolvent
    }

    /// SV-03 / SV-04 impact: a fee above 100% makes `amount - fee` underflow,
    /// so every withdrawAll() reverts and all deposits are stuck.
    function test_Exploit_FeeAbove100PercentBricksWithdrawals() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.prank(owner, owner);
        vault.setFee(10_001);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdrawAll();

        assertEq(vault.balances(alice), 1 ether); // funds still locked
    }

    /// SV-05 impact: transfer() forwards only 2300 gas, so a contract
    /// recipient (e.g. a multisig) cannot receive the fees.
    function test_Exploit_ClaimFeesToContractRecipientReverts() public {
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        GasHungryReceiver multisig = new GasHungryReceiver();

        vm.prank(owner);
        vm.expectRevert();
        vault.claimFees(payable(address(multisig)));

        assertEq(vault.collectedFees(), 0.005 ether);
    }

    /// SV-06 impact: claimFees(address(0)) succeeds and burns the fees.
    function test_Exploit_ClaimFeesToZeroAddressBurnsFees() public {
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        uint256 burnedBefore = address(0).balance;

        vm.prank(owner);
        vault.claimFees(payable(address(0)));

        assertEq(vault.collectedFees(), 0);
        assertEq(address(0).balance, burnedBefore + 0.005 ether);
    }
}
