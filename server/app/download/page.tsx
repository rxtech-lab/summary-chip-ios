import type { Metadata } from "next";
import Link from "next/link";
import { appStoreUrl, MAC_DOWNLOAD_URL } from "@/lib/config";

export const metadata: Metadata = {
  title: "Download",
  description: "Get Chippy for iPhone, iPad and Mac.",
  alternates: { canonical: "/download" },
};

type Platform = {
  emoji: string;
  name: string;
  requirement: string;
  body: string;
  href: string | null;
  cta: string;
};

function platforms(): Platform[] {
  return [
    {
      emoji: "📱",
      name: "iPhone & iPad",
      requirement: "Requires iOS 26 or later",
      body: "Summarise from the share sheet, Messages and Siri, or try it instantly with the App Clip.",
      href: appStoreUrl(),
      cta: "Download on the App Store",
    },
    {
      emoji: "💻",
      name: "Mac",
      requirement: "Requires macOS 26 or later",
      body: "Signed and notarised by Apple. Updates install automatically from inside the app.",
      href: MAC_DOWNLOAD_URL,
      cta: "Download for Mac",
    },
  ];
}

export default function DownloadPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col px-6 py-16 sm:py-24">
      <Link href="/" className="flex items-center gap-3 text-sm font-semibold tracking-wide text-slate-500 dark:text-slate-400">
        <span className="inline-flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-br from-indigo-500 to-sky-400 text-lg text-white">S</span>
        Chippy
      </Link>
      <h1 className="mt-10 text-4xl font-bold leading-tight tracking-tight sm:text-5xl">
        Get <span className="bg-gradient-to-r from-indigo-500 to-sky-400 bg-clip-text text-transparent">Chippy</span>
      </h1>
      <p className="mt-6 max-w-xl text-lg leading-relaxed text-slate-600 dark:text-slate-300">
        Your summaries and points sync across every device signed in to the same account.
      </p>
      <ul className="mt-14 grid gap-4 sm:grid-cols-2">
        {platforms().map((platform) => (
          <li key={platform.name} className="flex flex-col rounded-2xl border border-slate-200 p-6 dark:border-slate-800">
            <div className="text-3xl" aria-hidden>{platform.emoji}</div>
            <h2 className="mt-3 text-xl font-semibold">{platform.name}</h2>
            <p className="mt-1 text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">{platform.requirement}</p>
            <p className="mt-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">{platform.body}</p>
            <div className="mt-auto pt-6">
              {platform.href ? (
                <a
                  href={platform.href}
                  className="inline-flex rounded-full bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white dark:bg-white dark:text-slate-900"
                >
                  {platform.cta}
                </a>
              ) : (
                <span className="inline-flex rounded-full border border-slate-200 px-5 py-2.5 text-sm font-semibold text-slate-500 dark:border-slate-800 dark:text-slate-400">
                  Coming soon to the App Store
                </span>
              )}
            </div>
          </li>
        ))}
      </ul>
      <footer className="mt-auto pt-16 text-sm text-slate-500 dark:text-slate-500">© {new Date().getFullYear()} RxLab</footer>
    </main>
  );
}
