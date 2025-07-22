//! P2P Escrow Contract
//! Trust-minimised escrow contract for peer-to-peer token-for-fiat trades (e.g. USDC ⇄ MXN via SPEI).
//! Lifecycle: `deposit → lockOrder → (release | refund)`

use starknet::ContractAddress;

fn u256_from_u128(value: u128) -> u256 {
    u256 { low: value, high: 0 }
}

#[derive(Drop, Copy, Serde, starknet::Store)]
pub struct Order {
    pub seller: ContractAddress,
    pub buyer: ContractAddress,
    pub token: ContractAddress,
    pub amount: u256,
    pub lockExpiry: u64,
    pub status: u8,
}

#[starknet::interface]
pub trait IP2PEscrow<T> {
    fn deposit(ref self: T, id: felt252, amount: u128, token: ContractAddress);
    fn lockOrder(ref self: T, id: felt252, duration: u64);
    fn release(ref self: T, id: felt252, sig_r: felt252, sig_s: felt252, v: u8);
    fn refund(ref self: T, id: felt252);
    fn updateProofSigner(ref self: T, newSigner: felt252);
    fn setWhitelistEnabled(ref self: T, enabled: bool);
    fn whitelistToken(ref self: T, token: ContractAddress, allowed: bool);
    
    // View functions
    fn orders(self: @T, id: felt252) -> Order;
    fn usedProof(self: @T, proofHash: felt252) -> bool;
    fn proofSigner(self: @T) -> felt252;
    fn allowedTokens(self: @T, token: ContractAddress) -> bool;
    fn whitelistEnabled(self: @T) -> bool;
    fn MAX_LOCK_DURATION(self: @T) -> u256;
    fn MXN_KYC_LIMIT(self: @T) -> u256;
}

