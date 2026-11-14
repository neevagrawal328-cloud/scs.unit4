// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SavingsVaultFixed
/// @notice Same public interface as SavingsVault, with the Part F findings fixed.
contract SavingsVaultFixed is ReentrancyGuard {
    uint256 public constant MAX_FEE_BPS = 500; // 5% cap (SV-03, SV-04)

    address public immutable owner; // SV-08: never changes after deployment
    uint256 public feeBps = 50; // 0.50%
    uint256 public collectedFees;
    mapping(address => uint256) public balances;

    error FeeTooHigh(uint256 requested, uint256 max);

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps); // SV-07
    event FeesClaimed(address indexed to, uint256 amount);

    /// SV-01: authenticate the direct caller, not tx.origin
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function deposit() external payable {
        require(msg.value > 0, "zero deposit");
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// SV-02: checks -> effects -> interactions, plus nonReentrant as defence in depth
    function withdrawAll() external nonReentrant {
        // Checks
        uint256 amount = balances[msg.sender];
        require(amount > 0, "nothing to withdraw");
        uint256 fee = (amount * feeBps) / 10_000;

        // Effects (all state changes and the event before the ETH leaves)
        balances[msg.sender] = 0;
        collectedFees += fee;
        emit Withdrawn(msg.sender, amount, fee);

        // Interaction
        (bool ok, ) = msg.sender.call{value: amount - fee}("");
        require(ok, "transfer failed");
    }

    /// SV-01, SV-03, SV-04, SV-07
    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        uint256 oldFeeBps = feeBps;
        feeBps = newFeeBps;
        emit FeeUpdated(oldFeeBps, newFeeBps);
    }

    /// SV-05, SV-06: reject address(0), send with a checked call, emit an event
    function claimFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 amount = collectedFees;
        collectedFees = 0;
        emit FeesClaimed(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }
}
