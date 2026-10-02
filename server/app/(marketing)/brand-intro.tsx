import { chippyAssemblySvg } from "@/lib/brand";

export function BrandIntro() {
  return (
    <section className="brand-intro" aria-labelledby="intro-title">
      <div className="intro-pin">
        <div className="intro-scene">
          <div className="intro-art" aria-hidden dangerouslySetInnerHTML={{ __html: chippyAssemblySvg() }} />
          <h1 id="intro-title" className="intro-title">Chippy</h1>
          <p className="intro-tagline">Read less. <span>Share more.</span></p>
          <div className="intro-cue">
            <p className="intro-scroll-hint">Scroll to bring it together</p>
            <a href="#overview" className="md-button md-button-text mt-2">Explore Chippy <span aria-hidden>↓</span></a>
          </div>
        </div>
      </div>
    </section>
  );
}
