import Head from "next/head";
import { useRouter } from "next/router";
import { useState } from "react";
import CreateGameConfigBar from "@/components/CreateGameConfigBar";
import type { CreateGameConfigInput } from "@/components/CreateGameConfigBar";
import RequireWallet from "@/components/RequireWallet";
import { depositA } from "@/transactions/tx";
import { BlockfrostProvider } from "@meshsdk/core";
import { useWallet } from "@meshsdk/react";

type OnchainConfigResponse = {
  blockfrostId?: string;
  pythPolicyId?: string;
  backendPkh?: string;
  plutus?: { validators: Array<{ title: string; compiledCode: string }> };
  error?: string;
};

export default function CreateGamePage() {
  const router = useRouter();
  const { address, wallet } = useWallet();
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleCreate(config: CreateGameConfigInput) {
    if (!address) {
      setError("Wallet address is still loading. Please wait and try again.");
      return;
    }

    setCreating(true);
    setError(null);

    try {
      const lovelace = Math.round(config.betAda * 1_000_000);
      if (!Number.isFinite(lovelace) || lovelace <= 0) {
        throw new Error("Invalid bet amount");
      }

      const response = await fetch("/api/games", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          config,
          creatorWallet: address,
        }),
      });

      const data = (await response.json()) as { game?: { id: string }; error?: string };
      if (!response.ok || !data.game?.id) {
        throw new Error(data.error ?? "Could not create game");
      }

      const onchainConfigRes = await fetch("/api/onchain/deposit-a-config");
      const onchainConfig = (await onchainConfigRes.json()) as OnchainConfigResponse;
      if (!onchainConfigRes.ok) {
        throw new Error(onchainConfig.error ?? "Could not load on-chain config");
      }
      if (
        !onchainConfig.blockfrostId ||
        !onchainConfig.pythPolicyId ||
        !onchainConfig.backendPkh ||
        !onchainConfig.plutus
      ) {
        throw new Error("Incomplete on-chain config");
      }

      const provider = new BlockfrostProvider(onchainConfig.blockfrostId);
      const utxos = await wallet.getUtxos();
      const depositResult = await depositA({
        provider,
        wallet,
        utxos,
        playerOneAddress: address,
        backendPkh: onchainConfig.backendPkh,
        pythPolicyId: onchainConfig.pythPolicyId,
        plutus: onchainConfig.plutus,
        bet_lovelace: lovelace,
      });
      console.log(depositResult);
      const txUrl = `https://preprod.cardanoscan.io/transaction/${depositResult.txHash}`;
      
      console.log(`[create-game] depositA tx: ${depositResult.txHash}`);
      console.log(`[create-game] explorer: ${txUrl}`);

      await router.push(`/game/${data.game.id}`);
    } catch (err) {
      const message = err instanceof Error ? err.message : "Could not create game";
      setError(message);
    } finally {
      setCreating(false);
    }
  }

  return (
    <>
      <Head>
        <title>Create Game</title>
      </Head>
      <main className="mx-auto min-h-[60vh] w-[92%] max-w-6xl py-10">
        <RequireWallet
          title="Connect your  Wallet To Create a Game"
          description="Connect your wallet to configure the game."
        >
          <CreateGameConfigBar creating={creating} error={error} onCreate={handleCreate} />
        </RequireWallet>
      </main>
    </>
  );
}
