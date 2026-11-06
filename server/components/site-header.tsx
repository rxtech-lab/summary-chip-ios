import Link from "next/link";
import { ChippyLogo } from "@/app/(marketing)/chippy-logo";

export function SiteHeader({ discover = false }: { discover?: boolean }) {
  return (
      <header className="site-header md-appbar fixed inset-x-0 top-0 z-40">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <Link href="/" className="md-brand-link flex items-center gap-3 text-lg font-semibold">
            <ChippyLogo />
            Chippy
          </Link>
          <nav className="flex items-center gap-2" aria-label="Main navigation">
            <Link href="/discover" className="md-button md-button-text" aria-current={discover ? "page" : undefined}>Discover</Link>
            <Link href="/download" className="md-button md-button-filled">Download</Link>
          </nav>
        </div>
      </header>
  );
}
