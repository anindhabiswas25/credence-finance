// A channel either delivers (returns a provider id), fails permanently (bad address, blocked bot, gone
// subscription: never retried), or fails transiently (5xx, 429, network: retried with back-off).

export class ChannelError extends Error {
  readonly permanent: boolean;
  /** A provider's own "retry after" (s), e.g. Telegram's 429 `parameters.retry_after`. */
  readonly retryAfterS?: number;
  constructor(message: string, permanent: boolean, retryAfterS?: number) {
    super(message);
    this.permanent = permanent;
    this.retryAfterS = retryAfterS;
  }
}

/** Map an HTTP status to a channel error. 408, 425, 429 and 5xx are transient. */
export function httpError(
  provider: string,
  status: number,
  body: string,
): ChannelError {
  const transient =
    status === 408 || status === 425 || status === 429 || status >= 500;
  return new ChannelError(
    `${provider} ${status}: ${body.slice(0, 300)}`,
    !transient,
    status === 429 ? retryAfterOf(body) : undefined,
  );
}

/** Telegram's 429 body carries `parameters.retry_after` (s); other providers' bodies give nothing here. */
export function retryAfterOf(body: string): number | undefined {
  try {
    const v = (JSON.parse(body) as { parameters?: { retry_after?: unknown } })
      .parameters?.retry_after;
    return typeof v === "number" && v > 0 ? v : undefined;
  } catch {
    return undefined;
  }
}

export type Fetch = typeof fetch;

/** fetch with a timeout; network errors are transient. */
export async function post(
  f: Fetch,
  url: string,
  init: RequestInit,
  provider: string,
  timeoutMs = 10_000,
): Promise<Response> {
  try {
    return await f(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (e) {
    throw new ChannelError(`${provider}: ${(e as Error).message}`, false);
  }
}
