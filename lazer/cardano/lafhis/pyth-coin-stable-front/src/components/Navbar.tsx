import { CardanoWallet } from "@meshsdk/react";

export default function Navbar() {
  return (
    <nav className="top-nav mx-auto mt-6 flex w-[92%] max-w-6xl items-center justify-between gap-4 rounded-2xl border border-amber-300/35 bg-stone-950/80 px-4 py-3 md:px-6">
      <div className="flex items-center gap-2 md:gap-3">
        <a className="nav-chip" href="#">
          Create Game
        </a>
        <a className="nav-chip" href="#">
          Join Game
        </a>
      </div>

      <CardanoWallet />
    </nav>
  );
}
