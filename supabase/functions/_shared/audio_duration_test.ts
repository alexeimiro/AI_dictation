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
