import Link from "next/link";

export function PricingSection() {
  return (
    <section id="pricing" tabIndex={-1} aria-labelledby="pricing-title" className="scroll-mt-20 px-6">
      <div className="mx-auto max-w-6xl">
        <div className="chapter-head mx-auto max-w-2xl text-center">
          <h2 id="pricing-title" className="text-4xl tracking-tight sm:text-5xl">Chippy AI is included with Flowcy Plus</h2>
          <p className="md-text-secondary mt-5 text-lg leading-relaxed">Use Chippy to organize your library and create chips for free. Subscribe to Flowcy Plus with your RxLab account to unlock AI summaries, chat, voice, podcasts, audiobooks, and translations.</p>
        </div>
        <div className="pricing-grid mt-14">
          <article className="pricing-card pricing-flowcy">
            <h3 className="text-3xl font-medium">Flowcy Plus</h3>
            <p className="md-text-secondary my-6 leading-relaxed">Subscribe on Flowcy to unlock AI features in Chippy across your devices.</p>
            <a href="https://www.flowcy.dev/dashboard/settings/billing" className="md-button md-button-filled pricing-action">Subscribe on Flowcy</a>
          </article>
          <article className="pricing-card">
            <h3 className="text-3xl font-medium">Subscribe in Chippy for iOS</h3>
            <p className="md-text-secondary my-6 leading-relaxed">Sign in with RxLab and choose the monthly Flowcy Plus subscription in the app. The App Store shows the price for your region.</p>
            <Link href="/download" className="md-button md-button-tonal pricing-action">Get Chippy</Link>
          </article>
        </div>
      </div>
    </section>
  );
}
