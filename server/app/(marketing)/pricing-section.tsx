import Link from "next/link";
import { Suspense } from "react";
import { formatTopUpPrice, getPricingTopUps } from "@/lib/subscription/pricing";

async function TopUpPacks() {
  const packs = await getPricingTopUps();
  if (packs === null) {
    return <p className="pricing-notice" role="status">Prices are temporarily unavailable. Open Chippy to check available top-ups.</p>;
  }
  if (packs.length === 0) {
    return <p className="pricing-notice">No points packs are available right now. Check back in Chippy.</p>;
  }
  return (
    <ul className="pricing-packs" aria-label="Points packs">
      {packs.map(pack => (
        <li key={pack.id} className="pricing-pack">
          <div>
            <h4 className="text-lg font-medium">{pack.name}</h4>
            <p className="md-text-secondary mt-1">{pack.amount.toLocaleString("en-US")} points</p>
            {pack.description && <p className="md-text-secondary mt-2 text-sm leading-relaxed">{pack.description}</p>}
          </div>
          <div className="pricing-pack-price">
            <span className="text-xl font-medium">{formatTopUpPrice(pack)}</span>
            <span className="md-text-secondary mt-1 text-sm">one-time</span>
          </div>
        </li>
      ))}
    </ul>
  );
}

export function PricingSection() {
  return (
    <section id="pricing" tabIndex={-1} aria-labelledby="pricing-title" className="scroll-mt-20 px-6">
      <div className="mx-auto max-w-6xl">
        <div className="chapter-head mx-auto max-w-2xl text-center">
          <p className="md-eyebrow">Simple pricing</p>
          <h2 id="pricing-title" className="mt-3 text-4xl tracking-tight sm:text-5xl">Start free. Top up when you need more.</h2>
          <p className="md-text-secondary mt-5 text-lg leading-relaxed">A free workspace for your ideas, with points for the moments you want to do more. No recurring subscription.</p>
        </div>
        <div className="pricing-grid mt-14">
          <article className="pricing-card pricing-free">
            <p className="md-eyebrow">Your starting point</p>
            <h3 className="mt-4 text-3xl font-medium">Free</h3>
            <p className="pricing-amount">$0<span>to get started</span></p>
            <p className="md-text-secondary leading-relaxed">Bring your chips, podcasts, papers and trips together in one workspace.</p>
            <ul className="pricing-benefits">
              <li>Free summary allowance included</li>
              <li>Connect your AI assistant through MCP</li>
              <li>Keep your library across iPhone, iPad and Mac</li>
            </ul>
            <p className="md-text-secondary mb-6 text-sm leading-relaxed">See your current summary allowance and reset time in Chippy.</p>
            <Link href="/download" className="md-button md-button-filled pricing-action">Get started free</Link>
          </article>
          <article className="pricing-card">
            <p className="md-eyebrow">As you go</p>
            <h3 className="mt-4 text-3xl font-medium">Points top-ups</h3>
            <p className="md-text-secondary mt-5 leading-relaxed">Add points for extra summaries and AI features such as chat, translation and podcast creation.</p>
            <Suspense fallback={<p className="pricing-notice" role="status">Loading current top-up prices…</p>}>
              <TopUpPacks />
            </Suspense>
            <p className="md-text-secondary mb-6 text-sm leading-relaxed">Web prices shown. In-app prices may vary by store and region. Review the final price and availability before purchase.</p>
            <Link href="/download" className="md-button md-button-tonal pricing-action">Get Chippy to top up</Link>
            <p className="md-text-secondary mt-4 text-sm">In Chippy: Settings → Summaries &amp; Points → Top-ups</p>
          </article>
        </div>
      </div>
    </section>
  );
}
