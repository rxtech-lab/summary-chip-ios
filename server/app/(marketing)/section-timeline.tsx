"use client";

import { useEffect, useRef, useState } from "react";

const sections = [
  ["intro", "Welcome"],
  ["overview", "Overview"],
  ["features", "Workspace"],
  ["podcast", "Podcasts"],
  ["paper", "Papers"],
  ["chip", "Chips"],
  ["trip", "Trips"],
  ["how-it-works", "How it works"],
  ["connect", "Connect your AI"],
  ["pricing", "Pricing"],
  ["get-chippy", "Get Chippy"],
] as const;

export function SectionTimeline() {
  const [active, setActive] = useState(0);
  const [scrolling, setScrolling] = useState(false);
  const [nearEdge, setNearEdge] = useState(false);
  const progress = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    let idleTimer: ReturnType<typeof setTimeout>;
    const onScroll = () => {
      setScrolling(true);
      clearTimeout(idleTimer);
      idleTimer = setTimeout(() => setScrolling(false), 1000);
    };
    const onPointerMove = (event: PointerEvent) => {
      setNearEdge(event.pointerType !== "touch" && window.innerWidth - event.clientX <= 96);
    };
    const onPointerLeave = () => setNearEdge(false);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("pointermove", onPointerMove, { passive: true });
    document.documentElement.addEventListener("pointerleave", onPointerLeave);
    window.addEventListener("blur", onPointerLeave);
    return () => {
      clearTimeout(idleTimer);
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("pointermove", onPointerMove);
      document.documentElement.removeEventListener("pointerleave", onPointerLeave);
      window.removeEventListener("blur", onPointerLeave);
    };
  }, []);

  useEffect(() => {
    const elements = sections.map(([id]) => document.getElementById(id));
    let frame = 0;
    const update = () => {
      frame = 0;
      // Read the untransformed chapter boundaries, including the long brand intro.
      const positions = elements.map(element => element
        ? element.getBoundingClientRect().top + window.scrollY : Infinity);
      const readingPosition = window.scrollY + Math.min(window.innerHeight * 0.3, 240);
      let index = 0;
      for (let i = 1; i < positions.length; i++) {
        if (positions[i] <= readingPosition) index = i;
      }
      if (window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2) {
        index = sections.length - 1;
      }
      const next = positions[index + 1];
      const fraction = next === undefined ? 0 : Math.max(0, Math.min(1,
        (readingPosition - positions[index]) / (next - positions[index])));
      progress.current?.style.setProperty("--section-progress", String((index + fraction) / (sections.length - 1)));
      setActive(index);
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
    const observer = new ResizeObserver(schedule);
    observer.observe(document.body);
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    update();
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
  }, []);

  return (
    <nav className="section-timeline" aria-label="Page sections" data-visible={scrolling || nearEdge}>
      <div className="section-timeline-track" aria-hidden="true"><span ref={progress} /></div>
      <ol>
        {sections.map(([id, label], index) => (
          <li key={id} data-complete={index < active}>
            <a href={`#${id}`} aria-label={label} aria-current={index === active ? "location" : undefined}
              onClick={event => {
                const target = document.getElementById(id);
                if (!target || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
                event.preventDefault();
                history.pushState(null, "", `#${id}`);
                target.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
                target.focus({ preventScroll: true });
              }}>
              <span className="section-timeline-dot" aria-hidden="true" />
              <span className="section-timeline-label" aria-hidden="true">{label}</span>
            </a>
          </li>
        ))}
      </ol>
    </nav>
  );
}
