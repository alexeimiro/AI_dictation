// How long a dictation's audio is, read from the file's own header, for the cost of transcribing
// it (`_shared/cost.ts`). Nothing is decoded. A file that doesn't say gives null, never a guess.
import type { AudioFormat } from "./transcribe.ts";

/** The audio's length in whole milliseconds, or null when the header doesn't hold it. */
export function audioDurationMs(audio: Uint8Array, format: AudioFormat): number | null {
  try {
    const view = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
    return format === "wav" ? wavDurationMs(view) : mp4DurationMs(view);
  } catch {
    // A header cut short reads past the end: the length is unknown.
    return null;
  }
}

function tag(view: DataView, offset: number): string {
  return String.fromCharCode(
    view.getUint8(offset),
    view.getUint8(offset + 1),
    view.getUint8(offset + 2),
    view.getUint8(offset + 3),
  );
}

/** RIFF/WAVE: the data chunk's bytes over the format chunk's bytes per second. */
function wavDurationMs(view: DataView): number | null {
  if (view.byteLength < 12 || tag(view, 0) !== "RIFF" || tag(view, 8) !== "WAVE") return null;
  let bytesPerSecond = 0;
  let offset = 12;
  while (offset + 8 <= view.byteLength) {
    const id = tag(view, offset);
    const size = view.getUint32(offset + 4, true);
    const content = offset + 8;
    if (id === "fmt " && size >= 16) {
      bytesPerSecond = view.getUint32(content + 8, true);
    } else if (id === "data") {
      if (bytesPerSecond === 0) return null;
      // A writer that never went back to fill in the size leaves 0 or all ones: the rest is audio.
      const rest = view.byteLength - content;
      const bytes = size === 0 || size === 0xffffffff || size > rest ? rest : size;
      return Math.round((bytes / bytesPerSecond) * 1000);
    }
    // Chunks are padded to an even length.
    offset = content + size + (size % 2);
  }
  return null;
}

interface Box {
  /** Where the box's content starts and ends. */
  start: number;
  end: number;
}

/** The first box of `type` among the boxes laid out between `from` and `to`. */
function findBox(view: DataView, from: number, to: number, type: string): Box | null {
  let offset = from;
  while (offset + 8 <= to) {
    let size = view.getUint32(offset);
    let header = 8;
    if (size === 1) {
      // A 64-bit size follows the type.
      if (offset + 16 > to) return null;
      size = Number(view.getBigUint64(offset + 8));
      header = 16;
    } else if (size === 0) {
      // The box runs to the end.
      size = to - offset;
    }
    if (size < header || offset + size > to) return null;
    if (tag(view, offset + 4) === type) return { start: offset + header, end: offset + size };
    offset += size;
  }
  return null;
}

/** The duration an `mvhd` or `mdhd` box states, over its own timescale. */
function headerDurationMs(view: DataView, box: Box): number | null {
  const version = view.getUint8(box.start);
  // After the version and flags: two dates, then the timescale and the duration.
  const timescaleAt = box.start + 4 + (version === 1 ? 16 : 8);
  if (timescaleAt + (version === 1 ? 12 : 8) > box.end) return null;
  const timescale = view.getUint32(timescaleAt);
  const duration = version === 1 ? Number(view.getBigUint64(timescaleAt + 4)) : view.getUint32(timescaleAt + 4);
  // All ones means "unknown"; zero is what a fragmented file's header holds.
  const unknown = version === 1 ? !Number.isSafeInteger(duration) : duration === 0xffffffff;
  if (timescale === 0 || duration === 0 || unknown) return null;
  return Math.round((duration / timescale) * 1000);
}

/** MPEG-4 (.m4a): the movie header's duration, else the first track's. */
function mp4DurationMs(view: DataView): number | null {
  const movie = findBox(view, 0, view.byteLength, "moov");
  if (!movie) return null;
  const movieHeader = findBox(view, movie.start, movie.end, "mvhd");
  const stated = movieHeader ? headerDurationMs(view, movieHeader) : null;
  if (stated !== null) return stated;
  const track = findBox(view, movie.start, movie.end, "trak");
  const media = track ? findBox(view, track.start, track.end, "mdia") : null;
  const mediaHeader = media ? findBox(view, media.start, media.end, "mdhd") : null;
  return mediaHeader ? headerDurationMs(view, mediaHeader) : null;
}
