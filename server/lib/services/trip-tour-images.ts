import type { TripDocument } from "@/lib/contracts/trip";
import type { TourImageGroup } from "@/lib/contracts/tour";

/** Follow the same reachable component tree as the native JSON renderer, including disclosures. */
export function tourImageGroups(document: TripDocument): TourImageGroup[] {
  const groups: TourImageGroup[] = [];
  for (const view of document.views) {
    const seen = new Set<string>();
    const visit = (id: string, depth: number, title: string) => {
      if (depth >= 24 || seen.has(id)) return;
      seen.add(id);
      const element = view.spec.elements[id];
      if (!element) return;
      if (element.type === "Card" || element.type === "Disclosure") title = element.props.title || title;
      const photos = element.type === "Gallery" ? element.props.images
        : element.type === "Image" ? [{ url: element.props.url, caption: element.props.caption, credit: element.props.credit }] : [];
      if (photos.length) groups.push({ id: `${view.id}:${id}`, title, dayId: view.dayId, photos });
      for (const child of element.children ?? []) visit(child, depth + 1, title);
    };
    visit(view.spec.root, 0, view.title);
  }
  return groups;
}
