# The model test

Which speech model Murmur should use, decided on your own recordings: the open models that could
run on your own GPU (Qwen3-ASR, Parakeet v3, Whisper turbo, GigaAM, Voxtral Realtime) against
today's OpenAI and the best services (Soniox, ElevenLabs). Stage 3 of the backend plan.

You correct about 40 of your dictations once, every candidate transcribes them, and you vote blind
on which text you'd rather have typed. The report applies the plan's rules:

- A candidate **qualifies** when no clip comes back empty or with invented words, mixed Russian and
  English survive language detection (Auto), and it writes punctuation.
- Your **blind votes** rank the qualifiers. The Russian side (Russian and mixed clips) weighs 0.6,
  English 0.4. A candidate's points are the share of clips where its text was among your best, 0–100.
- **Your own model wins a tie** within 3 points. If no open model qualifies, the best service
  becomes the primary through the Murmur server, and your own model waits for training.

Everything lives in one work folder, `scripts/out/model_test/` (git ignores it). It holds your
voice and your texts: delete it when the test is over.

## The steps

**1. Get your recordings off the iPhone** (a development build of Murmur, unlocked, by cable or on
the same Wi-Fi; Settings › Keep recordings on, which it is by default):

```sh
deno run --allow-run --allow-read --allow-write --allow-env scripts/model_test/pull_phone.ts --device "<the iPhone's name>"
```

It copies Murmur's history and recordings out of the app (one read, nothing on the phone changes),
keeps every dictation that has a recording and a text, picks a first set of 40 (12 Russian, 8
mixed, 20 English, some 2–5 s) and deletes its copy of the history. Run it again later to add newer
dictations; what you did to a clip stays. A TestFlight or App Store build can't be read this way.

**2. Correct the texts** on the correction page:

```sh
deno run --allow-net=127.0.0.1 --allow-read --allow-write scripts/model_test/review.ts
```

Open http://127.0.0.1:8790. For each clip: listen, write exactly what you said the way you want it
typed (punctuation, capitals, numbers as figures, names spelled right), fix the language when the
guess is wrong (a Russian sentence with English words is "Russian with English words"), and press
⌘↵. Swap clips in and out of the test with "In the test"; "Private" means the clip is never sent
anywhere. The bar at the top counts against the targets. Only checked clips are scored.

The page starts from what the phone typed (today's OpenAI). Listen to every clip: a slip you don't
catch would count in OpenAI's favour.

**3. Run every candidate** on a rented GPU (an RTX 4090 or L4 with 24 GB, about $0.34–0.89 an hour;
the whole run takes one to two hours with setup). Put the service keys in a file outside the
repository, e.g. `~/murmur-model-test.env`:

```
OPENAI_API_KEY=…
SONIOX_API_KEY=…
ELEVENLABS_API_KEY=…
```

A separate OpenAI key with a low spending limit, deleted after the test, is safest. Then:

```sh
scripts/model_test/gpu_box.sh send root@<box> -p <port> -i ~/.ssh/<key> --keys ~/murmur-model-test.env
# on the box:
cd ~/murmur-model-test/repo && bash scripts/model_test/gpu_box.sh setup && bash scripts/model_test/gpu_box.sh run
# back on the Mac:
scripts/model_test/gpu_box.sh fetch root@<box> -p <port> -i ~/.ssh/<key>
```

`send` shows what goes (only the clips in the test, never the private ones) and asks first;
`--dry-run` builds and checks the bundle without connecting. The run starts each open model's server
in turn, so each has the whole GPU, then calls the services from the box, outside Russia. Stop or
terminate the pod when `fetch` has the results: it bills by the hour.

**4. Vote blind** on http://127.0.0.1:8790/vote (start `review.ts` again). For each clip, pick the
text you'd most want typed (several when equally good), mark any you couldn't use, ⏎ for the next.
The page never says who wrote what; identical texts are one option. "Reveal the result" shows the
ranking; `report.md` has every clip's differences.

## The candidates

`candidates.example.json` lists the plan's eight; `send` uses the work folder's `candidates.json`
when there is one, else that file. Kinds:

| Kind | Who | How it is asked |
|---|---|---|
| `openai` | OpenAI `gpt-transcribe` | the `transcribe` function's own request (`openAIForm`), with your languages as hints |
| `openai-compatible` | vLLM (Qwen3-ASR, Whisper turbo), `model_server.py` (Parakeet, GigaAM) | the same request to another server |
| `elevenlabs` | Scribe v3 | `POST /v1/speech-to-text`, numbers as digits, the language detected |
| `soniox` | `stt-rt-v6` | the live relay's own adapter over its WebSocket: the whole clip, then finalize |
| `vllm-realtime` | Voxtral Mini 4B Realtime | vLLM's `/v1/realtime` WebSocket |

No candidate is told a clip's language: they detect it, as the app's Auto does, with your languages
(`languageHints`) as hints where a service takes them. `keywords` takes your dictionary's terms,
as the app sends them (ElevenLabs charges 20% more with them). A `serve` block says how `run.ts
--serve` starts a candidate's own server and knows it is up; `own: true` marks your own models.

## The pieces

| File | What it is |
|---|---|
| `pull_phone.ts` | The phone pull; also `--from-dir` (a folder laid out like the app's) and `--from-clips` (`<group>-<name>.m4a` + `.txt`) |
| `review.ts`, `pages/` | The two pages, on 127.0.0.1 only; they answer no other site and write only `clips.json` and `votes.json` |
| `run.ts`, `adapters.ts`, `candidates.ts` | The runner: a warm-up per candidate, then every clip (`--repeat` for more timings), each answer saved as it comes, resumable; `--only`, `--skip`, `--rerun`, `--serve`, `--dry-run` |
| `report.ts` | Qualifying, word error rates, speed, price, votes, the ranking; `report.md` and `report.json` |
| `model_server.py` | Any onnx-asr model behind OpenAI's transcription request, on a CPU or a GPU; reports its own time in `x-processing-ms`; logs no audio and no text |
| `gpu_box.sh` | `send`, `setup`, `run`, `fetch` |
| `clips.ts` | The work folder's manifest, groups, the first test set, audio decoding |

Word error rate counts words changed, missing or added against your reference, in percent; case,
punctuation and ё/е don't count (`scripts/bench/metrics.ts`). Speed is request to text where the
runner runs, after the warm-up; "its own time" is what a candidate reports for itself.

## Tests

```sh
deno test --allow-net=127.0.0.1 --allow-read --allow-write --allow-run --allow-env scripts/model_test/
python3 -m unittest scripts/model_test/model_server_test.py      # needs numpy (and ffmpeg)
```

The adapters are tested against stand-ins that answer as each service's documentation says; no
real service was called. On a Mac, the whole chain was run on 16 spoken sample clips: a fake phone
folder with the app's own history table, the correction and vote pages driven in Chrome, and three
real open models on the CPU (Parakeet v3 int8: 85 ms a clip, GigaAM v3: 67 ms, Whisper base:
203 ms). The real services, vLLM's models and the GPU box itself are untested until there are keys
and a box.
