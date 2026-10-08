/**
 * Weather data behind one interface, so the provider can change without touching tracking.
 * Providers normalize their answers into `LocationForecast`; the rest of the backend never sees
 * provider-specific JSON. Spec: `docs/weather.md`.
 *
 * Units: °C, mm, km/h. Codes are WMO weather interpretation codes (0 clear … 99 thunderstorm with hail).
 */

export interface WeatherPoint {
  lat: number;
  lng: number;
}

export interface DailyForecast {
  /** The location's local date, `YYYY-MM-DD`. */
  date: string;
  code: number;
  high: number | null;
  low: number | null;
  /** 0–100. */
  precipitationChance: number | null;
  precipitation: number | null;
  windMax: number | null;
  gustsMax: number | null;
  uvIndexMax: number | null;
  /** The location's wall-clock time, `YYYY-MM-DDTHH:mm`. */
  sunrise: string | null;
  sunset: string | null;
}

/** One 15-minute slot of the short-range forecast. */
export interface NowcastSlot {
  /** Slot start, Unix ms. */
  at: number;
  /** The location's wall-clock time, `YYYY-MM-DDTHH:mm`. */
  local: string;
  code: number;
  temperature: number | null;
  /** mm in the slot. */
  precipitation: number | null;
  gusts: number | null;
}

export interface CurrentWeather {
  at: number;
  code: number;
  temperature: number | null;
  precipitation: number | null;
  gusts: number | null;
}

export interface LocationForecast {
  timeZone: string | null;
  current: CurrentWeather | null;
  daily: DailyForecast[];
  /** The next few hours in 15-minute slots. */
  nowcast: NowcastSlot[];
}

export interface WeatherProvider {
  readonly id: string;
  /** One forecast per point, in the same order. */
  forecast(points: WeatherPoint[]): Promise<LocationForecast[]>;
}

/** The provider failed (network, quota, bad answer): try again later. */
export class WeatherProviderError extends Error {
  constructor(message: string, public readonly retryAfterMs?: number) {
    super(message);
    this.name = "WeatherProviderError";
  }
}

let override: WeatherProvider | undefined;

export function setWeatherProviderForTests(provider?: WeatherProvider): void {
  override = provider;
}

/** `WEATHER_PROVIDER` picks one: Open-Meteo by default (no key needed), `mock` for development. */
export async function getWeatherProvider(): Promise<WeatherProvider> {
  if (override) return override;
  if (process.env.WEATHER_PROVIDER?.trim() === "mock") {
    const { MockWeatherProvider } = await import("./mock");
    return new MockWeatherProvider();
  }
  const { OpenMeteoProvider } = await import("./open-meteo");
  return new OpenMeteoProvider();
}
