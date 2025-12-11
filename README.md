### Modular ERC-4626 Vault System
A production-grade, gas-optimized ERC-4626 compliant vault with multi-strategy yield generation.

###  Installation & Setup

```bash
# Clone the repository
git clone https://github.com/SDargarh/VaultSystem.git
cd VaultSystem

# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts

# Build contracts
forge build

# Run tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test test_deposit

# Run invariant tests
forge test --match-contract InvariantTests

# Check coverage
forge coverage

```