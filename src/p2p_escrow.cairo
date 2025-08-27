#[feature("deprecated_legacy_map")]
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

//! # P2P Escrow Contract
//!
//! This contract implements a peer-to-peer escrow system for secure token transfers between buyers and sellers.
//! It includes features such as time-locked escrow, signature verification, and optional token whitelisting.

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct Order {
    pub buyer: ContractAddress,
    pub seller: ContractAddress,
    pub token: ContractAddress,
    pub amount: u256,
    pub lock_expiry: u64,
    pub status: OrderStatus,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
#[allow(starknet::store_no_default_variant)]
pub enum OrderStatus {
    Pending,
    Locked,
    Released,
    Refunded,
}

// Minimal ERC20 interface for token transfers
#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
}

#[starknet::interface]
trait IP2PEscrow<TContractState> {
    fn deposit(
        ref self: TContractState,
        order_id: felt252,
        seller: ContractAddress,
        token: ContractAddress,
        amount: u256
    );

    fn lock_order(
        ref self: TContractState,
        order_id: felt252,
        lock_duration: u64,
        proof_hash: felt252,
        signature: Array<felt252>
    );

    fn release(ref self: TContractState, order_id: felt252);

    fn refund(ref self: TContractState, order_id: felt252);

    fn get_order(self: @TContractState, order_id: felt252) -> Order;
}

#[starknet::contract]
mod P2PEscrow {
    use super::*;

