import Link from "next/link";
import Image from "next/image";

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-xl flex-col items-center justify-center px-6 text-center">
      <Image src="/images/marketing/unavailable.webp" alt="" width={480} height={480} sizes="192px" className="h-48 w-48 object-contain" loading="eager" />
      <h1 className="mt-6 text-3xl font-normal">This summary isn&apos;t available</h1>
      <p className="md-text-secondary mt-3">It may have expired, been made private, or never existed.</p>
      <Link href="/" className="md-button md-button-filled mt-8">
        About Chippy
      </Link>
      <Link href="/download" className="md-button md-button-text mt-3">
        Download the app
      </Link>
    </main>
  );
}
