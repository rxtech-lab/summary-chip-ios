import type { CSSProperties } from "react";
import Image from "next/image";

const frameCount = 9;
const sequenceStart = 20;
const sequenceEnd = 60;
const transitionStep = (sequenceEnd - sequenceStart) / (frameCount - 1);

export function featureTiming(index: number): CSSProperties {
  return { "--part-start": `${15 + index * 12}%`, "--part-end": `${32 + index * 12}%` } as CSSProperties;
}

/** Generated keyframes dissolve in sequence as the feature scrolls into view. */
export function FeatureArtwork({ id }: { id: string }) {
  return (
    <div className="feature-sequence" aria-hidden="true">
      {Array.from({ length: frameCount }, (_, index) => (
        <Image
          key={index}
          src={`/images/marketing/sequences/v2/${id}-${index + 1}.webp`}
          alt=""
          width={510}
          height={340}
          sizes="(min-width: 1024px) 560px, 90vw"
          className="feature-sequence-frame"
          style={{ "--frame-start": `${sequenceStart + Math.max(0, index - 1) * transitionStep}%`, "--frame-end": `${sequenceStart + index * transitionStep}%` } as CSSProperties}
        />
      ))}
    </div>
  );
}
