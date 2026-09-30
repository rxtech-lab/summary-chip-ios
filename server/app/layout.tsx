import type { Metadata, Viewport } from "next";
import { siteUrl } from "@/lib/config";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  return {
    metadataBase: new URL(siteUrl()),
    title: { default: "Summary Chip", template: "%s · Summary Chip" },
    description: "Summarise any web page, PDF or note into a shareable card.",
    applicationName: "Summary Chip",
  };
}

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0b0f19" },
  ],
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="min-h-dvh bg-white text-slate-900 dark:bg-[#0b0f19] dark:text-slate-100 font-sans">
        {children}
      </body>
    </html>
  );
}
