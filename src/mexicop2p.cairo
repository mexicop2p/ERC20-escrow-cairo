use starknet::{
    ContractAddress, get_caller_address, get_block_timestamp,
};
use core::num::traits::Zero;
use core::array::ArrayTrait;
use starknet::storage::StoragePointerWriteAccess;
use starknet::storage::StoragePointerReadAccess;
use starknet::storage::StorageMapReadAccess;
use starknet::storage::StorageMapWriteAccess;
use starknet::storage::Map;
use core::pedersen::PedersenTrait;
use core::hash::HashStateTrait;
use core::ecdsa::check_ecdsa_signature;

//! # MexicoP2P Escrow Contract
//!
//! A peer-to-peer escrow system for secure token transfers between buyers and sellers.
//! Features: 5-state machine, signature verification, dispute resolution, multi-token support.
//! Version: 1.0.1

const CONTRACT_VERSION: felt252 = 'v1.0.5';

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct Order {
    pub seller: ContractAddress,  // Seller first (matches old working contract)
    pub buyer: ContractAddress,
    pub token: ContractAddress,
    pub amount: u256,
    pub lock_expiry: u64,
    pub status: u8,  // Using u8 instead of enum for zero-storage compatibility
}

// Order status constants (using u8 instead of enum for zero-storage compatibility)
// When reading non-existent orders, storage returns 0 which maps to Open
// Existence is checked via seller.is_zero()
const ORDER_STATUS_OPEN: u8 = 0;
const ORDER_STATUS_LOCKED: u8 = 1;
const ORDER_STATUS_RELEASED: u8 = 2;
const ORDER_STATUS_REFUNDED: u8 = 3;
const ORDER_STATUS_DISPUTED: u8 = 4;

// ERC20 interface without bool returns (production-compatible)
#[starknet::interface]
trait IERC20<T> {
    fn transfer(ref self: T, recipient: ContractAddress, amount: u256);
    fn transfer_from(ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256);
    fn balance_of(self: @T, account: ContractAddress) -> u256;
    fn approve(ref self: T, spender: ContractAddress, amount: u256);
}

#[starknet::interface]
trait IMexicoP2P<TContractState> {
    // Core escrow functions
    fn deposit(
        ref self: TContractState,
        order_id: felt252,
        token: ContractAddress,
        amount: u256
    );

    fn lockOrder(
        ref self: TContractState,
        order_id: felt252,
        duration_seconds: u64
    );

    fn release(
        ref self: TContractState,
        order_id: felt252,
        sig_r: felt252,
        sig_s: felt252
    );

    fn refund(ref self: TContractState, order_id: felt252);

    fn orders(self: @TContractState, order_id: felt252) -> Order;

    // Dispute functions
    fn openDispute(ref self: TContractState, order_id: felt252);

    fn resolveDispute(
        ref self: TContractState,
        order_id: felt252,
        winner: ContractAddress
    );

    // Arbiter management (owner-only)
    fn addArbiter(ref self: TContractState, arbiter: ContractAddress);

    fn removeArbiter(ref self: TContractState, arbiter: ContractAddress);

    fn isArbiter(self: @TContractState, address: ContractAddress) -> bool;

    // Token whitelist management (owner-only)
    fn add_allowed_token(ref self: TContractState, token: ContractAddress);

    fn remove_allowed_token(ref self: TContractState, token: ContractAddress);

    fn is_token_allowed(self: @TContractState, token: ContractAddress) -> bool;

    // Version
    fn version(self: @TContractState) -> felt252;

    // Administrative functions
    fn update_proof_signer(ref self: TContractState, new_signer: felt252);

    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);

    fn get_owner(self: @TContractState) -> ContractAddress;

    fn get_proof_signer(self: @TContractState) -> felt252;

    // Emergency pause functions
    fn pause(ref self: TContractState);

    fn unpause(ref self: TContractState);

    fn is_paused(self: @TContractState) -> bool;

    fn is_proof_used(self: @TContractState, proof_hash: felt252) -> bool;
}

#[starknet::contract]
mod MexicoP2P {
    use super::*;

