#[starknet::contract]
mod MockERC20 {
    use starknet::ContractAddress;
    use openzeppelin::token::erc20::ERC20Component;
    use starknet::get_caller_address;
    use core::traits::{Into, TryInto};
    use core::option::OptionTrait;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        initial_supply: u256,
        recipient: ContractAddress
    ) {
        self.erc20.initializer(name.into(), symbol.into());
        self.erc20._mint(recipient, initial_supply);
    }

    #[external(v0)]
    fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
        self.erc20._mint(recipient, amount);
    }
}