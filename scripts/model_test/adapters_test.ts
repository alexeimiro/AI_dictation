// Each adapter against a stand-in that answers as the real service's documentation says. Nothing
// here reaches a real service: the stand-ins listen on 127.0.0.1.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { type ClipAudio, CandidateError, transcriberFor, withoutLanguageTag } from "./adapters.ts";
import type { Candidate } from "./candidates.ts";

const PCM = new Uint8Array(16000); // 0.5 s of silence
const M4A = new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32]); // an m4a's first bytes; nobody decodes it here

function clip(path = "audio/x.m4a"): ClipAudio {
  return { id: "x", path, bytes: M4A, pcm: () => Promise.resolve(PCM) };
}

const context = (env: Record<string, string> = {}) => ({
  languageHints: ["ru", "en"],
  keywords: ["Murmur", "Okafor"],
  env: (name: string) => env[name],
});

async function withServer(handler: (request: Request) => Response | Promise<Response>, run: (url: string) => Promise<void>) {
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, handler);
  try {
    await run(`http://127.0.0.1:${server.addr.port}`);
  } finally {
    await server.shutdown();
  }
}

Deno.test("openai: the transcribe function's own form, the key, the text, the languages and OpenAI's own time", async () => {
  let form: FormData | null = null;
  let auth: string | null = null;
  await withServer(async (request) => {
    auth = request.headers.get("authorization");
    form = await request.formData();
    return Response.json({ text: " Привет, мир. ", languages: [{ code: "ru" }] }, { headers: { "openai-processing-ms": "412" } });
  }, async (url) => {
    const candidate: Candidate = { name: "openai", kind: "openai", model: "gpt-transcribe", url, keyEnv: "OPENAI_API_KEY" };
    const result = await transcriberFor(candidate, context({ OPENAI_API_KEY: "sk-test" }))(clip(), AbortSignal.timeout(5000));
    assertEquals(result, { text: "Привет, мир.", language: "ru", serverMs: 412 });
  });
  assertEquals(auth, "Bearer sk-test");
  assertEquals(form!.get("model"), "gpt-transcribe");
  assertEquals(form!.getAll("languages[]"), ["ru", "en"]);
  assertEquals(form!.getAll("keywords[]"), ["Murmur", "Okafor"]);
  assertEquals((form!.get("file") as File).type, "audio/mp4");
});

Deno.test("openai-compatible: no key, no language when it must detect one, the terms as a prompt, wav for other files", async () => {
  let form: FormData | null = null;
  let auth: string | null = "unset";
  await withServer(async (request) => {
    auth = request.headers.get("authorization");
    form = await request.formData();
    return Response.json({ text: "hello", language: "en" }, { headers: { "x-processing-ms": "57" } });
  }, async (url) => {
    const candidate: Candidate = { name: "parakeet", kind: "openai-compatible", model: "nemo-parakeet-tdt-0.6b-v3", url: `${url}/` };
    const result = await transcriberFor(candidate, context())(clip("audio/x.aiff"), AbortSignal.timeout(5000));
    assertEquals(result, { text: "hello", language: "en", serverMs: 57 });
  });
  assertEquals(auth, null);
  assertEquals(form!.get("language"), null);
  assertEquals(form!.get("prompt"), "Murmur, Okafor");
  assertEquals((form!.get("file") as File).type, "audio/wav");
});

Deno.test("a failure says the status and the error's type, never its message", async () => {
  await withServer(() => Response.json({ error: { message: "Incorrect API key provided: sk-…", code: "invalid_api_key" } }, { status: 401 }), async (url) => {
    const candidate: Candidate = { name: "openai", kind: "openai", model: "gpt-transcribe", url, keyEnv: "K" };
    const error = await assertRejects(() => transcriberFor(candidate, context({ K: "x" }))(clip(), AbortSignal.timeout(5000)), CandidateError);
    assertEquals(error.short, "OpenAI HTTP 401 invalid_api_key");
  });
});

Deno.test("a candidate whose key isn't set can't be made", () => {
  const candidate: Candidate = { name: "eleven", kind: "elevenlabs", model: "scribe_v3", keyEnv: "ELEVENLABS_API_KEY" };
  try {
    transcriberFor(candidate, context());
    throw new Error("expected a CandidateError");
  } catch (error) {
    assert(error instanceof CandidateError);
    assertEquals(error.short, "no ELEVENLABS_API_KEY in the environment");
  }
});

Deno.test("elevenlabs: its header, the model, digits for numbers, key terms, and its three-letter language codes", async () => {
  let form: FormData | null = null;
  let key: string | null = null;
  let path = "";
  await withServer(async (request) => {
    key = request.headers.get("xi-api-key");
    path = new URL(request.url).pathname;
    form = await request.formData();
    return Response.json({ text: "Встреча в 15:30.", language_code: "rus", language_probability: 0.98, words: [] });
  }, async (url) => {
    const candidate: Candidate = { name: "eleven", kind: "elevenlabs", model: "scribe_v3", url, keyEnv: "E" };
    const result = await transcriberFor(candidate, context({ E: "xi-test" }))(clip(), AbortSignal.timeout(5000));
    assertEquals(result, { text: "Встреча в 15:30.", language: "ru", serverMs: null });
  });
  assertEquals([key, path], ["xi-test", "/v1/speech-to-text"]);
  assertEquals(form!.get("model_id"), "scribe_v3");
  assertEquals(form!.get("numbers_format"), "digits");
  assertEquals(form!.get("tag_audio_events"), "false");
  assertEquals(form!.get("language_code"), null);
  assertEquals(form!.getAll("keyterms"), ["Murmur", "Okafor"]);
});

