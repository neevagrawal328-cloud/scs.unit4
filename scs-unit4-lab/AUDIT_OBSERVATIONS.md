# SavingsVault: Mini Audit Observations (Part H)

Scope: `contracts/SavingsVault.sol` (solc 0.8.24). Fixed version: `contracts/SavingsVaultFixed.sol`.
Severity scale: Critical / High / Medium / Low / Informational.

| ID | Title | Severity | Status |
|---|---|---|---|
| SV-01 | `setFee` authenticates `tx.origin` instead of `msg.sender` | High | Fixed |
| SV-02 | Re-entrancy in `withdrawAll` lets an attacker drain other users' deposits | Critical | Fixed |
| SV-03 | `setFee` has no upper bound | Medium | Fixed |
| SV-04 | A fee above 100% makes every withdrawal revert (funds stuck) | High | Fixed |
| SV-05 | `claimFees` uses `transfer`, which fails for contract recipients | Low | Fixed |
| SV-06 | `claimFees` accepts `address(0)` and burns the fees | Low | Fixed |
| SV-07 | Fee changes emit no event | Informational | Fixed |
| SV-08 | `owner` is not `immutable` | Informational | Fixed |

---

### SV-01: `setFee` authenticates `tx.origin` instead of `msg.sender`
- **Severity:** High. Any contract the owner interacts with can change the fee, and a phishing call is cheap to set up.
- **Location:** `SavingsVault.setFee`, line 37.
- **Description:** `setFee` checks `require(tx.origin == owner)`. `tx.origin` is the account that started the transaction, not the account calling the function. If the owner calls any malicious contract (a fake airdrop, a token with a hook), that contract can call `setFee` and pass the check.
- **Impact:** An attacker can set the fee to 100%, and every user then loses their entire deposit on withdrawal. This lasts until the owner notices and resets the fee.
- **Evidence:** `test_Exploit_TxOriginPhishingSetsFeeTo100Percent` (alice withdraws 1 ETH and receives 0). `test_OwnerCanSetFee` fails while `test_OwnerCanSetFee_WhenOriginIsOwner` passes. Slither `tx-origin` (Medium/Medium).
- **Recommendation:** Add an `onlyOwner` modifier that checks `msg.sender == owner`.
- **Status:** Fixed in `SavingsVaultFixed.sol`. Proven by `test_OwnerCanSetFee` and `test_RevertWhen_SetFeeThroughHelperWithOwnerOrigin`.

### SV-02: Re-entrancy in `withdrawAll` lets an attacker drain other users' deposits
- **Severity:** Critical. Anyone can exploit it with a small deposit, and every user's funds are at risk.
- **Location:** `SavingsVault.withdrawAll`, lines 29–32.
- **Description:** `withdrawAll` sends ETH with `call` (line 29) before it sets `balances[msg.sender] = 0` (line 31). A contract recipient can re-enter `withdrawAll` from `receive()`. Each re-entry still sees the full balance and is paid again.
- **Impact:** With 10 ETH from alice in the vault, an attacker deposits 1 ETH and leaves with 10.945 ETH. The vault keeps 0.055 ETH but still owes alice 10 ETH. The loss is permanent.
- **Evidence:** `test_Exploit_ReentrancyDrainsVault` (11 entries, 10 re-entries). Slither `reentrancy-eth` (High/Medium).
- **Recommendation:** Update state and emit the event before the call (checks → effects → interactions). Add OpenZeppelin `nonReentrant` as defence in depth.
- **Status:** Fixed. Proven by `test_Fix_ReentrancyAttackReverts` (the attack reverts and the vault still holds 10 ETH).

### SV-03: `setFee` has no upper bound
- **Severity:** Medium. Only the owner (or a phished owner, see SV-01) can set it, but nothing stops a mistake or abuse.
- **Location:** `SavingsVault.setFee`, line 38.
- **Description:** Any `uint256` is accepted as `feeBps`, including values of 100% or more.
- **Impact:** Users can be charged any fee up to their entire deposit, for as long as the bad value stays set.
- **Evidence:** `test_Exploit_TxOriginPhishingSetsFeeTo100Percent`. Manual review. Slither does not report this.
- **Recommendation:** Add a constant `MAX_FEE_BPS = 500` and `revert FeeTooHigh(requested, max)` above it.
- **Status:** Fixed. Proven by `test_RevertWhen_SetFeeAboveMax` and `test_Fix_MaxFeeStillAllowsWithdrawals`.

### SV-04: A fee above 100% makes every withdrawal revert (funds stuck)
- **Severity:** High. All user funds become locked. Likelihood is lower because it needs an admin error or SV-01.
- **Location:** `SavingsVault.setFee` line 38, which causes the failure in `withdrawAll` line 29.
- **Description:** If `feeBps > 10_000`, then `fee > amount`, and `amount - fee` underflows. Solidity 0.8 checked arithmetic reverts with a panic, so no user can withdraw.
- **Impact:** All depositors' funds are frozen until the fee is lowered. The freeze is permanent if the owner key is lost.
- **Evidence:** `test_Exploit_FeeAbove100PercentBricksWithdrawals`. Manual review only: Slither does not report it, because it depends on business meaning that a pattern-matching tool can't see.
- **Recommendation:** Same cap as SV-03. With `MAX_FEE_BPS = 500`, the fee can never exceed the amount.
- **Status:** Fixed.

