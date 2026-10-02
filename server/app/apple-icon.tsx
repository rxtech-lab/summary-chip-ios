import { ImageResponse } from "next/og";
import { chippyIconDataUri } from "@/lib/brand";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  return new ImageResponse(
    <img src={chippyIconDataUri({ rounded: false })} width={size.width} height={size.height} alt="" />,
    size,
  );
}
