import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Summary Chip",
  description: "Summarise any web page, PDF or note into a beautiful card you can share as a link or an image.",
};

const features = [
  { emoji: "🔗", title: "Share from anywhere", body: "Use the share sheet in Safari, Files or any app to summarise a page, PDF or text." },
  { emoji: "✨", title: "A card for every summary", body: "Each summary gets its own colour palette and preview image, ready for Messages and social." },
  { emoji: "🔒", title: "You stay in control", body: "Links expire on your schedule, and you can make any summary private in one tap." },
];

export default function Home() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-3xl flex-col px-6 py-16 sm:py-24">
      <div className="flex items-center gap-3 text-sm font-semibold tracking-wide text-slate-500 dark:text-slate-400">
        <span className="inline-flex h-9 w-9 items-center justify-center rounded-xl bg-gradient-to-br from-indigo-500 to-sky-400 text-lg text-white">S</span>
        Summary Chip
      </div>
      <h1 className="mt-10 text-4xl font-bold leading-tight tracking-tight sm:text-6xl">
        Read less. <span className="bg-gradient-to-r from-indigo-500 to-sky-400 bg-clip-text text-transparent">Share more.</span>
      </h1>
      <p className="mt-6 max-w-xl text-lg leading-relaxed text-slate-600 dark:text-slate-300">
        Summary Chip turns long articles, PDFs and notes into short, beautiful summary cards — then lets you share them as a link or an image.
      </p>
      <ul className="mt-14 grid gap-4 sm:grid-cols-3">
        {features.map((feature) => (
          <li key={feature.title} className="rounded-2xl border border-slate-200 p-5 dark:border-slate-800">
            <div className="text-2xl" aria-hidden>{feature.emoji}</div>
            <h2 className="mt-3 font-semibold">{feature.title}</h2>
            <p className="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-400">{feature.body}</p>
          </li>
        ))}
      </ul>
      <footer className="mt-auto pt-16 text-sm text-slate-500 dark:text-slate-500">© {new Date().getFullYear()} RxLab</footer>
    </main>
  );
}
