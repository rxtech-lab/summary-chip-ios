import type { LocationForecast, WeatherPoint, WeatherProvider } from "./provider";

/**
 * Development stand-in: mild and mostly clear everywhere, for 16 days from today (UTC), with a
 * dry nowcast. Tests replace it with scripted answers.
 */
export class MockWeatherProvider implements WeatherProvider {
  readonly id = "mock";

  constructor(private readonly now: () => number = Date.now) {}

  async forecast(points: WeatherPoint[]): Promise<LocationForecast[]> {
    const now = this.now();
    const today = Date.parse(`${new Date(now).toISOString().slice(0, 10)}T00:00:00Z`);
    const slotStart = now - (now % (15 * 60_000));
    return points.map(() => ({
      // Unknown: the trip's own zone applies.
      timeZone: null,
      current: { at: now, code: 1, temperature: 21, precipitation: 0, gusts: 12 },
      daily: Array.from({ length: 16 }, (_, index) => {
        const date = new Date(today + index * 86_400_000).toISOString().slice(0, 10);
        return {
          date, code: index % 4 === 3 ? 3 : 1, high: 23, low: 15, precipitationChance: 10, precipitation: 0,
          windMax: 14, gustsMax: 25, uvIndexMax: 5, sunrise: `${date}T06:00`, sunset: `${date}T18:00`,
        };
      }),
      nowcast: Array.from({ length: 12 }, (_, index) => {
        const at = slotStart + index * 15 * 60_000;
        return { at, local: new Date(at).toISOString().slice(0, 16), code: 1, temperature: 21, precipitation: 0, gusts: 12 };
      }),
    }));
  }
}
