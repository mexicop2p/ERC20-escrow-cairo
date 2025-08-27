# P2P Escrow Contract

A secure and flexible peer-to-peer escrow contract built on StarkNet using Cairo. This contract facilitates safe token transfers between buyers and sellers with a time-locked escrow mechanism and signature verification.

## Features

- **Token Deposits**: Secure token deposits with ERC20 support
- **Time-Locked Escrow**: Orders can be locked for a specified duration
- **Signature Verification**: Secure order locking with signature verification
- **Release & Refund**: Mechanisms for releasing funds to seller or refunding to buyer
- **Token Whitelisting**: Optional token whitelisting for enhanced security
- **Reentrancy Protection**: Built-in protection against reentrancy attacks
- **Owner Controls**: Administrative functions for contract management

## Contract Structure

The contract consists of the following main components:

- `P2PEscrow`: Main escrow contract with core functionality
- `MockERC20`: Test ERC20 token implementation
- Comprehensive test suite

## Getting Started

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/)
- [StarkNet Foundry](https://foundry-rs.github.io/starknet-foundry/)

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd p2p_escrow
   ```

2. Install dependencies:
   ```bash
   scarb build
   ```

3. Run tests:
   ```bash
   scarb test
   ```

## Usage

### Order Flow

1. **Deposit**
   ```cairo
   deposit(order_id: felt252, seller: ContractAddress, token: ContractAddress, amount: u256)
   ```
   Buyer deposits tokens into escrow.

2. **Lock Order**
   ```cairo
   lock_order(order_id: felt252, lock_duration: u64, proof_hash: felt252, signature: Array<felt252>)
   ```
   Lock the order with a time duration and signature verification.

3. **Release or Refund**
   ```cairo
   release(order_id: felt252)  // Release funds to seller
   refund(order_id: felt252)   // Refund to buyer after lock expiry
   ```

### Administrative Functions

- **Token Whitelisting**
  ```cairo
  set_whitelist_enabled(enabled: bool)
  whitelist_token(token: ContractAddress, whitelisted: bool)
  ```

- **Proof Signer Management**
  ```cairo
  update_proof_signer(new_signer: felt252)
  ```

## Security Features

1. **Reentrancy Protection**: Using OpenZeppelin's ReentrancyGuard
2. **Access Control**: Owner-only administrative functions
3. **Time Locks**: Secure release/refund mechanisms
4. **Signature Verification**: Secure order locking
5. **Token Whitelisting**: Optional token restriction

## Testing

The contract includes a comprehensive test suite covering:
- Order lifecycle (deposit, lock, release, refund)
- Token whitelisting functionality
- Administrative functions
- Edge cases and error conditions

Run tests with:
```bash
scarb test
```

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.