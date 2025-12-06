# Glassmorphic Starknet front-end

A Next.js (App Router) dashboard for the Cairo P2P escrow contract. It stitches together Starknet.js mainnet connectivity through the ChipiPay paymaster, CEP (Comprobante Electrónico de Pago) validation using `cep-python`, and a responsive glassmorphic UI.

## Key features
- Sponsored Starknet.js calls using the provided paymaster endpoint.
- Ephemeral wallet generation for mainnet accounts.
- Contract calldata builder for `deposit` + `lockOrder`.
- Server-side CEP validation powered by the upstream [`cuenca-mx/cep-python`](https://github.com/cuenca-mx/cep-python) client.

## Getting started
```bash
cd frontend
npm install
npm run cep:install   # installs cep-python from GitHub for the validation route
npm run dev
```

The CEP validator API route (`/api/validate-cep`) spawns `python scripts/cep_validate.py` with the JSON body provided. Ensure Python 3.11+ is available in the environment and that `cep` is installed via the `cep:install` script.

Transactions are executed with `maxFee: 0` through the ChipiPay paymaster (`https://paymaster.chipipay.com`). You must still deploy your account contract on Starknet mainnet and supply its address/private key in the Escrow section before executing calls.
