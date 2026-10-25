import Link from "next/link";
import { chippyAssemblySvg } from "@/lib/brand";

export function BrandIntro() {
  return (
    <section id="intro" tabIndex={-1} className="brand-intro" aria-labelledby="intro-title">
      <div className="intro-pin">
        <div className="intro-scene">
          <div className="intro-art" aria-hidden dangerouslySetInnerHTML={{ __html: chippyAssemblySvg() }} />
          <h1 id="intro-title" className="intro-title">Chippy</h1>
          <p className="intro-tagline">Your AI <span>workspace.</span></p>
          <div className="intro-cue mt-8 flex flex-wrap items-center justify-center gap-3">
            <Link href="/download" className="md-button md-button-filled">Download Chippy</Link>
            <a href="#overview" className="md-button md-button-text">Explore Chippy <span aria-hidden>↓</span></a>
          </div>
        </div>
      </div>
    </section>
  );
}
