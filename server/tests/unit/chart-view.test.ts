import { expect, it } from "vitest";
import { viewElementSchema } from "@/lib/contracts/trip-view";

it.each(["LineChart", "BarChart", "AreaChart"])("accepts signed values for %s", type => {
  expect(viewElementSchema.safeParse({ type, props: { items: [{ label: "Loss", value: -4 }] } }).success).toBe(true);
});
it("requires positive pie totals and rejects negative slices", () => {
  for (const value of [0, -1]) {
    expect(viewElementSchema.safeParse({ type: "PieChart", props: { items: [{ label: "A", value }] } }).success).toBe(false);
  }
  expect(viewElementSchema.safeParse({ type: "PieChart", props: { items: [{ label: "A", value: 3 }] } }).success).toBe(true);
});
it("requires numeric scatter coordinates", () => {
  expect(viewElementSchema.safeParse({ type: "ScatterChart", props: { items: [{ label: "A", x: -2, y: 4 }] } }).success).toBe(true);
  expect(viewElementSchema.safeParse({ type: "ScatterChart", props: { items: [{ label: "A", value: 4 }] } }).success).toBe(false);
});
