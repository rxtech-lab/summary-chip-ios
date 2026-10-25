import type { CSSProperties } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";
import { ChippyLogo } from "./chippy-logo";
import { BrandIntro } from "./brand-intro";
import { SectionTimeline } from "./section-timeline";
import { CopyLink } from "./copy-link";
import { FeatureArtwork, featureTiming } from "./feature-artwork";
import "./landing.css";

export const metadata: Metadata = {
  title: { absolute: "Chippy — Your AI workspace" },
  description: "Chippy is your AI workspace. Save ideas as shareable chips, turn your reading into podcasts, write and review LaTeX papers, and keep trip itineraries, maps and expenses together in Chippy.",
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
];

type Feature = {
  id: string;
  eyebrow: string;
  title: string;
  summary: string;
  body: string;
  details: string[];
};

const features: Feature[] = [
  {
    id: "podcast",
    eyebrow: "Podcasts",
    title: "Your reading, ready to listen.",
    summary: "Turn what you read into conversations you can listen to or share as video.",
    body: "Turn the chips you saved during the day into a conversational podcast. Choose your sources, language and speaker names, then listen with timed captions and artwork. Keep the audio or export a captioned video to take your ideas further.",
    details: ["Choose your chips", "Timed captions", "Audio & video export"],
  },
  {
    id: "paper",
    eyebrow: "Papers",
    title: "Give your next paper a home.",
    summary: "Write, review and organise your research in one place.",
    body: "Write LaTeX with a live preview, or settle into a reader that adapts to your screen. Add review comments, revisit saved versions and translate your work. Export a PDF or Word document when it’s ready to share.",
    details: ["LaTeX editor & preview", "Reviews & versions", "PDF & Word export"],
  },
  {
    id: "chip",
    eyebrow: "Chips",
    title: "Big ideas. Beautiful little cards.",
    summary: "Keep the best parts of articles, videos and notes on illustrated cards.",
    body: "Turn articles, PDFs, videos and notes into illustrated summary cards with key points and tags. Drop a document into Chippy or use the share extension from another app. Send a card as an image or a link, with privacy and link expiry in your control.",
    details: ["Summaries & key points", "Drag, drop or share", "Shareable cards"],
  },
  {
    id: "trip",
    eyebrow: "Trips",
    title: "Bring the whole journey together.",
    summary: "Bring itineraries, maps, bookings and expenses into one travel plan.",
    body: "Keep your day-by-day itinerary, places, transport, hotels and expenses in one trip diary. Follow your route on the map as you read, explore the details of each stop and keep your plans close from the first departure to the journey home.",
    details: ["Daily itineraries", "Maps & places", "Bookings & expenses"],
  },
];

const steps = [
  { image: "share-material", title: "Bring anything in", body: "Drop in an article, PDF, video, booking or note, use the share sheet, or let your AI assistant add it.", tags: ["Share sheet", "Drag & drop", "MCP"] },
  { image: "summarise-material", title: "Chippy understands it", body: "It reads the source, pulls out the key points and remembers where everything came from.", tags: ["Key points", "Source language", "Search"] },
  { image: "style-material", title: "Make it into something", body: "Keep it as a chip, gather chips into a podcast, cite it in a paper or add the place to a trip.", tags: ["Chip", "Podcast", "Paper", "Trip"] },
  { image: "send-material", title: "Share it your way", body: "Send a card, a captioned video, a PDF or a whole itinerary, synced across iPhone, iPad and Mac.", tags: ["Link or image", "Video", "PDF & Word"] },
];

const agentResults = [
  { tool: "create_trip", label: "Kyoto weekend · 2 days, 9 places" },
  { tool: "add_summary", label: "3 chips saved from your research" },
  { tool: "create_podcast", label: "“Slow mornings in Kyoto” · 12 min" },
];

const setupSteps = [
  <>Copy the Chippy MCP server link.<CopyLink value="https://summary.rxlab.app/api/mcp" /></>,
  <>Add it as a remote MCP server or <strong>custom connector</strong> in your assistant’s settings.</>,
  <>Sign in to Chippy when your assistant asks, then ask it to work with your library.</>,
];

