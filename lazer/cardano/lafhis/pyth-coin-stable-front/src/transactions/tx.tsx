import {
  MeshTxBuilder,
  applyParamsToScript,
  mConStr0,
  mConStr1,
  resolvePaymentKeyHash,
  resolveScriptHash,
  resolveSlotNo,
  serializePlutusScript,
} from "@meshsdk/core";

const DEFAULT_FEED_A = 16; // ADA/USD

type TxInputRef = {
  txHash: string;
  outputIndex: number;
};

type UtxoLike = {
  input: TxInputRef;
};

type ProviderLike = {
  fetchTxInfo?: (txHash: string) => Promise<unknown>;
};

type WalletLike = {
  signTx: (unsignedTx: string) => Promise<string>;
  submitTx: (signedTx: string) => Promise<string>;
};

type PlutusValidator = {
  title: string;
  compiledCode: string;
};

type PlutusJson = {
  validators: PlutusValidator[];
};

export type DepositAParams = {
  provider: ProviderLike;
  wallet: WalletLike;
  utxos: UtxoLike[];
  playerOneAddress: string;
  playerPkh?: string;
  backendPkh: string;
  pythPolicyId: string;
  plutus: PlutusJson;
  feedA?: number;
  bet_lovelace: number;
  network?: "preprod" | "preview" | "mainnet";
  networkId?: 0 | 1;
};

export type DepositAResult = {
  txHash: string;
  duelId: string;
  scriptAddress: string;
  spendScriptHash: string;
  mintPolicyId: string;
};

const cborBytesParam = (hex: string) => {
  const len = hex.length / 2;
  if (len < 24) return (0x40 | len).toString(16).padStart(2, "0") + hex;
  if (len < 256) return "58" + len.toString(16).padStart(2, "0") + hex;
  return (
    "59" +
    (len >> 8).toString(16).padStart(2, "0") +
    (len & 0xff).toString(16).padStart(2, "0") +
    hex
  );
};

const someD = (inner: unknown) => mConStr0([inner as never]);
const noneD = () => mConStr1([]);

const playerD = ({
  pkh,
  feedId,
  startPrice,
}: {
  pkh: string;
  feedId: number;
  startPrice: number | null;
}) => mConStr0([pkh, feedId, startPrice != null ? someD(startPrice) : noneD()]);

const duelDatumD = ({
  duelId,
  playerA,
  betLovelace,
}: {
  duelId: string;
  playerA: { pkh: string; feedId: number; startPrice: number | null };
  betLovelace: number;
}) =>
  mConStr0([
    duelId,
    playerD(playerA),
    noneD(),
    betLovelace,
    mConStr0([]),
    noneD(),
  ]);

const outputRefD = (txHash: string, index: number) => mConStr0([txHash, index]);

function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) throw new Error("Invalid hex length");
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = Number.parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function u64beBytes(value: number): Uint8Array {
  const view = new DataView(new ArrayBuffer(8));
  view.setBigUint64(0, BigInt(value));
  return new Uint8Array(view.buffer);
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const data = new Uint8Array(bytes.byteLength);
  data.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return bytesToHex(new Uint8Array(digest));
}

async function computeDuelId(txHash: string, outputIndex: number): Promise<string> {
  const txHashBytes = hexToBytes(txHash);
  const indexBytes = u64beBytes(outputIndex);
  return sha256Hex(concatBytes(txHashBytes, indexBytes));
}

function getCompiledCode(plutus: PlutusJson, title: string): string {
  const code = plutus.validators.find((v) => v.title === title)?.compiledCode;
  if (!code) throw new Error(`Missing compiled code for validator title: ${title}`);
  return code;
}

function requiredString(name: string, value: string): string {
  if (!value || !value.trim()) throw new Error(`Missing required value: ${name}`);
  return value.trim();
}

export async function depositA({
  provider,
  wallet,
  utxos,
  playerOneAddress,
  playerPkh,
  backendPkh,
  pythPolicyId,
  plutus,
  feedA = DEFAULT_FEED_A,
  bet_lovelace,
  network = "preprod",
  networkId = 0,
}: DepositAParams): Promise<DepositAResult> {
  if (!utxos.length) {
    throw new Error("No UTxOs available in wallet");
  }

  const sanitizedBackendPkh = requiredString("backendPkh", backendPkh);
  const sanitizedPythPolicyId = requiredString("pythPolicyId", pythPolicyId);
  const sanitizedAddress = requiredString("playerOneAddress", playerOneAddress);
  const sanitizedPlayerPkh =
    playerPkh?.trim() && playerPkh.trim().length > 0
      ? playerPkh.trim()
      : resolvePaymentKeyHash(sanitizedAddress);
  if (!Number.isFinite(bet_lovelace) || bet_lovelace <= 0) {
    throw new Error("bet_lovelace must be a positive number");
  }
  const finalBetLovelace = bet_lovelace;

  const nftCompiledCode = getCompiledCode(plutus, "nft.nft_policy.mint");
  const betCompiledCode = getCompiledCode(plutus, "validators.bet.spend");

  const mintScriptCbor = applyParamsToScript(
    nftCompiledCode,
    [cborBytesParam(sanitizedBackendPkh)],
    "CBOR",
  );
  const mintPolicyId = resolveScriptHash(mintScriptCbor, "V3");

  const spendScriptCbor = applyParamsToScript(
    betCompiledCode,
    [
      cborBytesParam(sanitizedBackendPkh),
      cborBytesParam(mintPolicyId),
      cborBytesParam(sanitizedPythPolicyId),
    ],
    "CBOR",
  );

  const spendScriptHash = resolveScriptHash(spendScriptCbor, "V3");
  const scriptAddress = serializePlutusScript(
    { code: spendScriptCbor, version: "V3" },
    undefined,
    networkId,
    false,
  ).address;

  const seed = utxos[0].input;
  const collateral = utxos[1]?.input ?? seed;
  const duelId = await computeDuelId(seed.txHash, seed.outputIndex);

  const datum = duelDatumD({
    duelId,
    playerA: { pkh: sanitizedPlayerPkh, feedId: feedA, startPrice: null },
    betLovelace: finalBetLovelace,
  });

  const mintRedeemer = mConStr0([outputRefD(seed.txHash, seed.outputIndex)]);

  const nowSlot = resolveSlotNo(network, Date.now());

  let tx = new MeshTxBuilder({ fetcher: provider as never, submitter: provider as never });
  tx = tx.invalidBefore(Number(nowSlot) - 600);
  tx = tx.invalidHereafter(Number(nowSlot) + 600);
  tx = tx.txInCollateral(collateral.txHash, collateral.outputIndex);
  tx = tx.txIn(seed.txHash, seed.outputIndex);
  tx = tx.mintPlutusScriptV3();
  tx = tx.mint("1", mintPolicyId, duelId);
  tx = tx.mintingScript(mintScriptCbor);
  tx = tx.mintRedeemerValue(mintRedeemer);
  tx = tx.txOut(scriptAddress, [
    { unit: "lovelace", quantity: String(finalBetLovelace) },
    { unit: mintPolicyId + duelId, quantity: "1" },
  ]);
  tx = tx.txOutInlineDatumValue(datum);
  tx = tx.changeAddress(sanitizedAddress);
  tx = tx.selectUtxosFrom(utxos as never);

  const unsigned = await tx.complete();
  const signed = await wallet.signTx(unsigned);
  const txHash = await wallet.submitTx(signed);

  return {
    txHash,
    duelId,
    scriptAddress,
    spendScriptHash,
    mintPolicyId,
  };
}
