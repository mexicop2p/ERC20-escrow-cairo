import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "P2P Escrow | Starknet Glass UI",
  description: "Glassmorphic Starknet P2P escrow dashboard with CEP validation & sponsored txs"
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
