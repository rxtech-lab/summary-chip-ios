import { ImageResponse } from "next/og";
import { chippyIconDataUri } from "@/lib/brand";

export const size = { width: 256, height: 256 };
export const contentType = "image/png";

export default function Icon() {
  return new ImageResponse(
    <img src={chippyIconDataUri()} width={size.width} height={size.height} alt="" />,
    size,
  );
}
