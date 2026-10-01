import Link from "next/link";

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-xl flex-col items-center justify-center px-6 text-center">
      <div className="text-5xl" aria-hidden>🫥</div>
      <h1 className="mt-6 text-2xl font-bold">This summary isn&apos;t available</h1>
      <p className="mt-3 text-slate-600 dark:text-slate-400">It may have expired, been made private, or never existed.</p>
      <Link href="/" className="mt-8 rounded-full bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white dark:bg-white dark:text-slate-900">
        About Chippy
      </Link>
    </main>
  );
}