const waveform = [40, 72, 55, 90, 64, 38, 80, 100, 58, 44, 76, 62, 92, 50, 34, 68, 84, 46];

const assistants = ["Grok bot", "GPT dots", "Meta Muse", "Google Spark", "Claude Duet"];

function depth(value: number): CSSProperties {
  return { "--depth": value } as CSSProperties;
}

function MockCard({ card, eager = false }: { card: SampleCard; eager?: boolean }) {
  const [from, to] = card.colors;
  return (
    <div className="summary-sample md-card overflow-hidden">
      <div className="relative aspect-[1200/630]" style={{ backgroundImage: `linear-gradient(135deg, ${from}, ${to})` }}>
        <Image src={`/images/marketing/${card.image}.webp`} alt="" fill sizes="(min-width: 1024px) 320px, 70vw" className="object-cover" loading={eager ? "eager" : "lazy"} />
      </div>
      <div className="space-y-2.5 p-4">
        <div className="flex items-center gap-2">
          <span className="md-chip">{card.category}</span>
          <span className="md-text-secondary truncate text-[11px]">{card.source}</span>
        </div>
        <p className="text-sm font-semibold leading-snug">{card.title}</p>
        <div className="space-y-1.5">
          <div className="h-1.5 w-full rounded-full bg-slate-200" />
          <div className="h-1.5 w-3/5 rounded-full bg-slate-200" />
        </div>
      </div>
    </div>
  );
}

/** Small product moments layered over each feature illustration. */
function FeatureMoment({ id }: { id: string }) {
  switch (id) {
    case "podcast":
      return (
        <div className="moment">
          <div className="moment-waveform">{waveform.map((height, i) => <span key={i} style={{ "--h": `${height}%`, "--part-start": `${40 + i * 2}%`, "--part-end": `${44 + i * 2}%` } as CSSProperties} />)}</div>
          <p className="moment-caption"><b>Ava</b> So the white roofs actually cool the whole street?</p>
        </div>
      );
    case "paper":
      return (
        <div className="moment">
          <p className="moment-label">Review · Section 2</p>
          <p className="moment-quote">“the sample was drawn from…”</p>
          <p className="moment-caption">Clarify how participants were recruited.</p>
        </div>
      );
    case "chip":
      return (
        <div className="moment">
          <p className="moment-label">Key points</p>
          <ul className="moment-list">
            <li style={featureTiming(1)}>Light roofs reflect up to 80% of sunlight</li>
            <li style={featureTiming(2)}>Streets can be 2 °C cooler</li>
          </ul>
        </div>
      );
    default:
      return (
        <div className="moment">
          <p className="moment-label">Day 2 · Kyoto</p>
          <ol className="moment-route">
            <li style={featureTiming(0)}><span>08:30</span> Fushimi Inari</li>
            <li style={featureTiming(1)}><span>12:10</span> Nishiki Market</li>
            <li style={featureTiming(2)}><span>15:40</span> Shinkansen to Tokyo</li>
          </ol>
        </div>
      );
  }
}

