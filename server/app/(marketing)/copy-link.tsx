"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";

/** A link shown as a pill; clicking copies it and shows a brief confirmation overlay. */
export function CopyLink({ value }: { value: string }) {
  const [status, setStatus] = useState<"idle" | "copied" | "failed">("idle");

  useEffect(() => {
    if (status === "idle") return;
    const timer = setTimeout(() => setStatus("idle"), 2000);
    return () => clearTimeout(timer);
  }, [status]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setStatus("copied");
    } catch {
      setStatus("failed");
    }
  }

  return (
    <>
      <button type="button" onClick={copy} className="copy-link" aria-label={`Copy ${value}`}>
        <code>{value}</code>
        {/* Both labels share one grid cell so the pill keeps the wider label's width and the link never rewraps. */}
        <span className="copy-link-action" aria-hidden data-copied={status === "copied"}>
          <span>Copy</span>
          <span>✓ Copied</span>
        </span>
      </button>
      {/* Portalled to <body>: the step cards animate with `translate`, which would otherwise pin this fixed overlay to the card. */}
      {status !== "idle" && createPortal(
        <p role="status" className="copy-toast">{status === "copied" ? "Link copied" : "Couldn’t copy. Select the link to copy it."}</p>,
        document.body,
      )}
    </>
  );
}
