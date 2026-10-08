import { WeatherProviderError, type CurrentWeather, type DailyForecast, type LocationForecast, type NowcastSlot, type WeatherPoint, type WeatherProvider } from "./provider";

/**
 * Open-Meteo forecast API: `GET /v1/forecast` with comma-separated coordinates (one answer per
 * location, an array when there are several). With `timezone=auto` times are the location's
 * wall-clock (`YYYY-MM-DDTHH:mm`) and `utc_offset_seconds` converts them. Free use needs no key;
 * commercial plans use `OPEN_METEO_API_KEY` and the customer host.
 */

const DAILY = ["weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max", "precipitation_sum", "wind_speed_10m_max", "wind_gusts_10m_max", "uv_index_max", "sunrise", "sunset"];
const SHORT = ["weather_code", "temperature_2m", "precipitation", "wind_gusts_10m"];
/** Open-Meteo accepts up to 100 locations per request; stay well below the URL length limits. */
const BATCH = 50;

type Series = Record<string, (number | string | null)[] | undefined>;
interface OpenMeteoAnswer {
  utc_offset_seconds?: number;
  timezone?: string;
  current?: Record<string, number | string | null> | null;
  daily?: Series | null;
  minutely_15?: Series | null;
}

function num(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function str(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

/** A local wall-clock time and its UTC offset → Unix ms. */
function instant(local: string, offsetSeconds: number): number {
  return Date.parse(`${local}Z`) - offsetSeconds * 1000;
}

function parseDaily(daily: Series | null | undefined): DailyForecast[] {
  const dates = daily?.time ?? [];
  return dates.flatMap((date, index): DailyForecast[] => {
    const code = num(daily?.weather_code?.[index]);
    if (typeof date !== "string" || code === null) return [];
    return [{
      date,
      code,
      high: num(daily?.temperature_2m_max?.[index]),
      low: num(daily?.temperature_2m_min?.[index]),
      precipitationChance: num(daily?.precipitation_probability_max?.[index]),
      precipitation: num(daily?.precipitation_sum?.[index]),
      windMax: num(daily?.wind_speed_10m_max?.[index]),
      gustsMax: num(daily?.wind_gusts_10m_max?.[index]),
      uvIndexMax: num(daily?.uv_index_max?.[index]),
      sunrise: str(daily?.sunrise?.[index]),
      sunset: str(daily?.sunset?.[index]),
    }];
  });
}

function parseNowcast(series: Series | null | undefined, offset: number): NowcastSlot[] {
  const times = series?.time ?? [];
  return times.flatMap((local, index): NowcastSlot[] => {
    const code = num(series?.weather_code?.[index]);
    if (typeof local !== "string" || code === null) return [];
    return [{
      at: instant(local, offset),
      local,
      code,
      temperature: num(series?.temperature_2m?.[index]),
      precipitation: num(series?.precipitation?.[index]),
      gusts: num(series?.wind_gusts_10m?.[index]),
    }];
  });
}

function parseCurrent(current: OpenMeteoAnswer["current"], offset: number): CurrentWeather | null {
  const code = num(current?.weather_code);
  const local = str(current?.time);
  if (code === null || !local) return null;
  return {
    at: instant(local, offset),
    code,
    temperature: num(current?.temperature_2m),
    precipitation: num(current?.precipitation),
    gusts: num(current?.wind_gusts_10m),
  };
}

export function parseOpenMeteo(answer: OpenMeteoAnswer): LocationForecast {
  const offset = num(answer.utc_offset_seconds) ?? 0;
  return {
    timeZone: str(answer.timezone),
    current: parseCurrent(answer.current, offset),
    daily: parseDaily(answer.daily),
    nowcast: parseNowcast(answer.minutely_15, offset),
  };
}

export class OpenMeteoProvider implements WeatherProvider {
  readonly id = "open-meteo";
  private readonly base: string;
  private readonly key: string | undefined;
  private readonly fetcher: typeof fetch;

  constructor(options: { key?: string; fetch?: typeof fetch } = {}) {
    this.key = options.key ?? (process.env.OPEN_METEO_API_KEY?.trim() || undefined);
    this.base = this.key ? "https://customer-api.open-meteo.com" : "https://api.open-meteo.com";
    this.fetcher = options.fetch ?? ((input, init) => fetch(input, init));
  }

  async forecast(points: WeatherPoint[]): Promise<LocationForecast[]> {
    const out: LocationForecast[] = [];
    for (let offset = 0; offset < points.length; offset += BATCH) out.push(...await this.batch(points.slice(offset, offset + BATCH)));
    return out;
  }

  private async batch(points: WeatherPoint[]): Promise<LocationForecast[]> {
    if (!points.length) return [];
    const params = new URLSearchParams({
      latitude: points.map((point) => point.lat.toFixed(4)).join(","),
      longitude: points.map((point) => point.lng.toFixed(4)).join(","),
      daily: DAILY.join(","),
      current: SHORT.join(","),
      minutely_15: SHORT.join(","),
      past_minutely_15: "1",
      forecast_minutely_15: "12",
      forecast_days: "16",
      timezone: "auto",
    });
    if (this.key) params.set("apikey", this.key);
    let response: Response;
    try {
      response = await this.fetcher(`${this.base}/v1/forecast?${params}`, { signal: AbortSignal.timeout(15_000) });
    } catch {
      throw new WeatherProviderError("Open-Meteo could not be reached");
    }
    if (response.status === 429) {
      const retryAfter = Number(response.headers.get("retry-after"));
      throw new WeatherProviderError("Open-Meteo rate limit reached", Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 60 * 60_000);
    }
    if (!response.ok) throw new WeatherProviderError(`Open-Meteo answered ${response.status}`);
    const body = await response.json().catch(() => null) as OpenMeteoAnswer | OpenMeteoAnswer[] | null;
    const answers = Array.isArray(body) ? body : body ? [body] : [];
    if (answers.length !== points.length) throw new WeatherProviderError("Open-Meteo sent an unexpected answer");
    return answers.map(parseOpenMeteo);
  }
}