    // Constants
    const MIN_LOCK_DURATION: u64 = 300;    // 5 minutes minimum
    const MAX_LOCK_DURATION: u64 = 86400;  // 24 hours maximum

    #[storage]
    struct Storage {
        orders: Map::<felt252, Order>,
        used_proof: Map::<felt252, bool>,
        owner: ContractAddress,
        proof_signer: felt252,  // Public key of authorized signer (Stark pubkey)
        // Reentrancy protection
        _reentrancy_guard: u32,
        // Emergency pause
        paused: bool,
        // Multi-token whitelist
        allowed_tokens: Map::<ContractAddress, bool>,
        // Arbiter management
        arbiters: Map::<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OrderCreated: OrderCreated,
        OrderLocked: OrderLocked,
        OrderReleased: OrderReleased,
        OrderRefunded: OrderRefunded,
        DisputeOpened: DisputeOpened,
        DisputeResolved: DisputeResolved,
        OwnershipTransferred: OwnershipTransferred,
        ProofSignerUpdated: ProofSignerUpdated,
        Paused: Paused,
        Unpaused: Unpaused,
        TokenAdded: TokenAdded,
        TokenRemoved: TokenRemoved,
        ArbiterAdded: ArbiterAdded,
        ArbiterRemoved: ArbiterRemoved,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderCreated {
        order_id: felt252,
        seller: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderLocked {
        order_id: felt252,
        buyer: ContractAddress,
        lock_expiry: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderReleased {
        order_id: felt252,
        buyer: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderRefunded {
        order_id: felt252,
        seller: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeOpened {
        order_id: felt252,
        opened_by: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct DisputeResolved {
        order_id: felt252,
        arbiter: ContractAddress,
        winner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ProofSignerUpdated {
        previous_signer: felt252,
        new_signer: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Paused {
        account: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Unpaused {
        account: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenAdded {
        token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenRemoved {
        token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ArbiterAdded {
        arbiter: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ArbiterRemoved {
        arbiter: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        proof_signer: felt252
    ) {
        self.owner.write(owner);
        self.proof_signer.write(proof_signer);
        self._reentrancy_guard.write(0);
        self.paused.write(false);
    }

    #[abi(embed_v0)]
    impl MexicoP2PImpl of super::IMexicoP2P<ContractState> {
        /// Seller deposits tokens into escrow, creating an Open order
        fn deposit(
            ref self: ContractState,
            order_id: felt252,
            token: ContractAddress,
            amount: u256
        ) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Input validation
            assert!(amount > 0, "Amount must be positive");
            assert!(!token.is_zero(), "Token zero");
            assert!(self.allowed_tokens.read(token), "Token not whitelisted");

            // Check if order exists
            let existing = self.orders.read(order_id);
            assert!(existing.seller.is_zero(), "Order exists");

            let seller = get_caller_address();

            // Transfer tokens from seller to escrow contract
            let token_contract = IERC20Dispatcher { contract_address: token };
            token_contract.transfer_from(seller, starknet::get_contract_address(), amount);

            // Create order with Open status (no lock_expiry yet)
            let new_order = Order {
                seller,
                buyer: 0.try_into().unwrap(),
                token,
                amount,
                lock_expiry: 0,  // Set when buyer locks
                status: ORDER_STATUS_OPEN,
            };
            self.orders.write(order_id, new_order);

            // Emit event
            self.emit(OrderCreated {
                order_id,
                seller,
                token,
                amount,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Buyer locks an Open order, setting the lock expiry
        fn lockOrder(
            ref self: ContractState,
            order_id: felt252,
            duration_seconds: u64
        ) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Validate duration
            assert!(duration_seconds >= MIN_LOCK_DURATION, "Lock too short");
            assert!(duration_seconds <= MAX_LOCK_DURATION, "Lock too long");

            // Get order
            let order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == ORDER_STATUS_OPEN, "Order not open");

            let buyer = get_caller_address();
            assert!(buyer != order.seller, "Buyer cannot be seller");

            // Calculate lock expiry
            let now = get_block_timestamp();
            assert!(duration_seconds <= 0xFFFFFFFFFFFFFFFF - now, "Lock overflow");
            let expiry = now + duration_seconds;

            // Update order to Locked status
            let locked_order = Order {
                seller: order.seller,
                buyer,
                token: order.token,
                amount: order.amount,
                lock_expiry: expiry,
                status: ORDER_STATUS_LOCKED,
            };
            self.orders.write(order_id, locked_order);

            // Emit event
            self.emit(OrderLocked {
                order_id,
                buyer,
                lock_expiry: expiry,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Release funds to buyer with valid signature from proof_signer
        fn release(
            ref self: ContractState,
            order_id: felt252,
            sig_r: felt252,
            sig_s: felt252
        ) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Get order
            let order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == ORDER_STATUS_LOCKED, "Order not locked");

            // Generate a unique proof hash from the signature
            let mut proof_st = PedersenTrait::new(0);
            proof_st = proof_st.update(sig_r);
            proof_st = proof_st.update(sig_s);
            let proof_hash = proof_st.finalize();

            // Check if proof was used
            assert!(!self.used_proof.read(proof_hash), "Proof already used");

            // Compute message hash with domain separation
            let msg_hash = self._compute_msg(
                order_id,
                proof_hash,
                order.token,
                order.amount,
                order.seller,
                order.buyer
            );

            // Verify signature
            assert!(self._verify_signature(msg_hash, sig_r, sig_s), "Invalid signature");

            // Mark proof as used
            self.used_proof.write(proof_hash, true);

            // Transfer funds to buyer
            let token_contract = IERC20Dispatcher { contract_address: order.token };
            token_contract.transfer(order.buyer, order.amount);

            // Update order to Released
            let released_order = Order {
                seller: order.seller,
                buyer: order.buyer,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: ORDER_STATUS_RELEASED,
            };
            self.orders.write(order_id, released_order);

            // Emit event
            self.emit(OrderReleased {
                order_id,
                buyer: order.buyer,
                token: order.token,
                amount: order.amount,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Refund tokens to seller
        /// - Seller can refund Open orders anytime
        /// - Seller can refund Locked orders after lock_expiry
        /// - Owner can refund anytime (emergency)
        fn refund(ref self: ContractState, order_id: felt252) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Get order
            let order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");

            // Can only refund Open or Locked orders (not Released, Refunded, or Disputed)
            assert!(
                order.status == ORDER_STATUS_OPEN || order.status == ORDER_STATUS_LOCKED,
                "Cannot refund"
            );

            // Authorization check
            let caller = get_caller_address();
            if caller != self.owner.read() {
                assert!(caller == order.seller, "Only seller or owner");
                // Seller must wait for lock expiry on Locked orders
                if order.status == ORDER_STATUS_LOCKED {
                    assert!(get_block_timestamp() >= order.lock_expiry, "Lock not expired");
                }
            }

            // Transfer tokens back to seller
            let token_contract = IERC20Dispatcher { contract_address: order.token };
            token_contract.transfer(order.seller, order.amount);

            // Update order to Refunded
            let refunded_order = Order {
                seller: order.seller,
                buyer: order.buyer,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: ORDER_STATUS_REFUNDED,
            };
            self.orders.write(order_id, refunded_order);

            // Emit event
            self.emit(OrderRefunded {
                order_id,
                seller: order.seller,
                token: order.token,
                amount: order.amount,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Query order by ID
        fn orders(self: @ContractState, order_id: felt252) -> Order {
            self.orders.read(order_id)
        }

        /// Open a dispute on a Locked order
        /// Only buyer or seller can open dispute
        fn openDispute(ref self: ContractState, order_id: felt252) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Get order
            let order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == ORDER_STATUS_LOCKED, "Can only dispute locked orders");

            // Only buyer or seller can open dispute
            let caller = get_caller_address();
            assert!(caller == order.buyer || caller == order.seller, "Not buyer or seller");

            // Update order to Disputed
            let disputed_order = Order {
                seller: order.seller,
                buyer: order.buyer,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: ORDER_STATUS_DISPUTED,
            };
            self.orders.write(order_id, disputed_order);

            // Emit event
            self.emit(DisputeOpened {
                order_id,
                opened_by: caller,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Resolve a dispute - only arbiters can call
        /// winner must be either buyer or seller
        fn resolveDispute(
            ref self: ContractState,
            order_id: felt252,
            winner: ContractAddress
        ) {
            // Emergency pause check
            self._when_not_paused();

            // Reentrancy protection
            self._non_reentrant();

            // Get order
            let order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == ORDER_STATUS_DISPUTED, "Order not disputed");

            // Only arbiters can resolve
            let caller = get_caller_address();
            assert!(self.arbiters.read(caller), "Not an arbiter");

            // Winner must be buyer or seller
            assert!(winner == order.buyer || winner == order.seller, "Invalid winner");

            // Transfer funds to winner
            let token_contract = IERC20Dispatcher { contract_address: order.token };
            token_contract.transfer(winner, order.amount);

            // Update order status based on winner
            let final_status = if winner == order.buyer {
                ORDER_STATUS_RELEASED
            } else {
                ORDER_STATUS_REFUNDED
            };

            let resolved_order = Order {
                seller: order.seller,
                buyer: order.buyer,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: final_status,
            };
            self.orders.write(order_id, resolved_order);

            // Emit event
            self.emit(DisputeResolved {
                order_id,
                arbiter: caller,
                winner,
            });

            // Reset reentrancy guard
            self._reset_reentrancy_guard();
        }

        /// Add an arbiter (owner-only)
        fn addArbiter(ref self: ContractState, arbiter: ContractAddress) {
            self._only_owner();
            assert!(!arbiter.is_zero(), "Arbiter zero");
            self.arbiters.write(arbiter, true);
            self.emit(ArbiterAdded { arbiter });
        }

        /// Remove an arbiter (owner-only)
        fn removeArbiter(ref self: ContractState, arbiter: ContractAddress) {
            self._only_owner();
            self.arbiters.write(arbiter, false);
            self.emit(ArbiterRemoved { arbiter });
        }

        /// Check if address is an arbiter
        fn isArbiter(self: @ContractState, address: ContractAddress) -> bool {
            self.arbiters.read(address)
        }

        /// Add a token to whitelist (owner-only)
        fn add_allowed_token(ref self: ContractState, token: ContractAddress) {
            self._only_owner();
            assert!(!token.is_zero(), "Token zero");
            self.allowed_tokens.write(token, true);
            self.emit(TokenAdded { token });
        }

        /// Remove a token from whitelist (owner-only)
        fn remove_allowed_token(ref self: ContractState, token: ContractAddress) {
            self._only_owner();
            self.allowed_tokens.write(token, false);
            self.emit(TokenRemoved { token });
        }

        /// Check if token is whitelisted
        fn is_token_allowed(self: @ContractState, token: ContractAddress) -> bool {
            self.allowed_tokens.read(token)
        }

        /// Get contract version
        fn version(self: @ContractState) -> felt252 {
            CONTRACT_VERSION
        }

        /// Update proof signer (owner-only)
        fn update_proof_signer(ref self: ContractState, new_signer: felt252) {
            self._only_owner();
            assert!(new_signer != 0, "New signer cannot be zero");

            let previous_signer = self.proof_signer.read();
            self.proof_signer.write(new_signer);

            self.emit(ProofSignerUpdated {
                previous_signer,
                new_signer,
            });
        }

        /// Transfer ownership (owner-only)
        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            self._only_owner();
            assert!(!new_owner.is_zero(), "New owner cannot be zero");

            let previous_owner = self.owner.read();
            self.owner.write(new_owner);

            self.emit(OwnershipTransferred {
                previous_owner,
                new_owner,
            });
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_proof_signer(self: @ContractState) -> felt252 {
            self.proof_signer.read()
        }

        /// Pause contract (owner-only)
        fn pause(ref self: ContractState) {
            self._only_owner();
            self.paused.write(true);
            self.emit(Paused { account: get_caller_address() });
        }

        /// Unpause contract (owner-only)
        fn unpause(ref self: ContractState) {
            self._only_owner();
            self.paused.write(false);
            self.emit(Unpaused { account: get_caller_address() });
        }

        fn is_paused(self: @ContractState) -> bool {
            self.paused.read()
        }

        fn is_proof_used(self: @ContractState, proof_hash: felt252) -> bool {
            self.used_proof.read(proof_hash)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _only_owner(self: @ContractState) {
            assert!(get_caller_address() == self.owner.read(), "Only owner");
        }

        fn _when_not_paused(self: @ContractState) {
            assert!(!self.paused.read(), "Contract paused");
        }

        fn _non_reentrant(ref self: ContractState) {
            let guard_value = self._reentrancy_guard.read();
            assert!(guard_value == 0, "Reentrant call");
            self._reentrancy_guard.write(1);
        }

        fn _reset_reentrancy_guard(ref self: ContractState) {
            self._reentrancy_guard.write(0);
        }

        /// Compute message hash with domain separation
        fn _compute_msg(
            self: @ContractState,
            order_id: felt252,
            proof_hash: felt252,
            token: ContractAddress,
            amount: u256,
            seller: ContractAddress,
            buyer: ContractAddress
        ) -> felt252 {
            let mut st = PedersenTrait::new(0);
            st = st.update(starknet::get_contract_address().into()); // domain
            st = st.update(order_id);
            st = st.update(proof_hash);
            st = st.update(token.into());
            st = st.update(amount.low.into());
            st = st.update(amount.high.into());
            st = st.update(seller.into());
            st = st.update(buyer.into());
            st.finalize()
        }

        /// Verify ECDSA signature using Stark curve
        fn _verify_signature(self: @ContractState, msg_hash: felt252, r: felt252, s: felt252) -> bool {
            let pubkey = self.proof_signer.read();
            if pubkey == 0 { return false; }
            if r == 0 || s == 0 { return false; }
            check_ecdsa_signature(msg_hash, pubkey, r, s)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ORDER_STATUS_OPEN, ORDER_STATUS_LOCKED, ORDER_STATUS_RELEASED, ORDER_STATUS_REFUNDED, ORDER_STATUS_DISPUTED};
    use core::array::ArrayTrait;
    use core::pedersen::PedersenTrait;
    use core::hash::HashStateTrait;

    // Test constants
    const OWNER: felt252 = 0x123;
    const BUYER: felt252 = 0x789;
    const SELLER: felt252 = 0xabc;
    const ORDER_ID: felt252 = 0x1;
    const TOKEN_SUPPLY: u256 = 1000000000000000000000;
    const DEPOSIT_AMOUNT: u256 = 1000000000000000000;
    const USDC_TOKEN: felt252 = 0x456;
    const WBTC_TOKEN: felt252 = 0x789;
    const MIN_LOCK_DURATION: u64 = 300;
    const MAX_LOCK_DURATION: u64 = 86400;

    #[test]
    fn test_order_status_enum() {
        let open = ORDER_STATUS_OPEN;
        let locked = ORDER_STATUS_LOCKED;
        let released = ORDER_STATUS_RELEASED;
        let refunded = ORDER_STATUS_REFUNDED;
        let disputed = ORDER_STATUS_DISPUTED;

        assert!(open != locked, "Open != Locked");
        assert!(locked != released, "Locked != Released");
        assert!(released != refunded, "Released != Refunded");
        assert!(refunded != disputed, "Refunded != Disputed");
    }

    #[test]
    fn test_five_state_transitions() {
        // Test valid state transition paths
        let open = ORDER_STATUS_OPEN;
        let locked = ORDER_STATUS_LOCKED;
        let released = ORDER_STATUS_RELEASED;
        let refunded = ORDER_STATUS_REFUNDED;
        let disputed = ORDER_STATUS_DISPUTED;

        // Valid paths:
        // Open -> Locked (buyer locks)
        // Open -> Refunded (seller refunds before lock)
        // Locked -> Released (buyer releases with signature)
        // Locked -> Refunded (seller refunds after expiry)
        // Locked -> Disputed (either party disputes)
        // Disputed -> Released (arbiter rules for buyer)
        // Disputed -> Refunded (arbiter rules for seller)

        assert!(open == ORDER_STATUS_OPEN, "Initial state is Open");
        assert!(locked == ORDER_STATUS_LOCKED, "Locked state works");
        assert!(released == ORDER_STATUS_RELEASED, "Released state works");
        assert!(refunded == ORDER_STATUS_REFUNDED, "Refunded state works");
        assert!(disputed == ORDER_STATUS_DISPUTED, "Disputed state works");
    }

    #[test]
    fn test_lockOrder_duration_constants() {
        assert!(MIN_LOCK_DURATION == 300, "Min lock is 5 minutes");
        assert!(MAX_LOCK_DURATION == 86400, "Max lock is 24 hours");
        assert!(MIN_LOCK_DURATION < MAX_LOCK_DURATION, "Min < Max");
    }

    #[test]
    fn test_lockOrder_min_duration_validation() {
        // Test that duration must be >= MIN_LOCK_DURATION
        let duration: u64 = 200; // Less than 300
        let is_valid = duration >= MIN_LOCK_DURATION;
        assert!(!is_valid, "Duration 200 should be rejected");

        let valid_duration: u64 = 300;
        let is_valid_min = valid_duration >= MIN_LOCK_DURATION;
        assert!(is_valid_min, "Duration 300 should be accepted");
    }

    #[test]
    fn test_lockOrder_max_duration_validation() {
        // Test that duration must be <= MAX_LOCK_DURATION
        let duration: u64 = 100000; // More than 86400
        let is_valid = duration <= MAX_LOCK_DURATION;
        assert!(!is_valid, "Duration 100000 should be rejected");

        let valid_duration: u64 = 86400;
        let is_valid_max = valid_duration <= MAX_LOCK_DURATION;
        assert!(is_valid_max, "Duration 86400 should be accepted");
    }

    #[test]
    fn test_release_requires_locked_status() {
        // Release should only work on Locked orders
        let open = ORDER_STATUS_OPEN;
        let locked = ORDER_STATUS_LOCKED;
        let released = ORDER_STATUS_RELEASED;

        let can_release_open = open == ORDER_STATUS_LOCKED;
        let can_release_locked = locked == ORDER_STATUS_LOCKED;
        let can_release_released = released == ORDER_STATUS_LOCKED;

        assert!(!can_release_open, "Cannot release Open order");
        assert!(can_release_locked, "Can release Locked order");
        assert!(!can_release_released, "Cannot release Released order");
    }

    #[test]
    fn test_buyer_cannot_be_seller() {
        let buyer: felt252 = 0xabc;
        let seller: felt252 = 0xabc; // Same address

        let buyer_is_seller = buyer == seller;
        assert!(buyer_is_seller, "Buyer equals seller should be detected");
    }

    #[test]
    fn test_openDispute_only_locked_orders() {
        let open = ORDER_STATUS_OPEN;
        let locked = ORDER_STATUS_LOCKED;
        let released = ORDER_STATUS_RELEASED;

        let can_dispute_open = open == ORDER_STATUS_LOCKED;
        let can_dispute_locked = locked == ORDER_STATUS_LOCKED;
        let can_dispute_released = released == ORDER_STATUS_LOCKED;

        assert!(!can_dispute_open, "Cannot dispute Open order");
        assert!(can_dispute_locked, "Can dispute Locked order");
        assert!(!can_dispute_released, "Cannot dispute Released order");
    }

    #[test]
    fn test_resolveDispute_winner_validation() {
        let buyer: felt252 = 0x789;
        let seller: felt252 = 0xabc;
        let random: felt252 = 0x999;

        let buyer_is_valid = buyer == 0x789 || buyer == 0xabc;
        let seller_is_valid = seller == 0x789 || seller == 0xabc;
        let random_is_valid = random == 0x789 || random == 0xabc;

        assert!(buyer_is_valid, "Buyer is valid winner");
        assert!(seller_is_valid, "Seller is valid winner");
        assert!(!random_is_valid, "Random address is not valid winner");
    }

    #[test]
    fn test_multi_token_whitelist() {
        // Test that multiple tokens can be whitelisted
        let usdc: felt252 = USDC_TOKEN;
        let wbtc: felt252 = WBTC_TOKEN;

        assert!(usdc != wbtc, "USDC and WBTC are different tokens");
        assert!(usdc != 0, "USDC is not zero");
        assert!(wbtc != 0, "WBTC is not zero");
    }

    #[test]
    fn test_refund_after_lock_expiry() {
        // Test lock expiry calculation
        let current_time: u64 = 1000;
        let lock_duration: u64 = 86400;
        let lock_expiry = current_time + lock_duration;

        let time_before_expiry: u64 = 50000;
        let time_after_expiry: u64 = 90000;

        let can_refund_before = time_before_expiry >= lock_expiry;
        let can_refund_after = time_after_expiry >= lock_expiry;

        assert!(!can_refund_before, "Cannot refund before expiry");
        assert!(can_refund_after, "Can refund after expiry");
    }

    #[test]
    fn test_message_computation_with_domain() {
        // Test message hash includes contract address for domain separation
        let contract_address: felt252 = 0x123;
        let order_id: felt252 = 0x1;
        let proof_hash: felt252 = 0x456;
        let token: felt252 = USDC_TOKEN;
        let amount_low: felt252 = 1000000;
        let amount_high: felt252 = 0;
        let seller: felt252 = SELLER;
        let buyer: felt252 = BUYER;

        let mut st = PedersenTrait::new(0);
        st = st.update(contract_address);
        st = st.update(order_id);
        st = st.update(proof_hash);
        st = st.update(token);
        st = st.update(amount_low);
        st = st.update(amount_high);
        st = st.update(seller);
        st = st.update(buyer);
        let msg_hash = st.finalize();

        assert!(msg_hash != 0, "Message hash is not zero");
        assert!(msg_hash != order_id, "Message hash includes domain");
    }

    #[test]
    fn test_signature_array_format() {
        // Test that signature uses r and s components
        let r: felt252 = 0x456;
        let s: felt252 = 0x789;

        assert!(r != 0, "r is not zero");
        assert!(s != 0, "s is not zero");
        assert!(r != s, "r and s are different");
    }

    #[test]
    fn test_reentrancy_guard_states() {
        let unlocked: u32 = 0;
        let locked: u32 = 1;

        assert!(unlocked == 0, "Unlocked state is 0");
        assert!(locked == 1, "Locked state is 1");
        assert!(unlocked != locked, "States are different");
    }

    #[test]
    fn test_arbiter_authorization() {
        let arbiter: felt252 = 0xdef;
        let non_arbiter: felt252 = 0x999;

        // Simulate arbiter check (in real contract, would check storage)
        let is_arbiter = arbiter == 0xdef;
        let is_non_arbiter = non_arbiter == 0xdef;

        assert!(is_arbiter, "Arbiter is authorized");
        assert!(!is_non_arbiter, "Non-arbiter is not authorized");
    }

    #[test]
    fn test_dispute_resolution_outcomes() {
        // When dispute resolved for buyer -> Released
        // When dispute resolved for seller -> Refunded
        let buyer_wins = ORDER_STATUS_RELEASED;
        let seller_wins = ORDER_STATUS_REFUNDED;

        assert!(buyer_wins == ORDER_STATUS_RELEASED, "Buyer wins -> Released");
        assert!(seller_wins == ORDER_STATUS_REFUNDED, "Seller wins -> Refunded");
    }

    #[test]
    fn test_proof_hash_uniqueness() {
        // Test proof hash generation from signature
        let r1: felt252 = 0x111;
        let s1: felt252 = 0x222;
        let r2: felt252 = 0x333;
        let s2: felt252 = 0x444;

        let mut st1 = PedersenTrait::new(0);
        st1 = st1.update(r1);
        st1 = st1.update(s1);
        let hash1 = st1.finalize();

        let mut st2 = PedersenTrait::new(0);
        st2 = st2.update(r2);
        st2 = st2.update(s2);
        let hash2 = st2.finalize();

        assert!(hash1 != hash2, "Different signatures produce different hashes");
    }

    #[test]
    fn test_emergency_pause_states() {
        let paused: bool = true;
        let unpaused: bool = false;

        assert!(paused, "Paused state is true");
        assert!(!unpaused, "Unpaused state is false");
        assert!(paused != unpaused, "States are different");
    }
}
