# MexicoP2P Escrow Contract

A secure peer-to-peer escrow smart contract for the Mexican crypto market, built on Starknet using Cairo. This contract facilitates trustless SPEI-to-crypto trades with CEP (Comprobante Electronico de Pago) validation.

[![Security Audit](https://img.shields.io/badge/Security-Audited-green)](https://github.com/mexicop2p/ERC20-escrow-cairo/issues/2)
[![Starknet](https://img.shields.io/badge/Starknet-Mainnet-blue)](https://voyager.online/contract/0x021b47dd0cf4a1b9a5d8ca8e04d4b29056146c6938f9604d87cf0418c1ec8632)
[![Cairo](https://img.shields.io/badge/Cairo-2.10.1-orange)](https://www.cairo-lang.org/)

## Deployment

| Network | Contract Address | Explorer |
|---------|------------------|----------|
| **Mainnet** | `0x021b47dd0cf4a1b9a5d8ca8e04d4b29056146c6938f9604d87cf0418c1ec8632` | [Voyager](https://voyager.online/contract/0x021b47dd0cf4a1b9a5d8ca8e04d4b29056146c6938f9604d87cf0418c1ec8632) |

### Whitelisted Tokens

| Token | Address | Decimals |
|-------|---------|----------|
| USDC (Native) | `0x033068F6539f8e6e6b131e6B2B814e6c34A5224bC66947c47DaB9dFeE93b35fb` | 6 |
| USDC.e (Bridged) | `0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8` | 6 |
| WBTC | `0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac` | 8 |

---

## Features

- **5-State Machine**: Open, Locked, Released, Refunded, Disputed
- **ECDSA Signature Verification**: Cryptographically secure release mechanism using `check_ecdsa_signature`
- **On-Chain Dispute Resolution**: Arbiter-based dispute handling with transparent resolution
- **Multi-Token Whitelist**: Support for USDC, WBTC, and extensible to other ERC20 tokens
- **Emergency Pause**: Owner can pause all operations in case of emergency
- **Reentrancy Protection**: All critical functions protected against reentrancy attacks
- **Minimum Lock Duration**: 5-minute minimum prevents griefing attacks

---

## Architecture

```
+------------------+     +-------------------+     +------------------+
|                  |     |                   |     |                  |
|  MexicoP2P Web   |---->|  Backend API      |---->|  Starknet        |
|  (Next.js)       |     |  (CEP Validator)  |     |  Escrow Contract |
|                  |     |                   |     |                  |
+------------------+     +-------------------+     +------------------+
        |                        |                        |
        |   1. Submit CEP        |                        |
        |----------------------->|                        |
        |                        |                        |
        |   2. Validate via      |                        |
        |      Banxico API       |                        |
        |                        |                        |
        |   3. Generate ECDSA    |                        |
        |      Signature         |                        |
        |<-----------------------|                        |
        |                        |                        |
        |   4. Call release()    |                        |
        |      with signature    |                        |
        |------------------------------------------------>|
        |                        |                        |
        |   5. Verify signature  |                        |
        |      & transfer funds  |                        |
        |<------------------------------------------------|
```

---

## Order State Machine

```
                              +-------------+
                              |             |
                    deposit() |    OPEN     |
          +------------------>|     (0)     |
          |                   |             |
          |                   +------+------+
          |                          |
          |                          | lockOrder()
          |                          v
          |                   +-------------+
          |                   |             |
          |                   |   LOCKED    |<-----------+
          |                   |     (1)     |            |
          |                   |             |            |
          |                   +------+------+            |
          |                          |                   |
          |         +----------------+----------------+  |
          |         |                |                |  |
          |         v                v                v  |
          |  +-------------+  +-------------+  +-------------+
          |  |             |  |             |  |             |
          |  |  RELEASED   |  |  REFUNDED   |  |  DISPUTED   |
          |  |     (2)     |  |     (3)     |  |     (4)     |
          |  |             |  |             |  |             |
          |  +-------------+  +-------------+  +------+------+
          |                                          |
          |                         resolveDispute() |
          |                                          v
          |                                   Winner receives
          |                                   funds (Released
          |                                   or Refunded)
          |
     [Seller]
```

### State Transitions

| From | To | Function | Caller | Conditions |
|------|-----|----------|--------|------------|
| - | Open | `deposit()` | Seller | Token whitelisted, amount > 0 |
| Open | Locked | `lockOrder()` | Buyer | Duration: 5min - 24h |
| Locked | Released | `release()` | Buyer | Valid ECDSA signature |
| Locked | Refunded | `refund()` | Seller/Owner | Lock expired (seller) or anytime (owner) |
| Locked | Disputed | `openDispute()` | Buyer/Seller | Order is locked |
| Disputed | Released/Refunded | `resolveDispute()` | Arbiter | Winner = buyer or seller |

---

## Security Model

### Signature Verification Flow

```
+------------------+                              +------------------+
|                  |                              |                  |
|  Buyer submits   |   1. CEP image/data         |  Backend         |
|  payment proof   |----------------------------->|  Validates CEP   |
|                  |                              |  via Banxico     |
+------------------+                              +--------+---------+
                                                          |
                                                          | 2. Valid CEP
                                                          v
                                                 +------------------+
                                                 |                  |
                                                 |  Generate hash:  |
                                                 |  Pedersen(       |
                                                 |    contract,     |
                                                 |    order_id,     |
                                                 |    proof_hash,   |
                                                 |    token,        |
                                                 |    amount,       |
                                                 |    seller,       |
                                                 |    buyer         |
                                                 |  )               |
                                                 +--------+---------+
                                                          |
                                                          | 3. Sign with
                                                          |    private key
                                                          v
+------------------+                              +------------------+
|                  |   4. (sig_r, sig_s)         |                  |
|  Buyer calls     |<-----------------------------|  Return          |
|  release()       |                              |  signature       |
|                  |                              |                  |
+--------+---------+                              +------------------+
         |
         | 5. Contract verifies
         v
+------------------+
|                  |
|  check_ecdsa_    |
|  signature(      |
|    message_hash, |
|    proof_signer, |  <-- Public key stored in contract
|    sig_r,        |
|    sig_s         |
|  )               |
|                  |
+--------+---------+
         |
         | 6. Valid? Transfer funds
         v
+------------------+
|                  |
|  Funds released  |
|  to buyer        |
|                  |
+------------------+
```

### Fraud Prevention Matrix

| Attack Vector | Protection | Implementation |
|--------------|------------|----------------|
| Fake payment proof | CEP validation via Banxico API | Backend validates before signing |
| Signature forgery | ECDSA cryptography | `check_ecdsa_signature()` in Cairo |
| Replay attack | Unique proof_hash per transaction | Hash includes order details |
| Reentrancy | Custom guard | `_set_reentrancy()` / `_clear_reentrancy()` |
| Griefing (short locks) | Minimum duration | `MIN_LOCK_DURATION = 300` (5 min) |
| Fund theft | On-chain escrow | Funds locked in contract until release |
| Unauthorized release | Signature required | Only valid signatures from proof_signer |
| Seller abandonment | Dispute mechanism | Arbiter can force release to buyer |

---

## Contract Interface

### Core Functions

```cairo
// Seller deposits tokens into escrow (creates order)
fn deposit(order_id: felt252, token: ContractAddress, amount: u256)

// Buyer locks an open order (starts the trade timer)
fn lockOrder(order_id: felt252, duration_seconds: u64)

// Buyer releases funds with valid signature from backend
fn release(order_id: felt252, sig_r: felt252, sig_s: felt252)

// Seller refunds after lock expires (or owner anytime for emergency)
fn refund(order_id: felt252)

// Query order details
fn orders(order_id: felt252) -> Order
```

### Dispute Functions

```cairo
// Buyer or seller opens a dispute on a locked order
fn openDispute(order_id: felt252)

// Arbiter resolves dispute (winner receives funds)
fn resolveDispute(order_id: felt252, winner: ContractAddress)

// Arbiter management (owner-only)
fn addArbiter(arbiter: ContractAddress)
fn removeArbiter(arbiter: ContractAddress)
fn isArbiter(address: ContractAddress) -> bool
```

### Token Whitelist (Owner-only)

```cairo
fn add_allowed_token(token: ContractAddress)
fn remove_allowed_token(token: ContractAddress)
fn is_token_allowed(token: ContractAddress) -> bool
```

### Administrative Functions

```cairo
fn update_proof_signer(new_signer: felt252)
fn transfer_ownership(new_owner: ContractAddress)
fn pause()
fn unpause()
fn is_paused() -> bool
fn get_owner() -> ContractAddress
fn get_proof_signer() -> felt252
```

---

## Events

```cairo
OrderCreated { order_id, seller, token, amount }
OrderLocked { order_id, buyer, lock_expiry }
OrderReleased { order_id, buyer, token, amount }
OrderRefunded { order_id, seller, token, amount }
DisputeOpened { order_id, opened_by }
DisputeResolved { order_id, arbiter, winner }
OwnershipTransferred { previous_owner, new_owner }
ProofSignerUpdated { previous_signer, new_signer }
Paused { account }
Unpaused { account }
TokenAdded { token }
TokenRemoved { token }
ArbiterAdded { arbiter }
ArbiterRemoved { arbiter }
```

---

## Getting Started

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) v2.10.1+
- [Starkli](https://github.com/xJonathanLEI/starkli) v0.4.0+ for deployment
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) for testing

### Installation

```bash
git clone https://github.com/mexicop2p/ERC20-escrow-cairo.git
cd ERC20-escrow-cairo
scarb build
```

### Run Tests

```bash
scarb cairo-test
```

Expected output: **18 tests passing**

### Test Coverage

The contract includes comprehensive unit tests covering all critical functionality:

| Test | Description |
|------|-------------|
| `test_order_status_enum` | Validates OrderStatus enum values (0-4) |
| `test_five_state_transitions` | Verifies valid state transition paths |
| `test_lockOrder_duration_constants` | Confirms MIN=300s, MAX=86400s |
| `test_lockOrder_min_duration_validation` | Rejects duration < 5 minutes |
| `test_lockOrder_max_duration_validation` | Rejects duration > 24 hours |
| `test_release_requires_locked_status` | Release only works on Locked orders |
| `test_buyer_cannot_be_seller` | Prevents self-trading |
| `test_openDispute_only_locked_orders` | Disputes only on Locked status |
| `test_resolveDispute_winner_validation` | Winner must be buyer or seller |
| `test_multi_token_whitelist` | Multiple tokens can be whitelisted |
| `test_refund_after_lock_expiry` | Lock expiry calculation correctness |
| `test_message_computation_with_domain` | Domain separation in message hash |
| `test_signature_array_format` | Signature uses (r, s) components |
| `test_reentrancy_guard_states` | Guard toggle: 0=unlocked, 1=locked |
| `test_arbiter_authorization` | Only arbiters can resolve disputes |
| `test_dispute_resolution_outcomes` | Correct fund distribution on resolution |
| `test_proof_hash_uniqueness` | Proof hash derived from signature |
| `test_emergency_pause_states` | Pause functionality validation |

---

## Deployment Guide

### 1. Build

```bash
scarb build
```

### 2. Declare

```bash
starkli declare target/dev/mexicop2p_MexicoP2P.contract_class.json \
  --rpc <RPC_URL> \
  --account <ACCOUNT_FILE> \
  --private-key <PRIVATE_KEY>
```

### 3. Deploy

```bash
starkli deploy <CLASS_HASH> \
  <OWNER_ADDRESS> \
  <PROOF_SIGNER_PUBKEY> \
  --rpc <RPC_URL> \
  --account <ACCOUNT_FILE> \
  --private-key <PRIVATE_KEY>
```

**Constructor Parameters:**
- `owner`: Contract owner address (can pause, add tokens, add arbiters)
- `proof_signer`: Public key for signature verification (from your backend signer)

### 4. Configure Tokens

```bash
# Add USDC
starkli invoke <CONTRACT> add_allowed_token \
  0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8

# Add WBTC
starkli invoke <CONTRACT> add_allowed_token \
  0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac
```

### 5. Add Arbiter(s)

```bash
starkli invoke <CONTRACT> addArbiter <ARBITER_ADDRESS>
```

---

## Integration with MexicoP2P Platform

This contract is designed to work with the [MexicoP2P](https://github.com/mexicop2p/mexicop2p) platform:

### Environment Variables

```env
# Contract address
NEXT_PUBLIC_ESCROW_CONTRACT_ADDRESS=0x021b47dd0cf4a1b9a5d8ca8e04d4b29056146c6938f9604d87cf0418c1ec8632
ESCROW_CONTRACT_ADDRESS=0x021b47dd0cf4a1b9a5d8ca8e04d4b29056146c6938f9604d87cf0418c1ec8632

# Signer keys (for backend signature generation)
ESCROW_SIGNER_PRIVATE_KEY=0x...
ESCROW_SIGNER_PUBLIC_KEY=0x...

# Arbiter (for dispute resolution)
ARBITER_ADDRESS=0x...
```

### Integration Points

| Component | Integration |
|-----------|-------------|
| **Frontend** | Calls `deposit`, `lockOrder`, `release`, `refund` via Starknet.js |
| **Backend** | Validates CEP and generates signatures at `/api/proof-of-payment/verify` |
| **Database** | Tracks order state in PostgreSQL with Prisma (escrowStatus field) |
| **Admin Panel** | Manages disputes, views arbiter actions |

---

## Security Audit Resolution

This contract addresses all findings from the [Security Audit Report (Issue #2)](https://github.com/mexicop2p/ERC20-escrow-cairo/issues/2):

| Finding | Severity | Status | Resolution |
|---------|----------|--------|------------|
| C-1: Placeholder Signature | Critical | **FIXED** | Implemented real `check_ecdsa_signature()` |
| C-2: Poseidon vs Keccak256 | Critical | **DOCUMENTED** | Uses Pedersen (Starknet native) |
| H-1: ERC20 Return Value | High | **FIXED** | Interface defined without bool returns |
| H-2: Reentrancy Guard | High | **FIXED** | Proper guard implementation |
| H-3: No Min Lock Duration | High | **FIXED** | `MIN_LOCK_DURATION = 300` (5 min) |
| M-3: Emergency Pause | Medium | **FIXED** | `pause()` / `unpause()` implemented |

### Additional Security Features Added

- **Dispute Resolution**: On-chain arbiter system for handling conflicts
- **Multi-Token Whitelist**: Only approved tokens can be deposited
- **5-State Machine**: Clear state transitions prevent invalid operations
- **Comprehensive Events**: Full audit trail for all actions

---

## Access Control

| Role | Permissions |
|------|-------------|
| **Owner** | Pause/unpause, add/remove tokens, add/remove arbiters, update proof_signer, emergency refund |
| **Arbiter** | Resolve disputes |
| **Seller** | Deposit tokens, refund after lock expires |
| **Buyer** | Lock orders, release with signature, open disputes |

---

## License

MIT

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## Links

- [MexicoP2P Platform](https://github.com/mexicop2p/mexicop2p)
- [Security Audit Report](https://github.com/mexicop2p/ERC20-escrow-cairo/issues/2)
- [Starknet Documentation](https://docs.starknet.io/)
- [Cairo Language](https://www.cairo-lang.org/)
