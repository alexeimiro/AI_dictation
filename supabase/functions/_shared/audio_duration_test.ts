import { assertEquals } from "jsr:@std/assert@1";
import { audioDurationMs } from "./audio_duration.ts";

const ascii = (text: string) => [...text].map((char) => char.charCodeAt(0));
const u32 = (value: number) => [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
const u32le = (value: number) => u32(value).reverse();
const u16le = (value: number) => [value & 0xff, (value >>> 8) & 0xff];
const u64 = (value: number) => [...u32(Math.floor(value / 2 ** 32)), ...u32(value >>> 0)];

/** An MPEG-4 box: its size, its type, its content. */
function box(type: string, content: number[]): number[] {
  return [...u32(8 + content.length), ...ascii(type), ...content];
}

/** A version 0 `mvhd` or `mdhd`: version and flags, two dates, the timescale, the duration. */
function header(type: string, timescale: number, duration: number): number[] {
  return box(type, [0, 0, 0, 0, ...u32(0), ...u32(0), ...u32(timescale), ...u32(duration), ...new Array(8).fill(0)]);
}

const FTYP = box("ftyp", [...ascii("M4A "), ...u32(0), ...ascii("M4A mp42isom")]);
const MDAT = box("mdat", new Array(64).fill(7));

function m4a(...boxes: number[][]): Uint8Array {
  return new Uint8Array(boxes.flat());
}

/** A WAV file: 16 kHz mono PCM16 unless told otherwise. */
function wav(
  dataBytes: number,
  options: { byteRate?: number; statedSize?: number; before?: number[]; format?: number[] } = {},
): Uint8Array {
  const format = options.format ?? [
    ...u16le(1),
    ...u16le(1),
    ...u32le(16000),
    ...u32le(options.byteRate ?? 32000),
    ...u16le(2),
    ...u16le(16),
  ];
  const chunks = [
    ...ascii("fmt "),
    ...u32le(format.length),
    ...format,
    ...(options.before ?? []),
    ...ascii("data"),
    ...u32le(options.statedSize ?? dataBytes),
    ...new Array(dataBytes).fill(0),
  ];
  return new Uint8Array([...ascii("RIFF"), ...u32le(4 + chunks.length), ...ascii("WAVE"), ...chunks]);
}

Deno.test("an m4a's length is its movie header's duration over its timescale", () => {
  // As iOS writes it: the audio first, the movie box at the end.
  const file = m4a(FTYP, MDAT, box("moov", header("mvhd", 16000, 124800)));
  assertEquals(audioDurationMs(file, "m4a"), 7800);
});

// An upload as the app sends it (`M4AFreeSpace` in the app): half a second of a 440 Hz tone in low
// data mode, through `EncodedAudio.aac` on the iOS 26.5 simulator. Core Audio wrote ftyp, moov, a
// 23,681-byte free box of zeros and mdat (25,257 bytes); the upload is ftyp, moov, mdat.
const APP_UPLOAD = Uint8Array.from(atob([
  "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",
].join("")), (char) => char.charCodeAt(0));

Deno.test("an upload without Core Audio's empty space states the length it was written with", () => {
  assertEquals(APP_UPLOAD.length, 1576);
  // 8,000 samples, plus the encoder's lead-in and the last frame's padding: ten frames of 1,024.
  assertEquals(audioDurationMs(APP_UPLOAD, "m4a"), 640);
  // The free box put back where Core Audio wrote it: after ftyp (28 bytes) and moov (859).
  const audioStart = 28 + 859;
  const asWritten = new Uint8Array([
    ...APP_UPLOAD.subarray(0, audioStart),
    ...box("free", new Array(23681 - 8).fill(0)),
    ...APP_UPLOAD.subarray(audioStart),
  ]);
  assertEquals(asWritten.length, 25257);
  assertEquals(audioDurationMs(asWritten, "m4a"), 640);
});

Deno.test("an m4a with the movie box first, and a rounded length", () => {
  const file = m4a(FTYP, box("moov", header("mvhd", 44100, 100000)), MDAT);
  assertEquals(audioDurationMs(file, "m4a"), 2268);
});

Deno.test("a version 1 movie header holds a 64-bit duration", () => {
  const mvhd = box("mvhd", [1, 0, 0, 0, ...u64(0), ...u64(0), ...u32(1000), ...u64(61250), ...new Array(8).fill(0)]);
  assertEquals(audioDurationMs(m4a(FTYP, MDAT, box("moov", mvhd)), "m4a"), 61250);
});

Deno.test("a box with a 64-bit size is stepped over", () => {
  const big = [...u32(1), ...ascii("mdat"), ...u64(16 + 32), ...new Array(32).fill(7)];
  assertEquals(audioDurationMs(m4a(FTYP, big, box("moov", header("mvhd", 1000, 5300))), "m4a"), 5300);
});

Deno.test("a movie header without a duration falls back to the first track's", () => {
  const track = box("trak", box("mdia", header("mdhd", 16000, 48000)));
  const file = m4a(FTYP, MDAT, box("moov", [...header("mvhd", 1000, 0), ...track]));
  assertEquals(audioDurationMs(file, "m4a"), 3000);
});

Deno.test("an m4a that doesn't say how long it is gives null", () => {
  assertEquals(audioDurationMs(m4a(FTYP, MDAT), "m4a"), null, "no movie box");
  assertEquals(audioDurationMs(m4a(FTYP, box("moov", header("mvhd", 1000, 0))), "m4a"), null, "no duration anywhere");
  assertEquals(audioDurationMs(m4a(FTYP, box("moov", header("mvhd", 0, 500))), "m4a"), null, "no timescale");
  assertEquals(audioDurationMs(m4a(FTYP, box("moov", header("mvhd", 1000, 0xffffffff))), "m4a"), null, "unknown duration");
  assertEquals(audioDurationMs(new TextEncoder().encode("fake m4a bytes"), "m4a"), null, "not an MPEG-4 file");
  assertEquals(audioDurationMs(new Uint8Array(), "m4a"), null, "empty");
});

Deno.test("an m4a cut short gives null instead of throwing", () => {
  const whole = m4a(FTYP, box("moov", header("mvhd", 16000, 124800)));
  for (let length = 0; length < whole.length; length++) {
    assertEquals(audioDurationMs(whole.slice(0, length), "m4a"), null, `cut at ${length}`);
  }
});

Deno.test("the bytes are read from where the array starts in its buffer", () => {
  const file = m4a(FTYP, MDAT, box("moov", header("mvhd", 16000, 124800)));
  const padded = new Uint8Array(file.length + 5);
  padded.set(file, 5);
  assertEquals(audioDurationMs(padded.subarray(5), "m4a"), 7800);
});

Deno.test("a WAV's length is its data bytes over its bytes per second", () => {
  assertEquals(audioDurationMs(wav(32000), "wav"), 1000);
  assertEquals(audioDurationMs(wav(8000), "wav"), 250);
  assertEquals(audioDurationMs(wav(9600, { byteRate: 96000 }), "wav"), 100);
});

Deno.test("a WAV whose writer never filled in the data size is measured to its end", () => {
  assertEquals(audioDurationMs(wav(16000, { statedSize: 0 }), "wav"), 500);
  assertEquals(audioDurationMs(wav(16000, { statedSize: 0xffffffff }), "wav"), 500);
  assertEquals(audioDurationMs(wav(16000, { statedSize: 64000 }), "wav"), 500, "a size past the end");
});

Deno.test("chunks before the audio are stepped over, with their padding", () => {
  // An odd-length chunk is followed by one byte of padding.
  const list = [...ascii("LIST"), ...u32le(3), 1, 2, 3, 0];
  assertEquals(audioDurationMs(wav(32000, { before: list }), "wav"), 1000);
});

Deno.test("the extensible format, which afconvert writes, has the same first fields", () => {
  const extensible = [
    ...u16le(0xfffe),
    ...u16le(1),
    ...u32le(16000),
    ...u32le(32000),
    ...u16le(2),
    ...u16le(16),
    ...new Array(24).fill(0),
  ];
  assertEquals(audioDurationMs(wav(64000, { format: extensible }), "wav"), 2000);
});

Deno.test("a WAV that doesn't say how long it is gives null", () => {
  assertEquals(audioDurationMs(new TextEncoder().encode("not a wave file at all"), "wav"), null);
  assertEquals(audioDurationMs(wav(32000, { byteRate: 0 }), "wav"), null, "no bytes per second");
  assertEquals(audioDurationMs(wav(32000).slice(0, 30), "wav"), null, "cut before the audio");
  assertEquals(audioDurationMs(new Uint8Array(), "wav"), null, "empty");
});
