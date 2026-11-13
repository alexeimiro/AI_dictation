// The candidates of the model test: who turns the clips into text. A JSON file lists them
// (candidates.example.json has all eight of the plan); the runner reads it, the report prices them.
//
// Kinds, by the protocol they speak:
//   openai             OpenAI's POST /v1/audio/transcriptions, sent exactly as the `transcribe` function sends it
//   openai-compatible  the same request to another server: vLLM (Qwen3-ASR, Whisper), model_server.py (Parakeet,
//                      GigaAM), or any server that speaks it
//   elevenlabs         ElevenLabs' POST /v1/speech-to-text (Scribe)
//   soniox             Soniox's realtime WebSocket, through the live relay's own adapter (_shared/live/soniox.ts)
//   vllm-realtime      vLLM's /v1/realtime WebSocket (Voxtral Realtime)

export const KINDS = ["openai", "openai-compatible", "elevenlabs", "soniox", "vllm-realtime"] as const;
export type CandidateKind = typeof KINDS[number];

/** How the runner starts a candidate's own server, one at a time (`run.ts --serve`), and knows it is up. */
export interface ServeSpec {
  /** The command and its arguments; a leading "~/" is your home folder. Run from the repository root. */
  command: string[];
  /** A URL that answers 200 once the model is loaded. */
  ready: string;
  /** How long loading may take, downloads included. 15 minutes when left out. */
  timeoutMs?: number;
  env?: Record<string, string>;
}

export interface Candidate {
  /** Its name in the results, the report and nowhere on the vote page. */
  name: string;
  kind: CandidateKind;
  /** The model as its server names it. */
  model: string;
  /** Where it answers: a base URL (http, or ws for the WebSocket kinds). The service's own address when left out. */
  url?: string;
  /** The environment variable that holds its key; none for your own servers. */
  keyEnv?: string;
  /** An open model on your own GPU: it wins a vote tie within 3 points. */
  own?: boolean;
  /** Its list price per audio minute (services); your own model costs the GPU instead. */
  usdPerMinute?: number;
  /** Where that price was read, and when. */
  priceSource?: string;
  serve?: ServeSpec;
  /** Kind-specific settings: soniox `pace` ("burst" or "realtime"); elevenlabs `numbersFormat`. */
  options?: Record<string, unknown>;
  note?: string;
}

export interface CandidateFile {
  candidates: Candidate[];
  /**
   * The languages you speak, as the app sends them while it detects the language (Auto): ["ru", "en"].
   * A service that takes hints gets them; no candidate is told the language of a clip.
   */
  languageHints?: string[];
  /** Your dictionary's terms, sent as each service's keyword hints, as the app sends them. */
  keywords?: string[];
  /** What your own model's GPU costs, for the report: "≈ €214 a month dedicated, or $0.44–0.89 an hour". */
  ownCost?: string;
}

/** Reads and checks a candidates file; throws with the first problem in plain words. */
export async function readCandidates(path: string): Promise<CandidateFile> {
  let file: CandidateFile;
  try {
    file = JSON.parse(await Deno.readTextFile(path));
  } catch (error) {
    throw new Error(`can't read the candidates file ${path}: ${error instanceof Error ? error.message : error}`);
  }
  if (!Array.isArray(file.candidates) || file.candidates.length === 0) throw new Error(`${path} lists no candidates`);
  const names = new Set<string>();
  for (const candidate of file.candidates) {
    if (!candidate.name || !/^[a-z0-9][a-z0-9._-]*$/i.test(candidate.name)) {
      throw new Error(`a candidate's name must be letters, digits, dots, dashes: ${JSON.stringify(candidate.name)}`);
    }
    if (names.has(candidate.name)) throw new Error(`two candidates are named ${candidate.name}`);
    names.add(candidate.name);
    if (!KINDS.includes(candidate.kind)) throw new Error(`${candidate.name}: kind must be one of ${KINDS.join(", ")}`);
    if (!candidate.model) throw new Error(`${candidate.name}: no model`);
    if ((candidate.kind === "openai-compatible" || candidate.kind === "vllm-realtime") && !candidate.url) {
      throw new Error(`${candidate.name}: an ${candidate.kind} candidate needs a url`);
    }
    if (candidate.serve && (!Array.isArray(candidate.serve.command) || !candidate.serve.command.length || !candidate.serve.ready)) {
      throw new Error(`${candidate.name}: serve needs a command and a ready URL`);
    }
  }
  return file;
}
