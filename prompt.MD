### ✨ TASK

Convert the Solidity contract below into a **single‑file Cairo 1** implementation for Starknet.

* Preserve the external API (function names, params, events).
* Re‑implement business logic 1‑for‑1, adjusting only where Cairo semantics differ.
* Optimise for clarity over micro‑gas; follow current Cairo best‑practices.

---

### 📜 Solidity Source (start)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title P2PEscrow
 * @notice Trust‑minimised escrow contract for peer‑to‑peer token‑for‑fiat trades (e.g. USDC ⇄ MXN via SPEI).
 * @dev    Lifecycle: `deposit → lockOrder → (release | refund)`
 *          1. Seller deposits any ERC‑20 token (optional whitelist enforced).
 *          2. Buyer locks the order while sending fiat off‑chain.
 *          3. Backend (off‑chain) validates SPEI and signs a proof; anyone can call `release`.
 *          4. If unpaid or lock expires, seller calls `refund`.
 *        Gas‑optimisations: packed struct, storage refund, custom errors.
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract P2PEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    /* -------------------------------------------------------------------------- */
    /*                                   ERRORS                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice Order identifier already used.
    error OrderExists();
    /// @notice Amount must be greater than zero.
    error ZeroAmount();
    /// @notice Amount exceeds the 42 400 MXN KYC limit.
    error KycLimit();
    /// @notice ERC‑20 token not on the whitelist.
    error TokenNotAllowed();
    /// @notice Order does not exist.
    error OrderNotFound();
    /// @notice Caller is not the seller for this order.
    error NotSeller();
    /// @notice Order is already locked by a buyer.
    error AlreadyLocked();
    /// @notice Lock duration beyond the maximum allowed.
    error LockTooLong();
    /// @notice Lock period has not yet expired.
    error LockActive();
    /// @notice Provided signature is invalid or from wrong signer.
    error SignatureInvalid();
    /// @notice Invalid order status for this operation.
    error InvalidStatus();
    /// @notice Message digest has already been used (replay protection).
    error ProofAlreadyUsed();

    /* -------------------------------------------------------------------------- */
    /*                                   EVENTS                                   */
    /* -------------------------------------------------------------------------- */

    /// @notice Emitted when a new order is created.
    event OrderCreated(bytes32 indexed id, address indexed seller, uint128 amount, address indexed token);
    /// @notice Emitted when an order is locked by a buyer.
    event OrderLocked(bytes32 indexed id, address indexed buyer, uint64 lockExpiry);
    /// @notice Emitted when tokens are released to the buyer.
    event OrderReleased(bytes32 indexed id, address indexed buyer);
    /// @notice Emitted when tokens are refunded to the seller.
    event OrderRefunded(bytes32 indexed id);
    /// @notice Emitted when backend signer is rotated.
    event ProofSignerUpdated(address indexed newSigner);
    /// @notice Emitted when an ECDSA proof hash is consumed (replay protection).
    event ProofConsumed(bytes32 indexed proofHash);
    /// @notice Emitted when whitelist status or a token entry is changed.
    event TokenWhitelistSet(address indexed token, bool allowed);

    /* -------------------------------------------------------------------------- */
    /*                                   STRUCTS                                  */
    /* -------------------------------------------------------------------------- */

    /**
     * @dev Packed order struct fits in two storage slots (32B each).
     * seller (20) | status (1) | padding (11)   = 32B slot‑0
     * buyer  (20) | token (20) | amount (16) | lockExpiry (8)  => not fully packed so amount+lockExpiry overflow to slot‑2
     * For simplicity we accept the 3‑slot layout; gas impact is negligible relative to clarity.
     */
    struct Order {
        address seller;     // 20 bytes
        address buyer;      // 20 bytes
        address token;      // 20 bytes
        uint128 amount;     // 16 bytes
        uint64  lockExpiry; // 8  bytes (unix seconds)
        uint8   status;     // 1  byte (cast of enum)
    }

    /// @notice Enum representing order lifecycle stages.
    enum OrderStatus { Available, Locked, Completed, Refunded }

    /* -------------------------------------------------------------------------- */
    /*                               STATE VARIABLES                              */
    /* -------------------------------------------------------------------------- */

    /// @dev Mapping orderId → Order metadata.
    mapping(bytes32 => Order) public orders;

    /// @dev Mapping of used proof hashes to prevent replay.
    mapping(bytes32 => bool) public usedProof;

    /// @notice Backend address allowed to sign off‑chain payment proofs.
    address public proofSigner;

    /// @notice Whitelisted ERC‑20 tokens. If `whitelistEnabled=false`, all tokens allowed.
    mapping(address => bool) public allowedTokens;
    bool public whitelistEnabled;

    /// @notice Maximum lock duration in seconds (immutable).
    uint256 public immutable MAX_LOCK_DURATION;

    /// @notice Max deposit per KYC (token native units) — e.g., 32 400 MXN.
    uint256 public immutable MXN_KYC_LIMIT;

    /* -------------------------------------------------------------------------- */
    /*                                 CONSTRUCTOR                                */
    /* -------------------------------------------------------------------------- */

    /**
     * @param _proofSigner   Initial backend signer address.
     * @param _maxLockSecs   Maximum seconds a buyer can lock an order.
     * @param _kycLimit      Deposit ceiling bypassing KYC (token‑native units).
     */
    constructor(address _proofSigner, uint256 _maxLockSecs, uint256 _kycLimit) Ownable(msg.sender) {
        proofSigner = _proofSigner;
        MAX_LOCK_DURATION = _maxLockSecs;
        MXN_KYC_LIMIT = _kycLimit;
    }

    /* -------------------------------------------------------------------------- */
    /*                            EXTERNAL USER ACTIONS                           */
    /* -------------------------------------------------------------------------- */

    /**
     * @notice Seller deposits `amount` of `token`, opening an order.
     * @dev    Requires prior `approve` from seller to this contract.
     * @param id      Unique order identifier (recommended: salted UUID).
     * @param amount  Amount of `token` to escrow.
     * @param token   ERC‑20 token address.
     *
     * Emits {OrderCreated}.
     *
     * Requirements:
     *  - `amount` > 0.
     *  - `amount` ≤ `MXN_KYC_LIMIT`.
     *  - `id` must not already exist.
     *  - If whitelist enabled, `token` must be allowed.
     */
    function deposit(bytes32 id, uint128 amount, address token) external nonReentrant {
        if (orders[id].seller != address(0)) revert OrderExists();
        if (amount == 0) revert ZeroAmount();
        if (amount > MXN_KYC_LIMIT) revert KycLimit();
        if (whitelistEnabled && !allowedTokens[token]) revert TokenNotAllowed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        orders[id] = Order({
            seller: msg.sender,
            buyer: address(0),
            token: token,
            amount: amount,
            lockExpiry: 0,
            status: uint8(OrderStatus.Available)
        });

        emit OrderCreated(id, msg.sender, amount, token);
    }

    /**
     * @notice Buyer locks an available order for `duration` seconds to send fiat.
     * @param id        Order identifier.
     * @param duration  Desired lock duration (≤ `MAX_LOCK_DURATION`).
     *
     * Emits {OrderLocked}.
     *
     * Requirements:
     *  - Order must exist and be `Available`.
     *  - `duration` > 0 and ≤ `MAX_LOCK_DURATION`.
     */
    function lockOrder(bytes32 id, uint64 duration) external nonReentrant {
        Order storage o = orders[id];
        if (o.seller == address(0)) revert OrderNotFound();
        if (o.status != uint8(OrderStatus.Available)) revert AlreadyLocked();
        if (duration == 0 || duration > MAX_LOCK_DURATION) revert LockTooLong();

        o.buyer = msg.sender;
        o.lockExpiry = uint64(block.timestamp + duration);
        o.status = uint8(OrderStatus.Locked);

        emit OrderLocked(id, msg.sender, o.lockExpiry);
    }

    /**
     * @notice Releases tokens to the buyer once backend proof is verified.
     * @dev    Anyone can call; prevents DoS if seller/buyer are offline.
     * @param id   Order identifier.
     * @param sig  ECDSA signature from `proofSigner` over `(id,buyer,amount,token)`.
     *
     * Emits {OrderReleased} and {ProofConsumed}.
     *
     * Requirements:
     *  - Order status must be `Locked`.
     *  - Valid signature.
     *  - Proof hash unused.
     */
    function release(bytes32 id, bytes calldata sig) external nonReentrant {
        Order storage o = orders[id];
        if (o.status != uint8(OrderStatus.Locked)) revert OrderNotFound();

        bytes32 digest = keccak256(abi.encodePacked(id, o.buyer, o.amount, o.token)).toEthSignedMessageHash();
        bytes32 proofHash = keccak256(sig);
        if (usedProof[proofHash]) revert ProofAlreadyUsed();
        if (digest.recover(sig) != proofSigner) revert SignatureInvalid();

        usedProof[proofHash] = true;
        emit ProofConsumed(proofHash);

        IERC20(o.token).safeTransfer(o.buyer, o.amount);
        emit OrderReleased(id, o.buyer);

        delete orders[id]; // storage refund
    }

    /**
     * @notice Refunds tokens back to seller if order not completed.
     * @param id Order identifier.
     *
     * Emits {OrderRefunded}.
     *
     * Requirements:
     *  - Caller must be seller.
     *  - Either (a) order is `Available`, or (b) `Locked` and lock has expired.
     */
    function refund(bytes32 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.seller == address(0)) revert OrderNotFound();
        if (msg.sender != o.seller) revert NotSeller();

        if (o.status == uint8(OrderStatus.Locked)) {
            if (block.timestamp < o.lockExpiry) revert LockActive();
        } else if (o.status != uint8(OrderStatus.Available)) {
            revert InvalidStatus();
        }

        o.status = uint8(OrderStatus.Refunded);
        IERC20(o.token).safeTransfer(o.seller, o.amount);
        emit OrderRefunded(id);
        delete orders[id];
    }

    /**
     * @notice Updates backend signer address.
     * @param newSigner New signer address.
     */
    function updateProofSigner(address newSigner) external onlyOwner {
        proofSigner = newSigner;
        emit ProofSignerUpdated(newSigner);
    }

    /**
     * @notice Enables or disables the token whitelist.
     * @param enabled True to enforce whitelist, false to allow all tokens.
     */
    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
    }

    /**
     * @notice Adds or removes a token from the whitelist.
     * @param token   ERC‑20 token address.
     * @param allowed True to allow, false to disallow.
     */
    function whitelistToken(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
        emit TokenWhitelistSet(token, allowed);
    }
}
```

### 📜 Solidity Source (end)

---

### 🧩 Provide example user‑inputs (when relevant)

If any external/public function accepts free‑form or ambiguous payloads (e.g. `bytes`, `string`, dynamic arrays, mixed structs), add **2 – 3 representative examples** **immediately below** ­— formatted as **JSON snippets**.

```json
{
  "deposit": {
    "id": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
    "amount": "1000000000000000000",
    "token": "0x02c79fa123456789abcdef0123456789abcdef0123456789abcdef01234567"
  },
  "lockOrder": {
    "id": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
    "duration": 1800
  },
  "release": {
    "id": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
    "sig": "0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  },
  "refund": {
    "id": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
  },
  "updateProofSigner": {
    "newSigner": "0x0519c3f0456789abcdef0123456789abcdef0123456789abcdef0123456789"
  },
  "setWhitelistEnabled": {
    "enabled": true
  },
  "whitelistToken": {
    "token": "0x02c79fa123456789abcdef0123456789abcdef0123456789abcdef01234567",
    "allowed": true
  }
}

```

These help the generator infer the correct Cairo types and packing strategy.

---

### 🛠 DELIVERABLE

Return **only** the Cairo file contents — no extra prose:

1. **File name:** `<originalName>.cairo` (snake\_case).
2. Builds cleanly with the latest toolchain (`scarb build`).
3. No TODOs or placeholders; concise inline docstrings are fine.

---

### ⚙️ REQUIREMENTS

| Topic                 | Requirement                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Syntax**            | Cairo 1                                                                                                       |
| **Imports**           | Use OpenZeppelin‑Cairo ≥ **0.13.0** when an analogue exists (Ownable, IERC20, non\_reentrant, Mapping, etc.). |
| **Storage**           | Mirror Solidity structs/enums in `#[storage] struct Storage { … }` or OZ `Mapping`s.                          |
| **Errors**            | Convert custom errors to `#[derive(Error)]` enums **or** `panic_with_reason("ErrorName")` — names must match. |
| **Events**            | Re‑declare every Solidity event as a `#[event]` struct with the same field order & names.                     |
| **Type widths**       | Use `Uint256` for token amounts & large counters; `u8`/`u64` for small fields & timestamps.                   |
| **Re‑entrancy**       | Protect mutating externals with `@non_reentrant`.                                                             |
| **Ownership**         | Implement `only_owner` gating via OZ `Ownable`.                                                               |
| **Hash & Sig checks** | *EVM sigs:* `starknet_keccak` + `verify_eth_signature`.<br>*Starknet sigs:* `ecdsa::verify`.                  |
| **Time**              | Replace `block.timestamp` with `get_block_timestamp()`.                                                       |
| **Storage refunds**   | Where Solidity does `delete`, call `.pop(key)` (or equivalent) to reclaim fees.                               |
| **Constants**         | Solidity `immutable` → Cairo `const` or constructor‑set storage vars, whichever preserves behaviour.          |

---

### 🏗 STRUCTURE GUIDE

1. **Imports & `use` statements**
2. `#[storage] struct Storage`
3. Custom error enum (`#[derive(Error)]`)
4. `#[event]` structs
5. User‑defined enums / helper structs
6. **Contract impl block**

   * `constructor( … )`
   * External/public functions (keep Solidity order)
   * Internal helpers
7. Optional snforge unit‑test stubs under `#[cfg(test)]`

---

### 🟢 ACCEPTANCE CRITERIA

* `scarb build` prints zero warnings.
* Function selectors & event topic hashes are byte‑identical to the Solidity originals.
* All revert paths mirror Solidity behaviour in snforge tests.
* README stays clean — no additional commentary beyond this template.

---

## 📦 Reference `Scarb.toml` snippet (latest versions — July 2025)

```toml
[package]
name    = "translated_contract"
version = "0.1.0"
edition = "2024_07"

[dependencies]
# Core Cairo / Starknet (Keccak, secp256k1, ECDSA helpers, etc.)
starknet = ">=2.11.4"           # use the latest stable tag

# OpenZeppelin Cairo contracts (Ownable, IERC20, non_reentrant, Mapping…)
openzeppelin = { git = "https://github.com/OpenZeppelin/cairo-contracts.git", tag = "v2.0.0" }

# (Add any extra libs the generator requires here)
```

> **Tip:** always run `scarb update` before compiling to pull the newest minor releases.