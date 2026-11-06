"use client";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import "./discover.css";
type Item = { id: string; slug: string; title: string; summary: string; kind: string; authorId: string; authorName: string | null };
const MIN_CARD_WIDTH = 300;
const GAP = 20;
const LOAD_AHEAD = 840;
/** Excerpt lengths are stable per item, so a card keeps its height (and lane) across reloads. */
const EXCERPT_LINES = [2, 4, 7, 3, 5];
function excerptLines(id: string) {
  let hash = 5381;
  for (const char of id) hash = (hash * 33 + char.charCodeAt(0)) >>> 0;
  return EXCERPT_LINES[hash % EXCERPT_LINES.length];
}
/** Places each item in the currently shortest lane; appending a page never moves earlier cards. */
function toLanes(items: Item[], count: number) {
  const lanes: Item[][] = Array.from({ length: count }, () => []);
  const heights = new Array<number>(count).fill(0);
  for (const item of items) {
    const lane = heights.indexOf(Math.min(...heights));
    lanes[lane].push(item);
    heights[lane] += 1 + (Math.min(3, Math.ceil(item.title.length / 24)) * 26 + excerptLines(item.id) * 22) / 300;
  }
  return lanes;
}
export default function DiscoverFeed() {
  const [items, setItems] = useState<Item[]>([]);
  const [next, setNext] = useState<number | null>(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [columns, setColumns] = useState(1);
  const [author, setAuthor] = useState<string | null>(null);
  const grid = useRef<HTMLDivElement>(null);
  const locked = useRef(false);
  const restored = useRef(false);
  const target = useRef(0);
  const nextOffset = useRef<number | null>(0);
  const load = useCallback(async (offset: number, refresh = false) => {
    if (locked.current) return;
    locked.current = true; setBusy(true); setError("");
    try {
      const params = new URLSearchParams(window.location.search);
      params.set("offset", String(offset)); params.delete("position");
      const response = await fetch(`/api/v1/marketplace?${params}`, { cache: "no-store" });
      if (!response.ok) throw new Error("Could not load Discover. Please try again.");
      const page = await response.json() as { items: Item[]; nextOffset: number | null };
      setItems(old => refresh ? page.items : [...old, ...page.items.filter(item => !old.some(existing => existing.id === item.id))]);
      setNext(page.nextOffset);
      nextOffset.current = page.nextOffset;
    } catch (e) { setError(e instanceof Error ? e.message : "Could not load Discover."); }
    finally { locked.current = false; setBusy(false); }
  }, []);
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    target.current = Math.max(0, Math.min(100000, Number(params.get("position")) || 0));
    const initialFrame = requestAnimationFrame(() => { setAuthor(params.get("author")); void load(0, true); });
    const measure = () => {
      const width = grid.current?.clientWidth ?? window.innerWidth;
      setColumns(Math.max(1, Math.floor((width + GAP) / (MIN_CARD_WIDTH + GAP))));
    };
    const scrolled = () => {
      if (!restored.current) return;
      const url = new URL(window.location.href);
      url.searchParams.set("position", String(Math.round(window.scrollY)));
      window.history.replaceState(window.history.state, "", url);
      const bottom = grid.current?.getBoundingClientRect().bottom ?? 0;
      if (bottom - window.innerHeight <= LOAD_AHEAD && nextOffset.current !== null) void load(nextOffset.current);
    };
    const observer = new ResizeObserver(measure);
    if (grid.current) observer.observe(grid.current);
    window.addEventListener("scroll", scrolled, { passive: true });
    return () => { cancelAnimationFrame(initialFrame); observer.disconnect(); window.removeEventListener("scroll", scrolled); };
  }, [load]);
  useEffect(() => {
    if (busy || error || !items.length) return;
    const frame = requestAnimationFrame(() => {
      const bottom = grid.current?.getBoundingClientRect().bottom ?? 0;
      if (!restored.current) {
        // `bottom` is relative to the viewport; compare it to where the saved position's viewport ends.
        if (bottom + window.scrollY < target.current + window.innerHeight && next !== null) { void load(next); return; }
        restored.current = true; window.scrollTo(0, target.current);
      } else if (bottom - window.innerHeight <= LOAD_AHEAD && next !== null) void load(next);
    });
    return () => cancelAnimationFrame(frame);
  }, [items, columns, next, busy, error, load]);
  const lanes = useMemo(() => toLanes(items, columns), [items, columns]);
  return <main className="discover-shell">
    <header className="discover-header"><div><h1>Discover</h1><p>Discover something worth keeping.</p></div>
      <button disabled={busy} onClick={() => { target.current = window.scrollY; restored.current = false; void load(0, true); }}>Refresh</button>
    </header>
    {author && <a href="/discover">All authors</a>}
    {error && <div role="alert">{error} <button onClick={() => void load(next ?? 0)}>Retry</button></div>}
    {!busy && !error && !items.length && <p>No published content yet.</p>}
    <div ref={grid} className="discover-grid">
      {lanes.map((lane, index) => <div key={index} className="discover-lane">
        {lane.map(item => <article key={item.id} className="discover-card">
          <Link className="discover-content" href={`/${["podcast", "audiobook"].includes(item.kind) ? "podcast" : "s"}/${encodeURIComponent(item.slug)}`}>
            {/* Public OG endpoint supplies the same artwork used by feed cards. */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={`/s/${encodeURIComponent(item.slug)}/og.png`} alt="" loading="lazy" onError={event => { event.currentTarget.style.visibility = "hidden"; }} />
            <div className="discover-copy"><small>{item.kind.replaceAll("_", " ")}</small><h2>{item.title}</h2><p style={{ WebkitLineClamp: excerptLines(item.id) }}>{item.summary}</p></div>
          </Link>
          <a className="discover-author" href={`/discover?author=${encodeURIComponent(item.authorId)}`}>{item.authorName || "Chippy author"} <span>›</span></a>
        </article>)}
      </div>)}
    </div>
    {busy && <div className="discover-status" role="status">Loading Discover…</div>}
  </main>;
}
