import { chippyIconSvg } from "@/lib/brand";

/** The app icon inline, so it renders crisply at any size without an extra request. */
export function ChippyLogo({ className = "h-9 w-9" }: { className?: string }) {
  return <span aria-hidden className={`inline-block [&>svg]:h-full [&>svg]:w-full ${className}`} dangerouslySetInnerHTML={{ __html: chippyIconSvg() }} />;
}