export default function Home() {
  return (
    <div className="landing-page">
      <SectionTimeline />

      <header className="site-header md-appbar fixed inset-x-0 top-0 z-40">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <Link href="/" className="md-brand-link flex items-center gap-3 text-lg font-semibold">
            <ChippyLogo />
            Chippy
          </Link>
          <nav className="flex items-center gap-2" aria-label="Main navigation">
            <a href="#features" className="md-button md-button-text md-nav-secondary">Features</a>
            <a href="#connect" className="md-button md-button-text md-nav-secondary">Connect your AI</a>
            <Link href="/download" className="md-button md-button-filled">Download</Link>
          </nav>
        </div>
      </header>

      <main className="overflow-x-clip">
        <BrandIntro />

        {/* Hero */}
        <section tabIndex={-1} id="overview" className="hero relative flex min-h-svh scroll-mt-20 items-center pt-20">
          <div className="relative mx-auto grid w-full max-w-6xl grid-cols-[minmax(0,1fr)] items-center gap-16 px-6 py-16 lg:grid-cols-[1.05fr_1fr]">
            <div className="hero-copy">
              <p className="hero-badge"><span aria-hidden />Now with podcasts, papers &amp; trips</p>
              <h2 className="mt-6 text-5xl font-normal leading-[1.05] tracking-tight sm:text-7xl">
                Your ideas.
                <br />
                <span className="md-text-primary">Connected.</span>
              </h2>
              <p className="md-text-secondary mt-6 max-w-xl text-lg leading-relaxed sm:text-xl">
                Save what matters as a chip. Listen to it as a podcast. Write your next paper. Plan your next trip. Chippy brings your ideas and journeys into one library.
              </p>
              <div className="mt-10 flex flex-wrap items-center gap-4">
                <Link href="/download" className="md-button md-button-filled">Download Chippy</Link>
                <a href="#features" className="md-button md-button-tonal">Explore the workspace <span aria-hidden>↓</span></a>
              </div>
              <p className="md-text-secondary mt-8 text-sm">Available on iPhone, iPad and Mac · Works with your AI through MCP</p>
            </div>

            <div aria-hidden className="hero-collage">
              <div className="collage-piece collage-chip hero-layer" style={depth(0.12)}>
                <MockCard card={samples[0]} eager />
              </div>
              <div className="collage-piece collage-player md-card hero-layer" style={depth(0.32)}>
                <Image src="/images/marketing/feature-podcast-transparent.webp" alt="" width={96} height={96} className="collage-player-art" loading="eager" />
                <div className="min-w-0 flex-1">
                  <p className="text-[11px] font-semibold uppercase tracking-wider md-text-primary">Today’s podcast</p>
                  <p className="truncate text-sm font-semibold">Cooler cities, better sleep</p>
                  <div className="collage-progress"><span /></div>
                </div>
                <span className="collage-play">▶</span>
              </div>
              <div className="collage-piece collage-trip md-card hero-layer" style={depth(0.5)}>
                <p className="text-[11px] font-semibold uppercase tracking-wider md-text-primary">Day 1 · Kyoto</p>
                <ol className="mt-3 space-y-2 text-sm">
                  <li><span>09:00</span> Kiyomizu-dera</li>
                  <li><span>13:30</span> Gion lunch</li>
                  <li><span>18:00</span> Ryokan check-in</li>
                </ol>
              </div>
            </div>
          </div>
        </section>

        {/* Workspace overview: a bento of the four spaces, each linking to its chapter. */}
        <section tabIndex={-1} id="features" className="workspace-section scroll-mt-20 px-6">
          <div className="mx-auto max-w-6xl">
            <div className="chapter-head">
              <p className="md-eyebrow">One workspace. More possibilities.</p>
              <h2 className="mt-3 max-w-3xl text-4xl tracking-tight sm:text-5xl">Everything you’re curious about, together.</h2>
              <p className="md-text-secondary mt-5 max-w-2xl text-lg leading-relaxed">From a useful idea to your next adventure. Give your podcasts, papers, summary chips and trips a place to grow.</p>
            </div>
            <div className="bento mt-14">
              {features.map((feature, index) => (
                <a key={feature.id} href={`#${feature.id}`} className={`bento-tile bento-${feature.id}`}>
                  <div className="bento-copy">
                    <span className="bento-index">0{index + 1}</span>
                    <h3 className="mt-6 text-2xl font-medium sm:text-3xl">{feature.eyebrow}</h3>
                    <p className="mt-3 max-w-sm leading-relaxed opacity-80">{feature.summary}</p>
                    <span className="bento-link">Learn more <span aria-hidden>↓</span></span>
                  </div>
                  <Image src={`/images/marketing/feature-${feature.id}-transparent.webp`} alt="" width={1200} height={800} sizes="(min-width: 1024px) 420px, 60vw" className="bento-art" />
                </a>
              ))}
            </div>
          </div>
        </section>

        {/* Feature chapters */}
        <section aria-label="Features in detail" className="feature-chapters mx-auto max-w-6xl px-6">
          {features.map((feature, index) => (
            <article tabIndex={-1} id={feature.id} key={feature.id} className={`feature-row feature-${feature.id} scroll-mt-24`}>
              <div className="feature-copy reveal">
                <p className="feature-index"><span>0{index + 1}</span> / 04 · {feature.eyebrow}</p>
                <h3 className="mt-5 text-4xl font-normal tracking-tight sm:text-5xl">{feature.title}</h3>
                <p className="md-text-secondary mt-6 text-lg leading-relaxed">{feature.body}</p>
                <ul className="feature-details mt-8" aria-label={`${feature.eyebrow} highlights`}>
                  {feature.details.map(detail => <li key={detail}>{detail}</li>)}
                </ul>
              </div>

              <div aria-hidden className="feature-stage">
                <div className="feature-art">
                  {feature.id === "podcast" ? (
                    <Image src={`/images/marketing/feature-${feature.id}-transparent.webp`} alt="" width={1200} height={800} sizes="(min-width: 1024px) 560px, 90vw" className="h-auto w-full object-cover" />
                  ) : <FeatureArtwork id={feature.id} />}
                </div>
                <div className="feature-moment parallax" style={depth(0.6)}>
                  <FeatureMoment id={feature.id} />
                </div>
              </div>
            </article>
          ))}
        </section>

        {/* How it works: one flow from a source to anything you make with it. */}
        <section tabIndex={-1} id="how-it-works" className="flow-section scroll-mt-20 px-6">
          <div className="flow-heading chapter-head mx-auto max-w-2xl text-center">
            <h2 className="text-4xl tracking-tight sm:text-5xl">How it works</h2>
            <p className="md-text-secondary mt-5 text-lg leading-relaxed">Bring an idea. Make it a chip, podcast, paper or trip. Share what you create.</p>
          </div>
          <ol className="chip-steps mx-auto mt-20 max-w-6xl">
            {steps.map((step, index) => (
              <li key={step.title} className="chip-step">
                {index < steps.length - 1 && (
                  <svg className="chip-flow-line" viewBox="0 0 1000 500" preserveAspectRatio="none" aria-hidden="true">
                    <path className="flow-path-track" d={index % 2 === 0 ? "M220 0 C650 0 350 500 780 500" : "M780 0 C350 0 650 500 220 500"} />
                    <path className="flow-path-progress" pathLength="1" d={index % 2 === 0 ? "M220 0 C650 0 350 500 780 500" : "M780 0 C350 0 650 500 220 500"} />
                  </svg>
                )}
                <div className="chip-step-card">
                  <div className="chip-step-art">
                    <Image src={`/images/marketing/${step.image}.webp`} alt="" width={480} height={480} sizes="(min-width: 640px) 240px, 160px" />
                  </div>
                  <span className="chip-step-number">{index + 1}</span>
                  <div className="chip-step-copy">
                    <h3 className="mt-5 text-xl font-medium">{step.title}</h3>
                    <p className="md-text-secondary mt-2 leading-relaxed">{step.body}</p>
                    <ul className="mt-4 flex flex-wrap gap-1.5" aria-label={`${step.title} examples`}>
                      {step.tags.map(tag => <li key={tag} className="md-chip">{tag}</li>)}
                    </ul>
                  </div>
                </div>
              </li>
            ))}
          </ol>
        </section>

        {/* MCP */}
        <section tabIndex={-1} id="connect" className="scroll-mt-20 px-6">
          <div className="mcp-section mx-auto max-w-6xl">
            <div className="grid grid-cols-[minmax(0,1fr)] items-center gap-14 lg:grid-cols-[1fr_1.05fr]">
              <div className="chapter-head">
                <p className="mcp-eyebrow">Introducing the Chippy MCP server</p>
                <h2 className="mt-4 text-4xl tracking-tight sm:text-5xl">Your favourite AI.<br />Your whole workspace.</h2>
                <p className="mt-6 text-lg leading-relaxed text-white/75">Ask your assistant to plan a trip, manage a paper, write a summary, create a podcast video or build a small interactive chip. The results land in Chippy, ready to open, review and share on iPhone, iPad and Mac.</p>
                <ul className="mt-8 flex flex-wrap gap-2" aria-label="AI assistants">
                  {assistants.map(name => <li key={name} className="mcp-pill">{name}</li>)}
                </ul>
              </div>

              <div className="mcp-conversation" aria-label="Example conversation">
                <p className="mcp-bubble">Plan a weekend in Kyoto, save my research and turn the highlights into a podcast.</p>
                <div className="mcp-reply">
                  <p className="flex items-center gap-2 text-sm font-semibold"><ChippyLogo className="h-6 w-6" /> Working in your Chippy library</p>
                  <ul className="mt-4 space-y-2.5">
                    {agentResults.map((result, index) => (
                      <li key={result.tool} className="mcp-result" style={{ "--i": index } as CSSProperties}>
                        <span className="mcp-check" aria-hidden>✓</span>
                        <span className="min-w-0">
                          <code>{result.tool}</code>
                          <span className="block">{result.label}</span>
                        </span>
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            </div>

            <div className="mcp-setup">
              <h3 className="text-lg font-medium">Connect in three steps</h3>
              <ol className="mt-6 grid gap-4 md:grid-cols-3">
                {setupSteps.map((step, index) => (
                  <li key={index} className="mcp-setup-step">
                    <span className="mcp-setup-number">{index + 1}</span>
                    <div className="mt-4 leading-relaxed text-white/80">{step}</div>
                  </li>
                ))}
              </ol>
              <p className="mt-6 text-sm leading-relaxed text-white/55">Works with assistants that support remote MCP servers with OAuth sign-in. Availability and setup depend on your assistant.</p>
            </div>
          </div>
        </section>

        {/* Call to action */}
        <section id="get-chippy" tabIndex={-1} className="scroll-mt-20 cta-section mx-auto max-w-6xl px-6">
          <div className="reveal-scale cta-surface relative overflow-hidden px-8 text-center">
            <Image src="/images/marketing/cta-background.webp" alt="" fill sizes="(min-width: 1200px) 1152px, 100vw" className="cta-background" />
            <div aria-hidden className="cta-float cta-float-left parallax" style={depth(0.8)}>
              <Image src="/images/marketing/cta-ideas.webp" alt="" width={800} height={800} sizes="(min-width: 900px) 280px, 170px" />
            </div>
            <div aria-hidden className="cta-float cta-float-right parallax" style={depth(-0.6)}>
              <Image src="/images/marketing/cta-journey.webp" alt="" width={800} height={800} sizes="(min-width: 900px) 280px, 170px" />
            </div>
            <div className="cta-content relative">
              <ChippyLogo className="mx-auto h-16 w-16" />
              <h2 className="mt-8 text-4xl font-normal tracking-tight sm:text-6xl">Make room for your next idea.</h2>
              <p className="mx-auto mt-5 max-w-xl text-lg text-white/75">Chippy is available for iPhone, iPad and Mac.</p>
              <Link href="/download" className="md-button md-button-inverse mt-10">Download Chippy</Link>
            </div>
          </div>
        </section>
      </main>

      <footer className="site-footer mx-auto max-w-6xl px-6 pb-12">
        <div className="flex flex-wrap items-center justify-between gap-6 border-t pt-8">
          <Link href="/" className="md-brand-link flex items-center gap-2 font-semibold"><ChippyLogo className="h-7 w-7" /> Chippy</Link>
          <nav className="md-text-secondary flex flex-wrap gap-6 text-sm" aria-label="Footer">
            <a href="#features">Features</a>
            <a href="#how-it-works">How it works</a>
            <a href="#connect">Connect your AI</a>
            <Link href="/download">Download</Link>
          </nav>
          <span className="md-text-secondary text-sm">© {new Date().getFullYear()} RxLab</span>
        </div>
      </footer>
    </div>
  );
}
