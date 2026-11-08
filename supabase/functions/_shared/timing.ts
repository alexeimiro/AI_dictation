// Where a request's time goes, for the 200 replies and the log lines: each phase in whole
// milliseconds, and whether the request found its worker (an isolate) cold or warm.

/** This isolate: when it loaded this module, and how many requests it has begun since. */
const worker = { bootedAt: Date.now(), served: 0 };

/** The worker a request runs on. `region` and `executionId` are hosted env vars, null locally. */
export interface RequestStart {
  /** The isolate's first request, which paid for booting it and opening its connections. */
  cold: boolean;
  workerAgeMs: number;
  /** `SB_REGION`: where the function ran ("eu-central-1"). */
  region: string | null;
  /** `SB_EXECUTION_ID`: the isolate's id, so requests that share it shared a worker. */
  executionId: string | null;
}

/**
 * Counts a request against this isolate. Call it first in the handler, before the OPTIONS reply,
 * so a preflight that boots the worker counts as its first request.
 */
export function beginRequest(env: Pick<Deno.Env, "get"> = Deno.env): RequestStart {
  return {
    cold: worker.served++ === 0,
    workerAgeMs: Date.now() - worker.bootedAt,
    region: env.get("SB_REGION") ?? null,
    executionId: env.get("SB_EXECUTION_ID") ?? null,
  };
}

/**
 * The `timings` of a 200 reply, in whole milliseconds. Each phase is its own duration; `readyMs`
 * and `totalMs` count from the start of the handler. A phase that didn't run is left out.
 */
export interface ServerTimings {
  region: string | null;
  cold: boolean;
  workerAgeMs: number;
  executionId: string | null;
  authMs?: number;
  /** Reading the body; unless the gateway buffers it, this includes waiting for the rest of the upload. */
  bodyMs?: number;
  /** The rate-limit and quota RPCs. */
  preflightMs?: number;
  /** When OpenAI was called, from the start of the handler. */
  readyMs?: number;
  transcribeMs?: number;
  modelMs?: number;
  /** From the start of the handler to the reply. */
  totalMs: number;
}

/** In the order `toJSON` writes them. */
const PHASES = ["authMs", "bodyMs", "preflightMs", "readyMs", "transcribeMs", "modelMs"] as const;
type Phase = (typeof PHASES)[number];
/** The phases `mark` times; `ready` records the other one. */
type TimedPhase = Exclude<Phase, "readyMs">;

/** One request's phases, on a clock that starts with the handler. */
export class Phases {
  readonly #worker: RequestStart;
  readonly #now: () => number;
  readonly #started: number;
  readonly #elapsed: Partial<Record<Phase, number>> = {};

  constructor(worker: RequestStart, now: () => number = () => performance.now()) {
    this.#worker = worker;
    this.#now = now;
    this.#started = now();
  }

  /**
   * Times `work` until it settles, whether it succeeds or throws, and passes its result through.
   * It takes a PostgREST builder too, which sends nothing until it is awaited here. A phase
   * marked twice adds up (`transcribe` has two preflight RPCs).
   */
  async mark<T>(name: TimedPhase, work: PromiseLike<T>): Promise<T> {
    const started = this.#now();
    try {
      return await work;
    } finally {
      this.#elapsed[name] = (this.#elapsed[name] ?? 0) + this.#now() - started;
    }
  }

  /** Records `readyMs`: everything before the OpenAI call is overhead the user waits through. */
  ready(): void {
    this.#elapsed.readyMs = this.#now() - this.#started;
  }

  /** The timings so far. `totalMs` runs to this call: take one result for the reply and the log line. */
  toJSON(): ServerTimings {
    const { region, cold, workerAgeMs, executionId } = this.#worker;
    const phases: Partial<Record<Phase, number>> = {};
    for (const name of PHASES) {
      const ms = this.#elapsed[name];
      if (ms !== undefined) phases[name] = Math.round(ms);
    }
    const totalMs = Math.round(this.#now() - this.#started);
    return { region, cold, workerAgeMs, executionId, ...phases, totalMs };
  }
}
