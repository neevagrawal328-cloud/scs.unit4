// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SavingsVaultFixed} from "../contracts/SavingsVaultFixed.sol";
import {VaultAttacker, FeeSetterHelper, GasHungryReceiver} from "./helpers/TestHelpers.sol";

/// Part G regression run: the Part C tests pointed at SavingsVaultFixed,
/// plus tests that prove each fix.
contract SavingsVaultFixedTest is Test {
    SavingsVaultFixed vault;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    function setUp() public {
        vm.prank(owner);
        vault = new SavingsVaultFixed();
        vm.deal(alice, 10 ether);
    }

    // ---------------------------------------------------------------
    // Part C tests, unchanged except for the contract type
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
        assertEq(vault.collectedFees(), 0);
    }

    // ---------------------------------------------------------------
    // Part G regression steps 2-4
    // ---------------------------------------------------------------

    /// Step 3: a plain vm.prank(owner) now works (msg.sender is checked).
    function test_OwnerCanSetFee() public {
        vm.expectEmit(address(vault));
        emit FeeUpdated(50, 100);

        vm.prank(owner);
        vault.setFee(100);
        assertEq(vault.feeBps(), 100);
    }

    /// Step 2: above the cap reverts with the custom error and its arguments.
    function test_RevertWhen_SetFeeAboveMax() public {
        uint256 tooHigh = vault.MAX_FEE_BPS() + 1;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(SavingsVaultFixed.FeeTooHigh.selector, tooHigh, vault.MAX_FEE_BPS())
        );
        vault.setFee(tooHigh);

        assertEq(vault.feeBps(), 50);
    }

    /// Step 4: a helper contract called while tx.origin == owner is rejected.
    function test_RevertWhen_SetFeeThroughHelperWithOwnerOrigin() public {
        FeeSetterHelper phishing = new FeeSetterHelper();

        vm.prank(owner, owner);
        vm.expectRevert(bytes("not owner"));
        phishing.setFeeOn(address(vault), 100);

        assertEq(vault.feeBps(), 50);
    }

    // ---------------------------------------------------------------
    // The same attacks as SavingsVault.t.sol, now failing
    // ---------------------------------------------------------------

    /// Re-entered withdrawAll() hits nonReentrant (and balance is already 0),
    /// so receive() reverts, the call returns false and the whole attack reverts.
    function test_Fix_ReentrancyAttackReverts() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();

        VaultAttacker attacker = new VaultAttacker(address(vault));
        address eve = makeAddr("eve");
        vm.deal(eve, 1 ether);

        vm.prank(eve);
        vm.expectRevert(bytes("transfer failed"));
        attacker.attack{value: 1 ether}();

        assertEq(address(vault).balance, 10 ether);
        assertEq(vault.balances(alice), 10 ether);
        assertEq(eve.balance, 1 ether);
    }

    function test_Fix_ClaimFeesToContractRecipientWorks() public {
        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        GasHungryReceiver multisig = new GasHungryReceiver();

        vm.prank(owner);
        vault.claimFees(payable(address(multisig)));

        assertEq(address(multisig).balance, 0.005 ether);
        assertEq(multisig.received(), 0.005 ether);
    }

    function test_RevertWhen_ClaimFeesToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("zero address"));
        vault.claimFees(payable(address(0)));
    }

    function test_Fix_MaxFeeStillAllowsWithdrawals() public {
        vm.prank(owner);
        vault.setFee(500); // the highest fee now possible

        vm.startPrank(alice);
        vault.deposit{value: 1 ether}();
        vault.withdrawAll();
        vm.stopPrank();

        assertEq(alice.balance, 9.95 ether);
    }
}
