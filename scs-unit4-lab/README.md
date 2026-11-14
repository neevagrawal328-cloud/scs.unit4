# SCS Unit IV Lab: Testing, Static Analysis and Checklist Review

Hardhat 3 tests (Solidity + TypeScript), Slither triage, a manual checklist review, a fixed contract and a regression run for `SavingsVault`.

## Files

| File | Part | What it is |
|---|---|---|
| `contracts/SavingsVault.sol` | B | Contract under review (unchanged from the handout) |
| `contracts/SavingsVaultFixed.sol` | G | Fixed contract: `onlyOwner`, CEI + `nonReentrant`, fee cap, immutable owner, safe `claimFees` |
| `test/SavingsVault.t.sol` | C, F | Given tests, "Your turn" tests, and exploit tests that prove each finding |
| `test/SavingsVault.ts` | D | TypeScript integration tests (given + "Your turn") |
| `test/SavingsVaultFixed.t.sol` | G | Regression run against the fixed contract |
| `test/helpers/TestHelpers.sol` | C, G | Attacker, phishing helper and gas-hungry receiver used by the tests |
| `AUDIT_OBSERVATIONS.md` | E, F, G, H | Slither triage tables, audit observations SV-01 to SV-08, checkpoint answers |

## Steps (Windows, Command Prompt)

Use a folder **outside** `C:\Users\<you>` (your home folder has an old `hardhat.config.js` that confuses Hardhat).

```cmd
cd /d C:\dev
mkdir scs-unit4-lab
cd scs-unit4-lab
npx hardhat --init --template node-test-runner-viem
```
At the path prompt type `.` and accept the other defaults.

1. Delete the sample files: `contracts\Counter.sol`, `contracts\Counter.t.sol`, `test\Counter.ts`, `ignition\modules\Counter.ts`.
2. Install OpenZeppelin:
   ```cmd
   npm add --save-dev @openzeppelin/contracts
   ```
3. In `hardhat.config.ts`, replace only the `solidity` field with:
   ```ts
   solidity: {
     version: "0.8.24",
     settings: {
       optimizer: { enabled: true, runs: 200 },
     },
   },
   ```
4. Copy this repo's `contracts\`, `test\`, `README.md` and `AUDIT_OBSERVATIONS.md` into the project.
5. Build and test:
   ```cmd
   npx hardhat build
   npx hardhat test solidity
   npx hardhat test nodejs
   npx hardhat test
   ```

### Expected result
Every test passes **except** `SavingsVaultTest#test_OwnerCanSetFee`. That one is meant to fail on the original contract: it is the evidence for SV-01 (the `tx.origin` check). Its twin `test_OwnerCanSetFee_WhenOriginIsOwner` passes, and on the fixed contract `test_OwnerCanSetFee` passes with a plain `vm.prank(owner)`.

If `forge-std/Test.sol` cannot be found:
```cmd
npm add --save-dev "github:foundry-rs/forge-std#v1.9.7"
```

## Slither (Part E and Part G step 5)
Slither needs Python and, on Windows, the handout says to run it inside **WSL** (Ubuntu). From the project folder in WSL (`cd /mnt/c/dev/scs-unit4-lab`):
```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade "slither-analyzer>=0.11.6"
slither --version

slither . --filter-paths "node_modules|test"
slither . --filter-paths "node_modules|test" --print human-summary
slither . --filter-paths "node_modules|test" --checklist > slither-report.md
```
If Slither can't compile, run `npx hardhat build` first (it must succeed), then add `--hardhat-ignore-compile`.

Compare its output with the expected triage in `AUDIT_OBSERVATIONS.md` and correct any rows that differ.