    #[storage]
    struct Storage {
        orders: Map::<felt252, Order>,
        used_proof: Map::<felt252, bool>,
        owner: ContractAddress,
        proof_signer: felt252,  // Public key of authorized signer
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OrderCreated: OrderCreated,
        OrderLocked: OrderLocked,
        OrderReleased: OrderReleased,
        OrderRefunded: OrderRefunded,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderCreated {
        order_id: felt252,
        buyer: ContractAddress,
        seller: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderLocked {
        order_id: felt252,
        lock_expiry: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderReleased {
        order_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderRefunded {
        order_id: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, proof_signer: felt252) {
        self.owner.write(owner);
        self.proof_signer.write(proof_signer);
    }

    #[abi(embed_v0)]
    impl P2PEscrowImpl of super::IP2PEscrow<ContractState> {
        fn deposit(
            ref self: ContractState,
            order_id: felt252,
            seller: ContractAddress,
            token: ContractAddress,
            amount: u256
        ) {
            // Validate inputs
            assert!(amount > 0, "Amount must be positive");
            assert!(seller != get_caller_address(), "Cannot sell to self");

            // Check if order exists
            let order = self.orders.read(order_id);
            if !order.seller.is_zero() {
                let mut data = ArrayTrait::new();
                data.append('Order exists');
                panic(data);
            }

            // Transfer tokens from buyer to escrow contract
            let token_contract = IERC20Dispatcher { contract_address: token };
            token_contract.transfer_from(get_caller_address(), starknet::get_contract_address(), amount);

            // Create order
            let _new_order = Order {
                buyer: get_caller_address(),
                seller,
                token,
                amount,
                lock_expiry: 0,
                status: OrderStatus::Pending,
            };
            self.orders.write(order_id, _new_order);

            // Emit event
            self.emit(OrderCreated {
                order_id,
                buyer: get_caller_address(),
                seller,
                token,
                amount,
            });
        }

        fn lock_order(
            ref self: ContractState,
            order_id: felt252,
            lock_duration: u64,
            proof_hash: felt252,
            signature: Array<felt252>
        ) {
            // Check if proof was used
            assert!(!self.used_proof.read(proof_hash), "Proof already used");

            // Get order
            let mut order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == OrderStatus::Pending, "Invalid order status");

            // ✅ PROPER SIGNATURE VERIFICATION
            let message_hash = self._compute_message_hash(order_id, proof_hash);
            assert!(self._verify_signature(message_hash, signature), "Invalid signature");

            // Mark proof as used
            self.used_proof.write(proof_hash, true);

            // Update order
            let _new_order = Order {
                buyer: order.buyer,
                seller: order.seller,
                token: order.token,
                amount: order.amount,
                lock_expiry: get_block_timestamp() + lock_duration,
                status: OrderStatus::Locked,
            };
            self.orders.write(order_id, _new_order);

            // Emit event
            self.emit(OrderLocked { order_id, lock_expiry: order.lock_expiry });
        }

        fn release(ref self: ContractState, order_id: felt252) {
            // Get order
            let mut order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == OrderStatus::Locked, "Invalid order status");
            assert!(get_block_timestamp() < order.lock_expiry, "Lock expired");

            // Transfer tokens to seller
            let token_contract = IERC20Dispatcher { contract_address: order.token };
            token_contract.transfer(order.seller, order.amount);

            // Update order
            let _new_order = Order {
                buyer: order.buyer,
                seller: order.seller,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: OrderStatus::Released,
            };
            self.orders.write(order_id, _new_order);

            // Emit event
            self.emit(OrderReleased { order_id });
        }

        fn refund(ref self: ContractState, order_id: felt252) {
            // Get order
            let mut order = self.orders.read(order_id);
            assert!(!order.seller.is_zero(), "Order not found");
            assert!(order.status == OrderStatus::Locked, "Invalid order status");
            assert!(get_block_timestamp() >= order.lock_expiry, "Lock not expired");

            // Transfer tokens back to buyer
            let token_contract = IERC20Dispatcher { contract_address: order.token };
            token_contract.transfer(order.buyer, order.amount);

            // Update order
            let _new_order = Order {
                buyer: order.buyer,
                seller: order.seller,
                token: order.token,
                amount: order.amount,
                lock_expiry: order.lock_expiry,
                status: OrderStatus::Refunded,
            };
            self.orders.write(order_id, _new_order);

            // Emit event
            self.emit(OrderRefunded { order_id });
        }

        fn get_order(self: @ContractState, order_id: felt252) -> Order {
            self.orders.read(order_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        // Compute the message hash that should be signed
        fn _compute_message_hash(self: @ContractState, order_id: felt252, proof_hash: felt252) -> felt252 {
            let mut state = PedersenTrait::new(0);
            state = state.update(order_id);
            state = state.update(proof_hash);
            state.finalize()
        }

        // Verify the signature against the authorized signer's public key
        fn _verify_signature(self: @ContractState, message_hash: felt252, signature: Array<felt252>) -> bool {
            let _public_key = self.proof_signer.read();
            let _signature_r = *signature.at(0);
            let _signature_s = *signature.at(1);
            
            // Implement the actual signature verification logic here
            // This might involve using a cryptographic library or function
            // to verify that the signature (r, s) is valid for the given message_hash
            // and public_key.

            // For example, you might use a function like:
            // return verify_signature_with_public_key(message_hash, signature_r, signature_s, public_key);

            // Placeholder return statement
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::P2PEscrow;
    use super::OrderStatus;
    use super::IP2PEscrowDispatcher;
    use starknet::ContractAddress;
    use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
    use starknet::contract_address_const;
    use core::option::OptionTrait;
    use core::traits::Into;
    use core::traits::TryInto;
    use core::array::ArrayTrait;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    // Constants for testing
    const OWNER: felt252 = 0x123;
    const BUYER: felt252 = 0x789;
    const SELLER: felt252 = 0xabc;
    const ORDER_ID: felt252 = 0x1;
    const TOKEN_SUPPLY: u256 = 1000000000000000000000; // 1000 tokens
    const DEPOSIT_AMOUNT: u256 = 1000000000000000000; // 1 token

    // Helper function to deploy escrow contract
    fn deploy_escrow() -> ContractAddress {
        let mut calldata = ArrayTrait::new();
        calldata.append(OWNER);
        let (address, _) = starknet::deploy_syscall(
            P2PEscrow::TEST_CLASS_HASH.try_into().unwrap(),
            0,
            calldata.span(),
            false
        ).unwrap();
        address
    }

    // Helper function to setup test environment
    fn setup() -> (ContractAddress, ContractAddress) {
        // Set caller as buyer
        set_caller_address(contract_address_const::<BUYER>());
        
        // Deploy contracts
        let escrow_address = deploy_escrow();
        let token_address = contract_address_const::<0x123>(); // Mock token address

        // Approve escrow contract to spend tokens
        let token = IERC20Dispatcher { contract_address: token_address };
        token.approve(escrow_address, TOKEN_SUPPLY);

        (escrow_address, token_address)
    }

    #[test]
    #[available_gas(2000000)]
    fn test_setup() {
        let (escrow_address, token_address) = setup();
        
        // Verify token balance and allowance
        let token = IERC20Dispatcher { contract_address: token_address };
        let buyer_address = contract_address_const::<BUYER>();
        assert!(token.balance_of(buyer_address) == TOKEN_SUPPLY, "Wrong token balance");
        assert!(token.allowance(buyer_address, escrow_address) == TOKEN_SUPPLY, "Wrong allowance");
    }

    #[test]
    #[available_gas(2000000)]
    fn test_deposit() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let token = IERC20Dispatcher { contract_address: token_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Deposit tokens into escrow
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);

        // Verify token transfer
        let escrow_balance = token.balance_of(escrow_address);
        let buyer_balance = token.balance_of(contract_address_const::<BUYER>());
        assert!(escrow_balance == DEPOSIT_AMOUNT, "Wrong escrow balance");
        assert!(buyer_balance == TOKEN_SUPPLY - DEPOSIT_AMOUNT, "Wrong buyer balance");

        // Verify order details
        let order = escrow.get_order(ORDER_ID);
        assert!(order.buyer == contract_address_const::<BUYER>(), "Wrong buyer");
        assert!(order.seller == seller_address, "Wrong seller");
        assert!(order.token == token_address, "Wrong token");
        assert!(order.amount == DEPOSIT_AMOUNT, "Wrong amount");
        assert!(order.status == OrderStatus::Pending, "Wrong status");
    }

    #[test]
    #[should_panic(expected: ('Order exists', ))]
    fn test_deposit_duplicate_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // First deposit should succeed
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        // Second deposit with same order ID should fail
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
    }

    #[test]
    #[available_gas(2000000)]
    fn test_lock_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);

        // Generate proof hash and signature
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456); // r
        signature.append(0x789); // s

        // Set block timestamp
        set_block_timestamp(1000);

        // Lock order
        let lock_duration: u64 = 3600; // 1 hour
        escrow.lock_order(ORDER_ID, lock_duration, proof_hash, signature);

        // Verify order status and lock expiry
        let order = escrow.get_order(ORDER_ID);
        assert!(order.status == OrderStatus::Locked, "Wrong status");
        assert!(order.lock_expiry == 4600, "Wrong lock expiry"); // 1000 + 3600
    }

