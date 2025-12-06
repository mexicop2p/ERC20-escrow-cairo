# Glassmorphic Starknet front-end

A Next.js (App Router) dashboard for the Cairo P2P escrow contract. It stitches together Starknet.js mainnet connectivity through the ChipiPay paymaster, CEP (Comprobante Electrónico de Pago) validation using the `cepmex` client, and a responsive glassmorphic UI.

## Key features
- Sponsored Starknet.js calls using the provided paymaster endpoint.
- Ephemeral wallet generation for mainnet accounts.
- Contract calldata builder for `deposit` + `lockOrder`.
- Server-side CEP validation powered by the upstream [`cepmex`](https://pypi.org/project/cepmex/) client.

## Getting started
```bash
cd frontend
npm --version  # ensure npm is available
npm install
CEP_PYTHON_BIN=python3 npm run cep:install   # installs cepmex from PyPI for the validation route (override if your `python` points elsewhere)
npm run dev
```

The CEP validator API route (`/api/validate-cep`) spawns `cep_validate.py` with the JSON body provided, using the `CEP_PYTHON_BIN` environment variable if set (defaulting to `python3`). Ensure Python 3.11+ is available in the environment and that `cep` is installed via the `cep:install` script.

CEP input requirements mirror the upstream `Transferencia.validar` signature:
- `fecha` in `YYYY-MM-DD` format.
- `claveRastreo` must be 6–30 alphanumeric characters.
- `emisor` and `receptor` are 5-digit bank codes (e.g., `90646` for STP, `40012` for BBVA).
- `cuenta` is the 18-digit CLABE.
- `montoCentavos` is an integer amount in cents (must be greater than zero).
- Optional `pagoABanco` toggles transfer types 4/31.

Transactions are executed with `maxFee: 0` through the ChipiPay paymaster (`https://paymaster.chipipay.com`). You must still deploy your account contract on Starknet mainnet and supply its address/private key in the Escrow section before executing calls.
