import { Account, Call, CallData, Contract, RpcProvider, ec, hash, constants } from "starknet";

export const PAYMASTER_CONFIG = {
  nodeUrl: "https://paymaster.chipipay.com",
  headers: {
    "x-paymaster-api-key": "paymaster_mainnet_7f9e3d2b8c1a4e6f"
  }
};

export const provider = new RpcProvider({
  nodeUrl: PAYMASTER_CONFIG.nodeUrl,
  headers: PAYMASTER_CONFIG.headers
});

export type WalletSeeds = {
  privateKey: string;
  publicKey: string;
};

export const generateWallet = (): WalletSeeds => {
  const privateKey = ec.starkCurve.utils.randomPrivateKey();
  const publicKey = ec.starkCurve.getStarkKey(privateKey);
  return { privateKey, publicKey };
};

export const accountFromSecrets = (accountAddress: string, privateKey: string) => {
  return new Account(provider, accountAddress, privateKey, constants.TransactionVersion.V2);
};

export const connectContract = <TAbi>(address: string, abi: TAbi) => new Contract(abi as never, address, provider);

export const buildDepositCalls = (
  contractAddress: string,
  orderId: string,
  amount: string,
  token: string,
  lockDuration?: string
): Call[] => {
  const calls: Call[] = [
    {
      contractAddress,
      entrypoint: "deposit",
      calldata: CallData.compile({ id: orderId, amount, token })
    }
  ];

  if (lockDuration && lockDuration !== "") {
    calls.push({
      contractAddress,
      entrypoint: "lockOrder",
      calldata: CallData.compile({ id: orderId, duration: lockDuration })
    });
  }

  return calls;
};

export const executeSponsored = async (account: Account, calls: Call[]) => {
  return account.execute(calls, undefined, { maxFee: 0n });
};

export const checksumAddress = (address: string) => hash.starknetKeccak(address);
