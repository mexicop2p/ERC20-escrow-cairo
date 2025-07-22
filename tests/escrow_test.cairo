use p2p_escrow::{IP2PEscrowDispatcher, IP2PEscrowDispatcherTrait, Order};
use starknet::{ContractAddress, contract_address_const};
use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp
};

// Mock ERC20 for testing
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

const OWNER: felt252 = 'owner';
const SELLER: felt252 = 'seller';
const BUYER: felt252 = 'buyer';
const PROOF_SIGNER: felt252 = 0x123456789abcdef;
const MAX_LOCK_DURATION: u256 = 86400; // 24 hours
const KYC_LIMIT: u256 = 1000000; // 1M units

fn deploy_escrow() -> (ContractAddress, IP2PEscrowDispatcher) {
    let contract = declare("P2PEscrow").unwrap().contract_class();
    
    let mut constructor_calldata = array![];
    constructor_calldata.append(OWNER); // owner
    constructor_calldata.append(PROOF_SIGNER); // proof signer
    constructor_calldata.append(MAX_LOCK_DURATION.low.into()); // max lock seconds low
    constructor_calldata.append(MAX_LOCK_DURATION.high.into()); // max lock seconds high
    constructor_calldata.append(KYC_LIMIT.low.into()); // kyc limit low
    constructor_calldata.append(KYC_LIMIT.high.into()); // kyc limit high
    
    let (contract_address, _) = contract.deploy(@constructor_calldata).unwrap();
    let dispatcher = IP2PEscrowDispatcher { contract_address };
    
    (contract_address, dispatcher)
}

fn mock_token_address() -> ContractAddress {
    contract_address_const::<'token'>()
}

#[test]
fn test_happy_path_deposit_lock_release() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order1';
    let amount: u128 = 1000;
    let lock_duration: u64 = 3600; // 1 hour
    
    // Mock caller as seller
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    
    // Test deposit
    escrow.deposit(order_id, amount, token);
    
    let order = escrow.orders(order_id);
    assert(order.seller == contract_address_const::<SELLER>(), 'Wrong seller');
    assert(order.amount.low == amount, 'Wrong amount');
    assert(order.token == token, 'Wrong token');
    assert(order.status == 0, 'Wrong status'); // Available
    
    stop_cheat_caller_address(escrow_address);
    
    // Mock caller as buyer
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    
    // Test lock order
    escrow.lockOrder(order_id, lock_duration);
    
    let order = escrow.orders(order_id);
    assert(order.buyer == contract_address_const::<BUYER>(), 'Wrong buyer');
    assert(order.status == 1, 'Wrong status'); // Locked
    assert(order.lockExpiry > 0, 'Lock expiry not set');
    
    // Test release with valid signature
    let sig_r: felt252 = 0x1234;
    let sig_s: felt252 = 0x5678;
    let v: u8 = 27;
    
    escrow.release(order_id, sig_r, sig_s, v);
    
    // Order should be cleared (zeroed out)
    let order = escrow.orders(order_id);
    assert(order.seller.into() == 0, 'Order not cleared');
    assert(order.amount.low == 0, 'Amount not cleared');
    
    stop_cheat_caller_address(escrow_address);
}

#[test]
fn test_refund_after_lock_expiry() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order2';
    let amount: u128 = 500;
    let lock_duration: u64 = 3600; // 1 hour
    
    // Deposit as seller
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.deposit(order_id, amount, token);
    stop_cheat_caller_address(escrow_address);
    
    // Lock as buyer
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    start_cheat_block_timestamp(escrow_address, 1000);
    escrow.lockOrder(order_id, lock_duration);
    stop_cheat_caller_address(escrow_address);
    
    // Fast forward past lock expiry
    start_cheat_block_timestamp(escrow_address, 1000 + lock_duration + 1);
    
    // Refund as seller
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.refund(order_id);
    
    // Order should be cleared
    let order = escrow.orders(order_id);
    assert(order.seller.into() == 0, 'Order not cleared');
    
    stop_cheat_caller_address(escrow_address);
    stop_cheat_block_timestamp(escrow_address);
}

