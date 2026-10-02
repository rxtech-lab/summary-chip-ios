import type { CSSProperties } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { ChippyLogo } from "./chippy-logo";
import { BrandIntro } from "./brand-intro";
import "./landing.css";

export const metadata: Metadata = {
  title: { absolute: "Chippy — Read less. Share more." },
  description: "Drag and drop documents, or use the Chippy share extension to summarise content from apps and websites into beautiful, shareable cards.",
};

type SampleCard = {
  image: string;
  category: string;
  title: string;
  source: string;
  colors: [string, string];
};

const samples: SampleCard[] = [
  { image: "climate", category: "Climate", title: "Why cities are painting their roofs white", source: "Article · 8 min read", colors: ["#ffb29b", "#f57f6b"] },
  { image: "science", category: "Science", title: "How sleep turns the day into memory", source: "PDF · 24 pages", colors: ["#303b60", "#17213f"] },
  { image: "finance", category: "Finance", title: "The quiet comeback of index funds", source: "Article · 12 min read", colors: ["#ffd3c4", "#ff987f"] },
  { image: "tech", category: "Tech", title: "What the new chip actually changes", source: "Note", colors: ["#ff987f", "#e0654f"] },
];

type Feature = {
  eyebrow: string;
  title: string;
  body: string;
  sample: SampleCard;
  illustration?: "drop" | "share";
};

const features: Feature[] = [
  {
    eyebrow: "Drag and drop",
    title: "Drop it in. Get the gist.",
    body: "Drag a PDF, text document, Markdown or code file into Chippy to start a summary. On Mac, you can drop a web link too. Your content opens in New Summary, ready for you to review.",
    sample: samples[3],
    illustration: "drop",
  },
  {
    eyebrow: "Share extension",
    title: "Summarise from apps and websites.",
    body: "Open Share in Safari, Files or another app and choose Chippy. The share extension turns shared web pages, PDFs and text into a summary, without leaving the app you’re using.",
    sample: samples[0],
    illustration: "share",
  },
  {
    eyebrow: "A card for every summary",
    title: "Every summary gets its own look.",
    body: "Each summary gets its own colour palette and preview image, with highlights and tags so you get the gist at a glance.",
    sample: samples[1],
  },
  {
    eyebrow: "Made to be shared",
    title: "Send it as a link or an image.",
    body: "Cards are ready for Messages and social — anyone can open the link, even without the app.",
    sample: samples[2],
  },
  {
    eyebrow: "You stay in control",
    title: "Your summaries, your rules.",
    body: "Links expire on your schedule, and you can make any summary private in one tap.",
    sample: samples[3],
  },
];

const steps = [
  { image: "share-material", title: "Add content", body: "Drag a document into Chippy, or choose Chippy in an app’s share sheet." },
  { image: "summarise-material", title: "Summarise", body: "Chippy reads it and pulls out the summary and highlights." },
  { image: "style-material", title: "Style", body: "The card picks a colour palette and preview image to match." },
  { image: "send-material", title: "Send", body: "Share the card as a link or an image, wherever you like." },
];

function MockCard({ card, className = "", eager = false, compact = false }: { card: SampleCard; className?: string; eager?: boolean; compact?: boolean }) {
  const [from, to] = card.colors;
  return (
    <div className={`summary-sample md-card overflow-hidden ${className}`}>
      <div className="relative aspect-[1200/630]" style={{ backgroundImage: `linear-gradient(135deg, ${from}, ${to})` }}>
        <Image src={`/images/marketing/${card.image}.webp`} alt="" fill sizes="(min-width: 1024px) 480px, (min-width: 640px) 400px, 90vw" className="object-cover" loading={eager ? "eager" : "lazy"} />
      </div>
      <div className="space-y-3 p-4">
        <div className="flex flex-wrap items-center gap-2">
          <span className="md-chip">
            {card.category}
          </span>
          {!compact && <span className="md-text-secondary truncate text-[11px]">{card.source}</span>}
        </div>
        <p className="text-sm font-semibold leading-snug">{card.title}</p>
        {!compact && <div className="space-y-1.5" aria-hidden>
          <div className="h-1.5 w-full rounded-full bg-slate-200" />
          <div className="h-1.5 w-4/5 rounded-full bg-slate-200" />
          <div className="h-1.5 w-3/5 rounded-full bg-slate-200" />
        </div>}
      </div>
    </div>
  );
}

function FeaturePreview({ feature }: { feature: Feature }) {
  if (feature.illustration) {
    const isDrop = feature.illustration === "drop";
    return (
      <div className={`feature-demo ${isDrop ? "feature-drop-demo" : ""}`}>
        <Image src={`/images/marketing/${isDrop ? "summarise-material" : "share-material"}.webp`} alt="" width={480} height={480} sizes="176px" className="h-44 w-44 object-contain" />
        <p className="mt-4 text-lg font-semibold">{isDrop ? "Drop to summarise" : "Share with Chippy"}</p>
        <p className="md-text-secondary mt-2 text-sm">{isDrop ? "PDFs, documents and more" : "From the app you’re already using"}</p>
        <div className="mt-5 flex flex-wrap justify-center gap-2">
          {(isDrop ? ["PDF", "Text", "Markdown"] : ["Web pages", "PDFs", "Text"]).map(label => <span key={label} className="md-chip">{label}</span>)}
        </div>
      </div>
    );
  }
  return <MockCard card={feature.sample} />;
}

function depth(value: number): CSSProperties {
  return { "--depth": value } as CSSProperties;
}