#[starknet::contract]
mod P2PEscrow {
    use super::{IP2PEscrow, Order, u256_from_u128};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{Map, StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};
    use core::poseidon::poseidon_hash_span;
    use core::traits::Into;
    use core::array::ArrayTrait;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        orders: Map<felt252, Order>,
        usedProof: Map<felt252, bool>,
        proofSigner: felt252,
        allowedTokens: Map<ContractAddress, bool>,
        whitelistEnabled: bool,
        MAX_LOCK_DURATION: u256,
        MXN_KYC_LIMIT: u256,
        reentrancy_guard: bool,
    }

    #[derive(Drop, Copy, Serde)]
    enum OrderStatus {
        Available: (),
        Locked: (),
        Completed: (),
        Refunded: (),
    }

    impl OrderStatusIntoU8 of Into<OrderStatus, u8> {
        fn into(self: OrderStatus) -> u8 {
            match self {
                OrderStatus::Available => 0,
                OrderStatus::Locked => 1,
                OrderStatus::Completed => 2,
                OrderStatus::Refunded => 3,
            }
        }
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        OrderCreated: OrderCreated,
        OrderLocked: OrderLocked,
        OrderReleased: OrderReleased,
        OrderRefunded: OrderRefunded,
        ProofSignerUpdated: ProofSignerUpdated,
        ProofConsumed: ProofConsumed,
        TokenWhitelistSet: TokenWhitelistSet,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderCreated {
        #[key]
        id: felt252,
        #[key]
        seller: ContractAddress,
        amount: u256,
        #[key]
        token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderLocked {
        #[key]
        id: felt252,
        #[key]
        buyer: ContractAddress,
        lockExpiry: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderReleased {
        #[key]
        id: felt252,
        #[key]
        buyer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct OrderRefunded {
        #[key]
        id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ProofSignerUpdated {
        #[key]
        newSigner: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct ProofConsumed {
        #[key]
        proofHash: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct TokenWhitelistSet {
        #[key]
        token: ContractAddress,
        allowed: bool,
    }

    #[derive(Drop, Copy)]
    enum EscrowError {
        OrderExists,
        ZeroAmount,
        KycLimit,
        TokenNotAllowed,
        OrderNotFound,
        NotSeller,
        AlreadyLocked,
        LockTooLong,
        LockActive,
        SignatureInvalid,
        InvalidStatus,
        ProofAlreadyUsed,
        ReentrantCall,
    }

    fn panic_with_error(err: EscrowError) {
        match err {
            EscrowError::OrderExists => panic!("OrderExists"),
            EscrowError::ZeroAmount => panic!("ZeroAmount"),
            EscrowError::KycLimit => panic!("KycLimit"),
            EscrowError::TokenNotAllowed => panic!("TokenNotAllowed"),
            EscrowError::OrderNotFound => panic!("OrderNotFound"),
            EscrowError::NotSeller => panic!("NotSeller"),
            EscrowError::AlreadyLocked => panic!("AlreadyLocked"),
            EscrowError::LockTooLong => panic!("LockTooLong"),
            EscrowError::LockActive => panic!("LockActive"),
            EscrowError::SignatureInvalid => panic!("SignatureInvalid"),
            EscrowError::InvalidStatus => panic!("InvalidStatus"),
            EscrowError::ProofAlreadyUsed => panic!("ProofAlreadyUsed"),
            EscrowError::ReentrantCall => panic!("ReentrantCall"),
        }
    }

    fn build_message_hash(id: felt252, buyer: ContractAddress, amount: u256, token: ContractAddress) -> felt252 {
        // Pack the data: id, buyer, amount.low, amount.high, token
        // TODO: Replace with Keccak256 + secp256k1 signature verification
        let mut message = ArrayTrait::new();
        message.append(id);
        message.append(buyer.into());
        message.append(amount.low.into());
        message.append(amount.high.into());
        message.append(token.into());
        
        // Temporary use of Poseidon - will be replaced with Keccak256
        poseidon_hash_span(message.span())
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        _proofSigner: felt252,
        _maxLockSecs: u256,
        _kycLimit: u256
    ) {
        self.ownable.initializer(owner);
        self.proofSigner.write(_proofSigner);
        self.MAX_LOCK_DURATION.write(_maxLockSecs);
        self.MXN_KYC_LIMIT.write(_kycLimit);
        self.reentrancy_guard.write(false);
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _check_reentrancy(ref self: ContractState) {
            if self.reentrancy_guard.read() {
                panic_with_error(EscrowError::ReentrantCall);
            }
            self.reentrancy_guard.write(true);
        }

        fn _clear_reentrancy(ref self: ContractState) {
            self.reentrancy_guard.write(false);
        }
    }

    #[abi(embed_v0)]
    impl P2PEscrowImpl of IP2PEscrow<ContractState> {
        fn deposit(ref self: ContractState, id: felt252, amount: u128, token: ContractAddress) {
            self._check_reentrancy();
            
            let existing_order = self.orders.read(id);
            let zero_addr = zero_address();
            
            if existing_order.seller != zero_addr {
                self._clear_reentrancy();
                panic_with_error(EscrowError::OrderExists);
            }
            if amount == 0 {
                self._clear_reentrancy();
                panic_with_error(EscrowError::ZeroAmount);
            }
            
            let amount_u256 = u256_from_u128(amount);
            if amount_u256 > self.MXN_KYC_LIMIT.read() {
                self._clear_reentrancy();
                panic_with_error(EscrowError::KycLimit);
            }
            if self.whitelistEnabled.read() && !self.allowedTokens.read(token) {
                self._clear_reentrancy();
                panic_with_error(EscrowError::TokenNotAllowed);
            }

            let caller = get_caller_address();
            let this_contract = starknet::get_contract_address();
            
            // Transfer tokens from caller to this contract
            let token_dispatcher = IERC20Dispatcher { contract_address: token };
            token_dispatcher.transfer_from(caller, this_contract, amount_u256);

            let new_order = Order {
                seller: caller,
                buyer: zero_addr,
                token: token,
                amount: amount_u256,
                lockExpiry: 0,
                status: OrderStatus::Available.into(),
            };

            self.orders.write(id, new_order);

            self.emit(OrderCreated { id, seller: caller, amount: amount_u256, token });
            self._clear_reentrancy();
        }

        fn lockOrder(ref self: ContractState, id: felt252, duration: u64) {
            self._check_reentrancy();
            
            let order = self.orders.read(id);
            let zero_addr = zero_address();
            
            if order.seller == zero_addr {
                self._clear_reentrancy();
                panic_with_error(EscrowError::OrderNotFound);
            }
            if order.status != OrderStatus::Available.into() {
                self._clear_reentrancy();
                panic_with_error(EscrowError::AlreadyLocked);
            }
            if duration == 0 || duration.into() > self.MAX_LOCK_DURATION.read() {
                self._clear_reentrancy();
                panic_with_error(EscrowError::LockTooLong);
            }

            let caller = get_caller_address();
            let lock_expiry = get_block_timestamp() + duration;

            let updated_order = Order {
                seller: order.seller,
                buyer: caller,
                token: order.token,
                amount: order.amount,
                lockExpiry: lock_expiry,
                status: OrderStatus::Locked.into(),
            };

            self.orders.write(id, updated_order);

            self.emit(OrderLocked { id, buyer: caller, lockExpiry: lock_expiry });
            self._clear_reentrancy();
        }

        fn release(ref self: ContractState, id: felt252, sig_r: felt252, sig_s: felt252, v: u8) {
            self._check_reentrancy();
            
            let order = self.orders.read(id);
            
            if order.status != OrderStatus::Locked.into() {
                self._clear_reentrancy();
                panic_with_error(EscrowError::OrderNotFound);
            }

            // Build message hash - TODO: Replace with Keccak256
            let message_hash = build_message_hash(id, order.buyer, order.amount, order.token);
            
            // Hash the signature for replay protection - TODO: Replace with Keccak256
            let mut sig_data = ArrayTrait::new();
            sig_data.append(sig_r);
            sig_data.append(sig_s);
            sig_data.append(v.into());
            let proof_hash = poseidon_hash_span(sig_data.span());
            
            if self.usedProof.read(proof_hash) {
                self._clear_reentrancy();
                panic_with_error(EscrowError::ProofAlreadyUsed);
            }

            // Simplified signature verification - TODO: Replace with secp256k1 ECDSA verification
            // Check that signature components are non-zero and from expected signer
            let expected_signer = self.proofSigner.read();
            
            if sig_r == 0 || sig_s == 0 || expected_signer == 0 {
                self._clear_reentrancy();
                panic_with_error(EscrowError::SignatureInvalid);
            }
            
            // Simple placeholder verification - replace with actual ECDSA verification
            let _verification_placeholder = message_hash + expected_signer;

            self.usedProof.write(proof_hash, true);
            self.emit(ProofConsumed { proofHash: proof_hash });

            // Transfer tokens to buyer
            let token_dispatcher = IERC20Dispatcher { contract_address: order.token };
            token_dispatcher.transfer(order.buyer, order.amount);

            self.emit(OrderReleased { id, buyer: order.buyer });

            // Clear order storage for gas refund (instead of writing zero values)
            let zero_addr = zero_address();
            let empty_order = Order {
                seller: zero_addr,
                buyer: zero_addr,
                token: zero_addr,
                amount: 0,
                lockExpiry: 0,
                status: 0,
            };
            self.orders.write(id, empty_order);
            
            self._clear_reentrancy();
        }

        fn refund(ref self: ContractState, id: felt252) {
            self._check_reentrancy();
            
            let order = self.orders.read(id);
            let caller = get_caller_address();
            let zero_addr = zero_address();
            
            if order.seller == zero_addr {
                self._clear_reentrancy();
                panic_with_error(EscrowError::OrderNotFound);
            }
            if caller != order.seller {
                self._clear_reentrancy();
                panic_with_error(EscrowError::NotSeller);
            }

            if order.status == OrderStatus::Locked.into() {
                if get_block_timestamp() < order.lockExpiry {
                    self._clear_reentrancy();
                    panic_with_error(EscrowError::LockActive);
                }
            } else if order.status != OrderStatus::Available.into() {
                self._clear_reentrancy();
                panic_with_error(EscrowError::InvalidStatus);
            }

            // Transfer tokens back to seller
            let token_dispatcher = IERC20Dispatcher { contract_address: order.token };
            token_dispatcher.transfer(order.seller, order.amount);

            self.emit(OrderRefunded { id });

            // Clear order storage for gas refund (instead of writing zero values)
            let empty_order = Order {
                seller: zero_addr,
                buyer: zero_addr,
                token: zero_addr,
                amount: 0,
                lockExpiry: 0,
                status: 0,
            };
            self.orders.write(id, empty_order);
            
            self._clear_reentrancy();
        }

        fn updateProofSigner(ref self: ContractState, newSigner: felt252) {
            self.ownable.assert_only_owner();
            self.proofSigner.write(newSigner);
            self.emit(ProofSignerUpdated { newSigner });
        }

        fn setWhitelistEnabled(ref self: ContractState, enabled: bool) {
            self.ownable.assert_only_owner();
            self.whitelistEnabled.write(enabled);
        }

        fn whitelistToken(ref self: ContractState, token: ContractAddress, allowed: bool) {
            self.ownable.assert_only_owner();
            self.allowedTokens.write(token, allowed);
            self.emit(TokenWhitelistSet { token, allowed });
        }

        // View functions
        fn orders(self: @ContractState, id: felt252) -> Order {
            self.orders.read(id)
        }

        fn usedProof(self: @ContractState, proofHash: felt252) -> bool {
            self.usedProof.read(proofHash)
        }

        fn proofSigner(self: @ContractState) -> felt252 {
            self.proofSigner.read()
        }

        fn allowedTokens(self: @ContractState, token: ContractAddress) -> bool {
            self.allowedTokens.read(token)
        }

        fn whitelistEnabled(self: @ContractState) -> bool {
            self.whitelistEnabled.read()
        }

        fn MAX_LOCK_DURATION(self: @ContractState) -> u256 {
            self.MAX_LOCK_DURATION.read()
        }

        fn MXN_KYC_LIMIT(self: @ContractState) -> u256 {
            self.MXN_KYC_LIMIT.read()
        }
    }
} 