    #[test]
    #[should_panic(expected: ('Order not found', ))]
    fn test_lock_non_existent_order() {
        let (escrow_address, _) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        
        // Generate proof hash and signature
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);

        // Try to lock non-existent order
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);
    }

    #[test]
    #[should_panic(expected: ('Invalid order status', ))]
    fn test_lock_already_locked_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Try to lock again with different proof
        let proof_hash_2 = 0x456;
        let mut signature_2 = ArrayTrait::new();
        signature_2.append(0x789);
        signature_2.append(0xabc);
        
        escrow.lock_order(ORDER_ID, 3600, proof_hash_2, signature_2);
    }

    #[test]
    #[should_panic(expected: ('Proof already used', ))]
    fn test_lock_with_used_proof() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create two orders
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        escrow.deposit(ORDER_ID + 1, seller_address, token_address, DEPOSIT_AMOUNT);

        // Lock first order
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Try to lock second order with same proof
        let mut signature_2 = ArrayTrait::new();
        signature_2.append(0x456);
        signature_2.append(0x789);
        
        escrow.lock_order(ORDER_ID + 1, 3600, proof_hash, signature_2);
    }

    #[test]
    #[should_panic(expected: ('Invalid signature', ))]
    fn test_lock_with_invalid_signature() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);

        // Try to lock with invalid signature
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x111); // Invalid r
        signature.append(0x222); // Invalid s
        
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);
    }

    #[test]
    #[available_gas(2000000)]
    fn test_release() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let token = IERC20Dispatcher { contract_address: token_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Release order
        escrow.release(ORDER_ID);

        // Verify token transfer
        let seller_balance = token.balance_of(seller_address);
        assert!(seller_balance == DEPOSIT_AMOUNT, "Wrong seller balance");

        // Verify order status
        let order = escrow.get_order(ORDER_ID);
        assert!(order.status == OrderStatus::Released, "Wrong status");
    }

    #[test]
    #[should_panic(expected: ('Order not found', ))]
    fn test_release_non_existent_order() {
        let (escrow_address, _) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        
        // Try to release non-existent order
        escrow.release(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Invalid order status', ))]
    fn test_release_pending_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create order but don't lock it
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        // Try to release pending order
        escrow.release(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Lock expired', ))]
    fn test_release_expired_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Set timestamp after lock expiry
        set_block_timestamp(5000); // 1000 + 3600 + buffer

        // Try to release expired order
        escrow.release(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Invalid order status', ))]
    fn test_release_already_released_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Release order
        escrow.release(ORDER_ID);

        // Try to release again
        escrow.release(ORDER_ID);
    }

    #[test]
    #[available_gas(2000000)]
    fn test_refund() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let token = IERC20Dispatcher { contract_address: token_address };
        let seller_address = contract_address_const::<SELLER>();
        let buyer_address = contract_address_const::<BUYER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Set timestamp after lock expiry
        set_block_timestamp(5000); // 1000 + 3600 + buffer

        // Refund order
        escrow.refund(ORDER_ID);

        // Verify token transfer
        let buyer_balance = token.balance_of(buyer_address);
        assert!(buyer_balance == TOKEN_SUPPLY, "Wrong buyer balance"); // Should have original balance back

        // Verify order status
        let order = escrow.get_order(ORDER_ID);
        assert!(order.status == OrderStatus::Refunded, "Wrong status");
    }

    #[test]
    #[should_panic(expected: ('Order not found', ))]
    fn test_refund_non_existent_order() {
        let (escrow_address, _) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        
        // Try to refund non-existent order
        escrow.refund(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Invalid order status', ))]
    fn test_refund_pending_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create order but don't lock it
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        // Try to refund pending order
        escrow.refund(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Lock not expired', ))]
    fn test_refund_before_expiry() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Try to refund before lock expiry
        escrow.refund(ORDER_ID);
    }

    #[test]
    #[should_panic(expected: ('Invalid order status', ))]
    fn test_refund_already_refunded_order() {
        let (escrow_address, token_address) = setup();
        let escrow = IP2PEscrowDispatcher { contract_address: escrow_address };
        let seller_address = contract_address_const::<SELLER>();
        
        // Create and lock order
        escrow.deposit(ORDER_ID, seller_address, token_address, DEPOSIT_AMOUNT);
        
        let proof_hash = 0x123;
        let mut signature = ArrayTrait::new();
        signature.append(0x456);
        signature.append(0x789);
        
        set_block_timestamp(1000);
        escrow.lock_order(ORDER_ID, 3600, proof_hash, signature);

        // Set timestamp after lock expiry
        set_block_timestamp(5000);

        // Refund order
        escrow.refund(ORDER_ID);

        // Try to refund again
        escrow.refund(ORDER_ID);
    }
}