export default function Home() {
  return (
    <div className="landing-page">
      <div className="scroll-progress" aria-hidden />

      <header className="site-header md-appbar fixed inset-x-0 top-0 z-40">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <Link href="/" className="md-brand-link flex items-center gap-3 text-lg font-semibold">
            <ChippyLogo />
            Chippy
          </Link>
          <nav className="flex items-center gap-2" aria-label="Main navigation">
            <a href="#features" className="md-button md-button-text md-nav-secondary">Features</a>
            <a href="#how-it-works" className="md-button md-button-text md-nav-secondary">How it works</a>
            <Link href="/download" className="md-button md-button-filled">Download</Link>
          </nav>
        </div>
      </header>

      <main className="overflow-x-clip">
        <BrandIntro />
        {/* Hero */}
        <section id="overview" className="hero relative flex min-h-svh scroll-mt-20 items-center pt-20">
          <div className="relative mx-auto grid w-full max-w-6xl items-center gap-12 px-6 py-16 lg:grid-cols-[1.1fr_1fr]">
            <div className="hero-copy">
              <p className="md-eyebrow mb-5">Less reading. More understanding.</p>
              <h2 className="text-5xl font-normal leading-[1.08] tracking-tight sm:text-7xl">
                Read less.
                <br />
                <span className="md-text-primary">Share more.</span>
              </h2>
              <p className="md-text-secondary mt-6 max-w-xl text-lg leading-relaxed sm:text-xl">
                Chippy turns long articles, PDFs and notes into short, beautiful summary cards — then lets you share them as a link or an image.
              </p>
              <p className="md-text-secondary mt-4 max-w-xl leading-relaxed">Drag and drop your documents, or use the Chippy share extension to bring in content from apps and websites.</p>
              <div className="mt-10 flex flex-wrap items-center gap-4">
                <Link href="/download" className="md-button md-button-filled">
                  Download Chippy
                </Link>
                <a href="#how-it-works" className="md-button md-button-tonal">
                  See how it works ↓
                </a>
              </div>
            </div>

            <div aria-hidden className="hero-gallery hero-layer md-surface mx-auto grid w-full max-w-lg grid-cols-2 gap-4 p-4 sm:p-6" style={depth(0.2)}>
              <div className="col-span-2">
                <MockCard card={samples[0]} eager compact />
              </div>
              <div>
                <MockCard card={samples[1]} eager compact />
              </div>
              <div>
                <MockCard card={samples[2]} eager compact />
              </div>
            </div>
          </div>
        </section>

        {/* Features */}
        <section id="features" className="relative mx-auto max-w-6xl scroll-mt-20 px-6 py-24 sm:py-32">
          <div className="reveal max-w-2xl">
            <p className="md-eyebrow">Features</p>
            <h2 className="mt-3 text-4xl font-normal tracking-tight sm:text-5xl">Everything you read, distilled into a card.</h2>
          </div>

          <div className="mt-16 space-y-8 sm:space-y-12">
            {features.map((feature, index) => {
              const flipped = index % 2 === 1;
              return (
                <article key={feature.eyebrow} className="feature-row md-surface grid items-center gap-8 p-6 sm:p-10 lg:grid-cols-2 lg:gap-16">
                  <div className={`reveal ${flipped ? "lg:order-2" : ""}`}>
                    <p className="md-eyebrow">{feature.eyebrow}</p>
                    <h3 className="mt-3 text-3xl font-normal tracking-tight sm:text-4xl">{feature.title}</h3>
                    <p className="md-text-secondary mt-5 text-lg leading-relaxed">{feature.body}</p>
                  </div>

                  <div aria-hidden className="relative flex min-h-80 items-center justify-center">
                    <div className="parallax relative" style={depth(0.5)}>
                      <FeaturePreview feature={feature} />
                    </div>
                  </div>
                </article>
              );
            })}
          </div>
        </section>

        {/* How it works — pinned, scrolls sideways */}
        <section id="how-it-works" className="steps relative scroll-mt-20">
          <div className="steps-pin py-24">
            <div className="mx-auto w-full max-w-6xl px-6">
              <p className="md-eyebrow">How it works</p>
              <h2 className="mt-3 text-4xl font-normal tracking-tight sm:text-5xl">From long read to card in seconds.</h2>
            </div>
            <div className="steps-viewport mt-14">
              <ol className="steps-track flex w-max gap-6 px-6 lg:px-[max(1.5rem,calc((100cqw-72rem)/2+1.5rem))]">
                {steps.map((step, index) => (
                  <li key={step.title} className="md-card step-card flex w-[78vw] max-w-sm flex-none flex-col p-8">
                    <span className="md-text-primary text-sm font-semibold">0{index + 1}</span>
                    <Image src={`/images/marketing/${step.image}.webp`} alt="" width={480} height={480} sizes="160px" className="mt-6 h-40 w-40 object-contain" />
                    <h3 className="mt-6 text-2xl font-medium">{step.title}</h3>
                    <p className="md-text-secondary mt-3 leading-relaxed">{step.body}</p>
                  </li>
                ))}
              </ol>
            </div>
          </div>
        </section>

        {/* Call to action */}
        <section className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
          <div className="reveal-scale cta-surface relative overflow-hidden px-8 py-16 text-center sm:py-24">
            <h2 className="text-4xl font-normal tracking-tight sm:text-6xl">Start reading less.</h2>
            <p className="mx-auto mt-5 max-w-xl text-lg text-white/75">Chippy is available for iPhone, iPad and Mac.</p>
            <Link href="/download" className="md-button md-button-inverse mt-10">
              Download Chippy
            </Link>
          </div>
        </section>
      </main>

      <footer className="md-text-secondary mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-4 px-6 pb-12 text-sm">
        <span>© {new Date().getFullYear()} RxLab</span>
        <Link href="/download" className="md-button md-button-text">Get Chippy</Link>
      </footer>
    </div>
  );
}
