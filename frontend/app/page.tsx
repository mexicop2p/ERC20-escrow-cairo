"use client";

import { useMemo, useState } from "react";
import { z } from "zod";
import escrowAbi from "./abi/p2pEscrow.json";
import { cepSchema, type CepPayload, type CepValidationResult, validateCep } from "../lib/cep";
import {
  PAYMASTER_CONFIG,
  accountFromSecrets,
  buildDepositCalls,
  executeSponsored,
  generateWallet
} from "../lib/starknet";
import type { Call } from "starknet";

const escrowSchema = z.object({
  contractAddress: z.string().min(3),
  accountAddress: z.string().min(3),
  privateKey: z.string().min(3),
  orderId: z.string().min(1),
  amount: z.string().min(1),
  token: z.string().min(3),
  lockDuration: z.string().optional()
});

export default function Home() {
  const [cepPayload, setCepPayload] = useState<CepPayload>({
    fecha: new Date().toISOString().slice(0, 10),
    claveRastreo: "",
    emisor: "90646",
    receptor: "40012",
    cuenta: "012180004643051249",
    montoCentavos: 0,
    pagoABanco: false
  });
  const [cepResult, setCepResult] = useState<CepValidationResult | null>(null);
  const [cepBusy, setCepBusy] = useState(false);

  const [wallet, setWallet] = useState(() => generateWallet());
  const [escrowForm, setEscrowForm] = useState({
    contractAddress: "",
    accountAddress: "",
    privateKey: "",
    orderId: "",
    amount: "0",
    token: "",
    lockDuration: ""
  });
  const [callsPreview, setCallsPreview] = useState<Call[]>([]);
  const [txHash, setTxHash] = useState<string | null>(null);
  const [txError, setTxError] = useState<string | null>(null);
  const [txPending, setTxPending] = useState(false);

  const escrowFunctions = useMemo(
    () =>
      (escrowAbi as { type?: string; name?: string }[])
        .filter((item) => item.type === "function" && item.name)
        .map((item) => item.name as string),
    []
  );

  const cepValid = useMemo(() => {
    const validation = cepSchema.safeParse(cepPayload);
    return validation.success;
  }, [cepPayload]);

  const handleCepChange = (key: keyof CepPayload, value: string | number | boolean) => {
    setCepPayload((prev) => ({ ...prev, [key]: value }));
  };

  const submitCep = async () => {
    setCepBusy(true);
    setTxError(null);
    const parsed = cepSchema.safeParse(cepPayload);
    if (!parsed.success) {
      setCepResult({ valid: false, error: parsed.error.errors[0]?.message });
      setCepBusy(false);
      return;
    }

    const result = await validateCep(parsed.data);
    setCepResult(result);
    setCepBusy(false);
  };

  const createCalls = () => {
    const parsed = escrowSchema.safeParse(escrowForm);
    if (!parsed.success) {
      setTxError(parsed.error.errors[0]?.message ?? "Check form values");
      return [] as Call[];
    }
    const calls = buildDepositCalls(
      parsed.data.contractAddress,
      parsed.data.orderId,
      parsed.data.amount,
      parsed.data.token,
      parsed.data.lockDuration
    );
    setCallsPreview(calls);
    return calls;
  };

  const executeEscrow = async () => {
    const calls = createCalls();
    if (!calls.length) return;
    try {
      setTxPending(true);
      setTxError(null);
      const parsed = escrowSchema.parse(escrowForm);
      const account = accountFromSecrets(parsed.accountAddress, parsed.privateKey);
      const receipt = await executeSponsored(account, calls);
      setTxHash(receipt.transaction_hash ?? "");
    } catch (error) {
      console.error(error);
      setTxError((error as Error).message);
    } finally {
      setTxPending(false);
    }
  };

  const regenerateWallet = () => setWallet(generateWallet());

  return (
    <main>
      <div className="badge">Starknet Mainnet · Sponsored via ChipiPay Paymaster</div>
      <h1>Glassmorphic P2P Escrow</h1>
      <p className="lead">
        Responsive, type-safe Next.js dashboard that wires your P2P escrow contract to Starknet.js with
        paymaster sponsorship and CEP (Comprobante Electrónico de Pago) validation backed by the cep-python
        client.
      </p>

      <div className="card-grid">
        <section className="glass">
          <div className="status">
            <span className="badge">Wallets</span>
            <span>
              Paymaster RPC: <strong>{PAYMASTER_CONFIG.nodeUrl}</strong>
            </span>
          </div>
          <div className="divider" />
          <div className="stack">
            <div>
              <div className="label">Generated private key</div>
              <code className="block">{wallet.privateKey}</code>
            </div>
            <div>
              <div className="label">Public key</div>
              <code className="block">{wallet.publicKey}</code>
            </div>
            <button className="primary" onClick={regenerateWallet}>Regenerate sponsor wallet</button>
            <p className="small">
              Use the generated secrets to deploy/declare an account contract on Starknet mainnet. Transactions
              executed with this provider are routed through the paymaster endpoint with zero-fee intent
              ({"maxFee: 0"}).
            </p>
          </div>
        </section>

        <section className="glass">
          <div className="status">
            <span className="badge">CEP validation</span>
            <span>Validated with cep-python via serverless route</span>
          </div>
          <div className="divider" />
          <div className="stack">
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="fecha">
                  Fecha (YYYY-MM-DD)
                </label>
                <input
                  className="input"
                  id="fecha"
                  type="date"
                  value={cepPayload.fecha}
                  onChange={(e) => handleCepChange("fecha", e.target.value)}
                />
              </div>
              <div>
                <label className="label" htmlFor="clave">
                  Clave de rastreo
                </label>
                <input
                  className="input"
                  id="clave"
                  value={cepPayload.claveRastreo}
                  onChange={(e) => handleCepChange("claveRastreo", e.target.value)}
                  placeholder="000000000000"
                />
              </div>
            </div>
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="emisor">
                  Banco emisor (clave de banco, 5 dígitos)
                </label>
                <input
                  className="input"
                  id="emisor"
                  inputMode="numeric"
                  pattern="\\d{5}"
                  placeholder="90646"
                  value={cepPayload.emisor}
                  onChange={(e) => handleCepChange("emisor", e.target.value)}
                />
              </div>
              <div>
                <label className="label" htmlFor="receptor">
                  Banco receptor (clave de banco, 5 dígitos)
                </label>
                <input
                  className="input"
                  id="receptor"
                  inputMode="numeric"
                  pattern="\\d{5}"
                  placeholder="40012"
                  value={cepPayload.receptor}
                  onChange={(e) => handleCepChange("receptor", e.target.value)}
                />
              </div>
            </div>
            <div>
              <label className="label" htmlFor="cuenta">
                Cuenta beneficiaria (CLABE 18 dígitos)
              </label>
              <input
                className="input"
                id="cuenta"
                inputMode="numeric"
                pattern="\\d{18}"
                placeholder="012180004643051249"
                value={cepPayload.cuenta}
                onChange={(e) => handleCepChange("cuenta", e.target.value)}
              />
            </div>
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="monto">
                  Monto (centavos)
                </label>
                <input
                  className="input"
                  id="monto"
                  type="number"
                  value={cepPayload.montoCentavos}
                  onChange={(e) => handleCepChange("montoCentavos", Number(e.target.value))}
                />
              </div>
              <div className="status">
                <input
                  id="pagoBanco"
                  type="checkbox"
                  checked={cepPayload.pagoABanco}
                  onChange={(e) => handleCepChange("pagoABanco", e.target.checked)}
                />
                <label className="label" htmlFor="pagoBanco">
                  Pago a banco
                </label>
              </div>
            </div>
            <button className="primary" onClick={submitCep} disabled={!cepValid || cepBusy}>
              {cepBusy ? "Validando..." : "Validar CEP"}
            </button>
            {cepResult && (
              <div className="stack">
                <div className="status">
                  Estado: <strong>{cepResult.valid ? "Transferencia válida" : "Sin coincidencia"}</strong>
                </div>
                {cepResult.error && <code className="block">{cepResult.error}</code>}
                {cepResult.transferencia && (
                  <code className="block">{JSON.stringify(cepResult.transferencia, null, 2)}</code>
                )}
              </div>
            )}
          </div>
        </section>

        <section className="glass">
          <div className="status">
            <span className="badge">Escrow contract</span>
            <span>Deposit + lock with sponsored Starknet.js calls</span>
          </div>
          <div className="divider" />
          <div className="stack">
            <div>
              <label className="label" htmlFor="contract">Contract address</label>
              <input
                className="input"
                id="contract"
                value={escrowForm.contractAddress}
                onChange={(e) => setEscrowForm({ ...escrowForm, contractAddress: e.target.value })}
                placeholder="0x..."
              />
            </div>
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="account">Account address</label>
                <input
                  className="input"
                  id="account"
                  value={escrowForm.accountAddress}
                  onChange={(e) => setEscrowForm({ ...escrowForm, accountAddress: e.target.value })}
                />
              </div>
              <div>
                <label className="label" htmlFor="priv">Private key</label>
                <input
                  className="input"
                  id="priv"
                  value={escrowForm.privateKey}
                  onChange={(e) => setEscrowForm({ ...escrowForm, privateKey: e.target.value })}
                />
              </div>
            </div>
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="order">Order id</label>
                <input
                  className="input"
                  id="order"
                  value={escrowForm.orderId}
                  onChange={(e) => setEscrowForm({ ...escrowForm, orderId: e.target.value })}
                />
              </div>
              <div>
                <label className="label" htmlFor="amount">Amount (wei)</label>
                <input
                  className="input"
                  id="amount"
                  type="number"
                  value={escrowForm.amount}
                  onChange={(e) => setEscrowForm({ ...escrowForm, amount: e.target.value })}
                />
              </div>
            </div>
            <div className="grid-2">
              <div>
                <label className="label" htmlFor="token">ERC20 token</label>
                <input
                  className="input"
                  id="token"
                  value={escrowForm.token}
                  onChange={(e) => setEscrowForm({ ...escrowForm, token: e.target.value })}
                />
              </div>
              <div>
                <label className="label" htmlFor="lock">Lock duration (seconds)</label>
                <input
                  className="input"
                  id="lock"
                  value={escrowForm.lockDuration}
                  onChange={(e) => setEscrowForm({ ...escrowForm, lockDuration: e.target.value })}
                  placeholder="Optional"
                />
              </div>
            </div>
            <p className="small">
              Contract entrypoints detected: {escrowFunctions.join(", ") || "(abi loaded)"}
            </p>
            <button className="secondary" onClick={createCalls}>Preview calldata</button>
            <button className="primary" onClick={executeEscrow} disabled={txPending}>
              {txPending ? "Enviando transacción..." : "Ejecutar depósito patrocinado"}
            </button>
            {callsPreview.length > 0 && (
              <code className="block">{JSON.stringify(callsPreview, null, 2)}</code>
            )}
            {txHash && (
              <div className="status">
                <span>Tx hash:</span>
                <code className="block">{txHash}</code>
              </div>
            )}
            {txError && <code className="block">{txError}</code>}
          </div>
        </section>
      </div>
    </main>
  );
}
