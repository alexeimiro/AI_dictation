# The dictation server

One long-running Deno process that serves the four functions a dictation waits on: `dictate`,
`transcribe`, `cleanup` and `live`. It imports their handlers from `supabase/functions/_shared`,
so there is one copy of the logic and the Supabase functions keep working beside it.

It exists because a Supabase function worker starts cold, lives 150 s (400 s on a paid plan) and
stalls its sockets about once a minute. This process is always on.

Accounts, limits, purchases and sync stay in the Supabase project. The server only needs the
project's URL and secret key to check tokens and limits and to record usage.

## Run it

```sh
deno run --allow-net --allow-env server/main.ts          # needs the variables below
deno test --allow-env server/ supabase/functions/         # its tests, and the handlers'
```

Build the image from the repository root. The ignore file next to the Dockerfile lets only
`server/main.ts`, `supabase/functions/_shared` and `supabase/functions/live/spike.ts` into it.

```sh
docker build -f server/Dockerfile --build-arg MURMUR_VERSION=$(git rev-parse --short HEAD) -t murmur-server .
docker run --rm -p 8080:8080 --env-file <a file outside the repository> --stop-timeout 40 murmur-server
```

The image was not built on the Mac this was written on (Docker wasn't running). What was checked
instead: the same files in an empty folder, `deno cache` into an empty cache, and a start with
`--cached-only`.

## What it answers

| Request | Answer |
|---|---|
| `GET /healthz` | 200 `{ ok, host, version, uptimeMs, configured, draining }`; 503 while it drains for a stop. Asks the database nothing. |
| `/functions/v1/dictate`, `transcribe`, `cleanup`, `live` | What each function's own header comment says, as on Supabase |
| any of those with `EDGE_DISABLED=1` | 503 `{ "error": "edge_disabled" }` |
| any of those with no project configured | 503 `{ "error": "not_configured" }` |
| `/functions/v1/live?mode=…` with the bench key | The network test (`supabase/functions/live/spike.ts`) |

Every reply carries `x-murmur-host`. The timings in a reply name `MURMUR_REGION` as the region and
one id per boot as the execution id, so the app's timing log and `scripts/timings_report.ts` read
this server as they read a Supabase worker.

## Variables

| Variable | Meaning |
|---|---|
| `PORT` | Where it listens, plain HTTP. 8080. TLS is the platform's or a proxy's. |
| `MURMUR_HOST` | This home's name in the logs and in `dictation_costs.host`. `edge`. |
| `MURMUR_REGION` | Where it runs, for the timings. |
| `MURMUR_VERSION` | The build; the image sets it. |
| `DRAIN_MS` | How long a stop waits for requests, live sockets and the writes after a reply. 30000. |
| `EDGE_DISABLED=1` | The kill switch: every function answers 503 and the app uses Supabase. |
| `SUPABASE_URL`, `SUPABASE_SECRET_KEYS` | The project. `SUPABASE_SECRET_KEYS` is JSON: `{"default":"sb_secret_…"}`. |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `TRANSCRIBE_*`, `CLEANUP_*`, `TRANSLATE_*`, `DICTATE_*`, `LIVE_*`, `SONIOX_API_KEY` | As the functions read them (README at the repository root) |
| `LIVE_BENCH_KEY` | Opens the network test. With only this set, the server is a test target and nothing else. |

`LIVE_WALL_CLOCK_MS` is ignored here: no platform ends this process by its age, so a live socket
lasts `LIVE_MAX_SESSION_MS`.

Secrets go into the host's secret store or an env file outside the repository. Never into the image.

## Stopping and deploying

On SIGTERM or SIGINT the server reports unhealthy, refuses new live sockets with 503 (the app
uploads that dictation), lets the requests in hand finish, and waits up to `DRAIN_MS` for open live
sockets and for the usage and cost writes. Give the container at least that long before it is killed.

A deploy is: run the tests, build the image tagged with the commit, start the new one, check
`/healthz`, stop the old one. Roll back by starting the previous tag. The commands depend on the
host, which the network test chooses; they are added here then.

## When it is down

The app treats this server as a faster path, not the only one. A build that knows it sends a
request here first; a network failure or a 502, 503 or 504 sends the same request to the Supabase
functions and skips this server for a minute. So an outage here costs speed, not dictations.

## The network test

Which hosting networks can be reached from Russia changes, and is decided by measuring.

1. Start this server on each candidate with only `LIVE_BENCH_KEY`, `MURMUR_HOST` and `PORT` set,
   behind TLS on port 443.
2. From each connection that matters (home Wi-Fi, the Mac on the iPhone's hotspot per carrier, any
   VPN off):

   ```sh
   deno run --allow-net --allow-read --allow-write --allow-env scripts/bench/live_spike.ts \
     --url wss://<host>/functions/v1/live --bench <key> --no-token \
     --run handshake,echo:200,download:256,stream:60x10 --label <host>-<connection>
   ```

3. A network passes when 95% of the 60 s streams finish with no stall over 2 s and the 256 KB
   download completes, on every connection. Among those that pass, the lowest 95th-percentile round
   trip wins; the runner-up is kept as a spare.