#[test]
#[should_panic(expected: 'ProofAlreadyUsed')]
fn test_replay_attack_prevention() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order3';
    let amount: u128 = 1000;
    let lock_duration: u64 = 3600;
    
    // Setup order
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.deposit(order_id, amount, token);
    stop_cheat_caller_address(escrow_address);
    
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    escrow.lockOrder(order_id, lock_duration);
    
    // First release with signature
    let sig_r: felt252 = 0x1234;
    let sig_s: felt252 = 0x5678;
    let v: u8 = 27;
    
    escrow.release(order_id, sig_r, sig_s, v);
    
    // Try to use the same signature again - should fail
    // Need to create another order first
    stop_cheat_caller_address(escrow_address);
    
    let order_id2: felt252 = 'order4';
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.deposit(order_id2, amount, token);
    stop_cheat_caller_address(escrow_address);
    
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    escrow.lockOrder(order_id2, lock_duration);
    
    // This should panic with ProofAlreadyUsed
    escrow.release(order_id2, sig_r, sig_s, v);
}

#[test]
#[should_panic(expected: 'SignatureInvalid')]
fn test_invalid_signature_rejection() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order5';
    let amount: u128 = 1000;
    let lock_duration: u64 = 3600;
    
    // Setup order
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.deposit(order_id, amount, token);
    stop_cheat_caller_address(escrow_address);
    
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    escrow.lockOrder(order_id, lock_duration);
    
    // Try release with invalid signature (zero components)
    escrow.release(order_id, 0, 0, 27); // Should panic
}

#[test]
#[should_panic(expected: 'OrderExists')]
fn test_duplicate_order_prevention() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order6';
    let amount: u128 = 1000;
    
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    
    // First deposit should succeed
    escrow.deposit(order_id, amount, token);
    
    // Second deposit with same ID should fail
    escrow.deposit(order_id, amount, token);
}

#[test]
#[should_panic(expected: 'ZeroAmount')]
fn test_zero_amount_rejection() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order7';
    
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    
    // Should panic with ZeroAmount
    escrow.deposit(order_id, 0, token);
}

#[test]
#[should_panic(expected: 'KycLimit')]
fn test_kyc_limit_enforcement() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order8';
    let amount: u128 = 2000000; // Exceeds KYC_LIMIT
    
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    
    // Should panic with KycLimit
    escrow.deposit(order_id, amount, token);
}

#[test]
#[should_panic(expected: 'LockActive')]
fn test_refund_blocked_during_active_lock() {
    let (escrow_address, escrow) = deploy_escrow();
    let token = mock_token_address();
    let order_id: felt252 = 'order9';
    let amount: u128 = 1000;
    let lock_duration: u64 = 3600;
    
    // Setup locked order
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    escrow.deposit(order_id, amount, token);
    stop_cheat_caller_address(escrow_address);
    
    start_cheat_caller_address(escrow_address, contract_address_const::<BUYER>());
    start_cheat_block_timestamp(escrow_address, 1000);
    escrow.lockOrder(order_id, lock_duration);
    stop_cheat_caller_address(escrow_address);
    
    // Try to refund while lock is still active (should fail)
    start_cheat_caller_address(escrow_address, contract_address_const::<SELLER>());
    start_cheat_block_timestamp(escrow_address, 1000 + 1800); // Half way through lock
    
    // Should panic with LockActive
    escrow.refund(order_id);
}

#[test]
fn test_proof_signer_update() {
    let (escrow_address, escrow) = deploy_escrow();
    let new_signer: felt252 = 0x987654321;
    
    // Only owner can update proof signer
    start_cheat_caller_address(escrow_address, contract_address_const::<OWNER>());
    escrow.updateProofSigner(new_signer);
    
    assert(escrow.proofSigner() == new_signer, 'Proof signer not updated');
    
    stop_cheat_caller_address(escrow_address);
}

#[test]
fn test_storage_limits() {
    let (escrow_address, escrow) = deploy_escrow();
    
    // Test that view functions return correct initial values
    assert(escrow.MAX_LOCK_DURATION() == MAX_LOCK_DURATION, 'Wrong max lock duration');
    assert(escrow.MXN_KYC_LIMIT() == KYC_LIMIT, 'Wrong KYC limit');
    assert(escrow.whitelistEnabled() == false, 'Whitelist should be disabled');
} 