### SV-05: `claimFees` uses `transfer`, which fails for contract recipients
- **Severity:** Low. Only fee collection is affected, and the owner can pick another recipient.
- **Location:** `SavingsVault.claimFees`, line 45.
- **Description:** `transfer` forwards only 2300 gas. Recipients whose `receive()` writes storage, such as most multisigs and smart wallets, run out of gas, so the claim reverts.
- **Impact:** The owner cannot send fees to a contract treasury. The fees stay stuck until an EOA recipient is used. The problem is temporary.
- **Evidence:** `test_Exploit_ClaimFeesToContractRecipientReverts`.
- **Recommendation:** Send with `(bool ok, ) = to.call{value: amount}("")` followed by `require(ok)`. Update state first and use `nonReentrant`.
- **Status:** Fixed. Proven by `test_Fix_ClaimFeesToContractRecipientWorks`.

### SV-06: `claimFees` accepts `address(0)` and burns the fees
- **Severity:** Low. Only an owner mistake triggers it, but the loss is irreversible.
- **Location:** `SavingsVault.claimFees`, lines 41 and 45.
- **Description:** There is no check on `to`. Passing `address(0)` succeeds and sends the fees to an address no one controls.
- **Impact:** The owner permanently loses all collected fees.
- **Evidence:** `test_Exploit_ClaimFeesToZeroAddressBurnsFees`. Slither `missing-zero-check` (Low/Medium).
- **Recommendation:** Add `require(to != address(0), "zero address")`.
- **Status:** Fixed. Proven by `test_RevertWhen_ClaimFeesToZeroAddress`.

### SV-07: Fee changes emit no event
- **Severity:** Informational.
- **Location:** `SavingsVault.setFee`, line 38.
- **Description / Impact:** Off-chain monitors and users cannot see when the fee changes, so a malicious change (SV-01) goes unnoticed.
- **Evidence:** Slither `events-maths` (Low/Medium).
- **Recommendation:** Emit `FeeUpdated(oldFeeBps, newFeeBps)`.
- **Status:** Fixed. Proven by `vm.expectEmit` in `test_OwnerCanSetFee` (fixed tests).

### SV-08: `owner` is not `immutable`
- **Severity:** Informational (gas).
- **Location:** `SavingsVault`, line 7.
- **Description / Impact:** `owner` is never written after the constructor. Reading it from storage costs about 2100 gas when cold, compared with about 3 gas for an immutable.
- **Evidence:** Slither `immutable-states` (Optimization/High).
- **Recommendation:** Declare it `address public immutable owner`.
- **Status:** Fixed.

---

## Part E: Slither triage, SavingsVault (expected results)

| # | Detector | Impact / confidence | Location | Verdict | Reason |
|---|---|---|---|---|---|
| 1 | reentrancy-eth | High / Medium | withdrawAll, L29–32 | True positive | ETH sent before `balances = 0` (SV-02) |
| 2 | tx-origin | Medium / Medium | setFee, L37 | True positive | Phishing contract can pass the check (SV-01) |
| 3 | missing-zero-check | Low / Medium | claimFees, L45 | True positive | `address(0)` burns fees (SV-06) |
| 4 | events-maths | Low / Medium | setFee, L38 | True positive (low) | No event on fee change (SV-07) |
| 5 | low-level-calls | Informational / High | withdrawAll, L29 | Informational | `call` is intended and its result is checked |
| 6 | immutable-states | Optimization / High | owner, L7 | Informational | Gas only (SV-08) |
| 7 | solc-version | Informational / High | pragma, L2 | Informational | Course pins 0.8.24; its known compiler bugs don't affect this code |

Not reported by Slither and found only by the checklist: **SV-03, SV-04, SV-05**.

## Part G: Slither triage, SavingsVaultFixed (expected results)

| # | Detector | Verdict | Reason |
|---|---|---|---|
| 1 | low-level-calls (withdrawAll, claimFees) | Informational | `call` is now used on purpose so contract recipients work, and the return value is checked |
| 2 | solc-version | Informational | Course pins 0.8.24 |

`reentrancy-eth`, `tx-origin`, `missing-zero-check`, `events-maths` and `immutable-states` should no longer appear. If Slither prints anything else, triage it here.

## Checkpoint answers
- **C:** The fuzz input is random, so the test asserts a rule (payout + fee = deposit) that must hold for every amount, instead of one fixed expected value.
- **C (your turn):** `vm.prank(owner)` sets only `msg.sender`, so `tx.origin` is still the default test account and the `tx.origin == owner` check fails. `vm.prank(owner, owner)` also sets `tx.origin`, so it passes. That shows `setFee` authenticates the transaction originator, not the caller.
- **D:** `loadFixture` runs the deployment once, takes a snapshot of the chain, and restores that snapshot before each test. That's faster than redeploying, and every test starts from an identical state.
- **E:** SV-04 (and SV-03). Slither doesn't know that `feeBps` must be at most 10 000, or what counts as a sane fee. It matches code patterns and doesn't understand business meaning.
- **F:** Slither also found SV-01, SV-02, SV-06, SV-07 and SV-08. Only the checklist found SV-03, SV-04 and SV-05. The impact of each one is in its observation above.
