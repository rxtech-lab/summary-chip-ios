import type { Metadata, Viewport } from "next";
import { siteUrl } from "@/lib/config";
import "./globals.css";
import "./material.css";

export async function generateMetadata(): Promise<Metadata> {
  return {
    metadataBase: new URL(siteUrl()),
    title: { default: "Chippy", template: "%s · Chippy" },
    description: "Summarise any web page, PDF or note into a shareable card.",
    applicationName: "Chippy",
    openGraph: {
      type: "website",
      siteName: "Chippy",
      title: "Chippy",
      description: "Summarise any web page, PDF or note into a shareable card.",
    },
    twitter: { card: "summary_large_image" },
  };
}

export const viewport: Viewport = {
  themeColor: "#fff8f5",
  colorScheme: "light",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="min-h-dvh">
        {children}
      </body>
    </html>
  );
}
