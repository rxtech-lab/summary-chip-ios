import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { appStoreUrl, MAC_DOWNLOAD_URL } from "@/lib/config";
import { ChippyLogo } from "../chippy-logo";

export const metadata: Metadata = {
  title: "Download",
  description: "Get Chippy for iPhone, iPad and Mac. Drop documents into the app or use the share extension to summarise content from apps and websites.",
  alternates: { canonical: "/download" },
};

type Platform = {
  image: string;
  name: string;
  requirement: string;
  body: string;
  href: string | null;
  cta: string;
};

function platforms(): Platform[] {
  return [
    {
      image: "ios",
      name: "iPhone & iPad",
      requirement: "Requires iOS 26 or later",
      body: "Use the Chippy share extension to summarise web pages and content shared by other apps. Drop supported documents into Chippy, or start from Messages, Siri or the App Clip.",
      href: appStoreUrl(),
      cta: "Download on the App Store",
    },
    {
      image: "mac",
      name: "Mac",
      requirement: "Requires macOS 26 or later",
      body: "Drag and drop a web link, PDF or text document into Chippy, or use the share extension from Safari and other apps. Signed and notarised by Apple, with automatic updates.",
      href: MAC_DOWNLOAD_URL,
      cta: "Download for Mac",
    },
  ];
}

export default function DownloadPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col px-6 py-16 sm:py-24">
      <Link href="/" className="md-brand-link flex w-fit items-center gap-3 text-lg font-semibold">
        <ChippyLogo />
        Chippy
      </Link>
      <h1 className="mt-10 text-4xl font-normal leading-tight tracking-tight sm:text-5xl">
        Get <span className="md-text-primary">Chippy</span>
      </h1>
      <p className="md-text-secondary mt-6 max-w-xl text-lg leading-relaxed">
        Your summaries and points sync across every device signed in to the same account.
      </p>
      <ul className="mt-14 grid gap-4 sm:grid-cols-2">
        {platforms().map((platform) => (
          <li key={platform.name} className="md-card flex flex-col p-6">
            <Image src={`/images/marketing/${platform.image}.webp`} alt="" width={480} height={480} sizes="192px" className="mx-auto h-48 w-48 object-contain" loading="eager" />
            <h2 className="mt-3 text-2xl font-medium">{platform.name}</h2>
            <p className="md-text-secondary mt-2 text-xs font-medium uppercase tracking-wide">{platform.requirement}</p>
            <p className="md-text-secondary mt-4 text-sm leading-relaxed">{platform.body}</p>
            <div className="mt-auto pt-6">
              {platform.href ? (
                <a
                  href={platform.href}
                  className="md-button md-button-filled"
                >
                  {platform.cta}
                </a>
              ) : (
                <span className="md-status">
                  Coming soon to the App Store
                </span>
              )}
            </div>
          </li>
        ))}
      </ul>
      <footer className="md-text-secondary mt-auto flex flex-wrap items-center justify-between gap-4 pt-16 text-sm">
        <span>© {new Date().getFullYear()} RxLab</span>
        <Link href="/" className="md-button md-button-text">About Chippy</Link>
      </footer>
    </main>
  );
}