Deno.test("soniox: the live relay's adapter over a socket, all the audio, then finalize; the text when <fin> comes", async () => {
  const received = { config: null as Record<string, unknown> | null, audioBytes: 0, auth: null as string | null, ended: false };
  await withServer((request) => {
    received.auth = request.headers.get("authorization");
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.onmessage = (event) => {
      if (typeof event.data !== "string") {
        received.audioBytes += (event.data as ArrayBuffer).byteLength ?? (event.data as Blob).size;
        return;
      }
      if (event.data === "") {
        received.ended = true;
        socket.send(JSON.stringify({ tokens: [], finished: true }));
        return socket.close(1000);
      }
      const message = JSON.parse(event.data);
      if (message.type === "finalize") {
        socket.send(JSON.stringify({ tokens: [{ text: "Скинь", is_final: true, language: "ru" }, { text: " pull", is_final: false }] }));
        socket.send(JSON.stringify({ tokens: [{ text: " pull request.", is_final: true, language: "en" }, { text: "<fin>", is_final: true }] }));
      } else received.config = message;
    };
    return response;
  }, async (url) => {
    const candidate: Candidate = { name: "soniox", kind: "soniox", model: "stt-rt-v6", url: url.replace("http", "ws"), keyEnv: "S" };
    const result = await transcriberFor(candidate, context({ S: "soniox-test" }))(clip(), AbortSignal.timeout(5000));
    assertEquals(result.text, "Скинь pull request.");
    assertEquals(result.language, "ru");
    assert(typeof result.detail?.finalizeMs === "number");
  });
  assertEquals(received.auth, "Bearer soniox-test");
  assertEquals(received.config?.model, "stt-rt-v6");
  assertEquals(received.config?.language_hints, ["ru", "en"]);
  assertEquals(received.config?.context, { terms: ["Murmur", "Okafor"] });
  // The clip and the 200 ms of silence the adapter adds before finalize.
  assertEquals(received.audioBytes, PCM.byteLength + 6400);
});

Deno.test("soniox: an error reply fails the clip with its status and type", async () => {
  await withServer((request) => {
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.onmessage = () => {
      socket.send(JSON.stringify({ error_code: 402, error_type: "insufficient_balance", error_message: "top up" }));
      socket.close(1000);
    };
    return response;
  }, async (url) => {
    const candidate: Candidate = { name: "soniox", kind: "soniox", model: "stt-rt-v6", url: url.replace("http", "ws"), keyEnv: "S" };
    const error = await assertRejects(() => transcriberFor(candidate, context({ S: "k" }))(clip(), AbortSignal.timeout(5000)), CandidateError);
    assertEquals(error.short, "soniox 402 insufficient_balance");
  });
});

Deno.test("vllm-realtime: session.created, the model, base64 audio, the final commit, then transcription.done", async () => {
  const seen: string[] = [];
  let audio = 0;
  await withServer((request) => {
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.onopen = () => socket.send(JSON.stringify({ type: "session.created", id: "sess_1" }));
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data as string);
      seen.push(message.final ? "commit final" : message.type);
      if (message.type === "input_audio_buffer.append") audio += atob(message.audio).length;
      if (message.type === "input_audio_buffer.commit" && message.final) {
        socket.send(JSON.stringify({ type: "transcription.delta", delta: "Hello" }));
        socket.send(JSON.stringify({ type: "transcription.done", text: "Hello there.", usage: {} }));
      }
    };
    return response;
  }, async (url) => {
    const candidate: Candidate = { name: "voxtral", kind: "vllm-realtime", model: "mistralai/Voxtral-Mini-4B-Realtime-2602", url: `${url.replace("http", "ws")}/v1/realtime` };
    const result = await transcriberFor(candidate, context())(clip(), AbortSignal.timeout(5000));
    assertEquals(result.text, "Hello there.");
  });
  assertEquals(seen[0], "session.update");
  assertEquals(seen[1], "input_audio_buffer.commit");
  assertEquals(seen.at(-1), "commit final");
  assertEquals(audio, PCM.byteLength);
});

Deno.test("a socket that never answers fails at the deadline instead of hanging", async () => {
  await withServer((request) => Deno.upgradeWebSocket(request).response, async (url) => {
    const candidate: Candidate = { name: "voxtral", kind: "vllm-realtime", model: "m", url: url.replace("http", "ws") };
    const started = performance.now();
    const error = await assertRejects(() => transcriberFor(candidate, context())(clip(), AbortSignal.timeout(300)), CandidateError);
    assertEquals(error.short, "timed out");
    assert(performance.now() - started < 3000);
  });
});

Deno.test("a model's own language tag in front of the text never counts as words", () => {
  assertEquals(withoutLanguageTag("language Russian<asr_text>Привет, мир."), { text: "Привет, мир.", language: "ru" });
  assertEquals(withoutLanguageTag("  language English <asr_text> Hello. "), { text: "Hello.", language: "en" });
  assertEquals(withoutLanguageTag("The language of love."), { text: "The language of love.", language: null });
});
