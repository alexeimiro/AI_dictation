import { assertEquals } from "jsr:@std/assert@1";
import { readManifest } from "./clips.ts";
import { clipsFromHistory, type HistoryRow, importMurmurFolder, parseDevices } from "./pull_phone.ts";

const ID = "BFD971FA183B4A908B4F8BC176BA6705";
const UUID = "BFD971FA-183B-4A90-8B4F-8BC176BA6705";

function row(fields: Partial<HistoryRow> = {}): HistoryRow {
  return {
    id: ID, ZCREATEDAT: 815902221.9, ZLANGUAGE: "en", ZSTYLE: "verbatim", ZRAWTEXT: "So how long will it take?", ZSTATUS: "raw",
    ZSOURCE: "keyboard", ZAUDIOSECONDS: 6.6, ...fields,
  };
}

Deno.test("a history row with a recording and a transcript is a clip", () => {
  const { clips, skipped } = clipsFromHistory([row()], new Map([[UUID, `${UUID}.m4a`]]), "phone");
  assertEquals(clips.length, 1);
  assertEquals(clips[0].id, UUID);
  assertEquals(clips[0].file, `audio/${UUID}.m4a`);
  assertEquals(clips[0].audioMs, 6600);
  assertEquals(clips[0].group, "en");
  assertEquals(clips[0].createdAt, "2026-11-09T07:30:21.900Z");
  assertEquals(Object.values(skipped).reduce((a, b) => a + b, 0), 0);
});

Deno.test("failed, empty, unrecorded and old dictations are left out, and counted", () => {
  const other = (hex: string) => hex.replace(/^./, "A");
  const rows = [
    row({ ZSTATUS: "failed" }),
    row({ id: other(ID), ZRAWTEXT: "  " }),
    row({ id: "C".repeat(32) }),
    row({ id: "D".repeat(32), ZCREATEDAT: 700000000 }),
    row({ id: "E".repeat(32), ZSTATUS: "cleaned", ZRAWTEXT: "Привет, это тест." }),
  ];
  const recordings = new Map([
    [UUID, `${UUID}.m4a`],
    ["AFD971FA-183B-4A90-8B4F-8BC176BA6705", "AFD971FA-183B-4A90-8B4F-8BC176BA6705.m4a"],
    ["DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD.wav"],
    ["EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE.wav"],
  ]);
  const { clips, skipped } = clipsFromHistory(rows, recordings, "phone", new Date("2026-01-01"));
  assertEquals(clips.map((clip) => [clip.id.slice(0, 4), clip.group, clip.file.split(".").pop()]), [["EEEE", "ru", "wav"]]);
  assertEquals(skipped, { "no recording": 1, "no text": 1, "failed or empty": 1, "older": 1 });
});

Deno.test("a folder laid out like the app's becomes clips, with the audio copied", async () => {
  const root = await Deno.makeTempDir();
  try {
    const murmur = `${root}/phone/Library/Application Support/Murmur`;
    await Deno.mkdir(`${murmur}/Recordings`, { recursive: true });
    // The app's table as SwiftData creates it.
    const schema = "CREATE TABLE ZTRANSCRIPTRECORD ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZASRMS INTEGER, " +
      "ZCLEANUPMS INTEGER, ZTOTALMS INTEGER, ZTTFTMS INTEGER, ZWORDS INTEGER, ZAUDIOSECONDS FLOAT, ZCREATEDAT TIMESTAMP, " +
      "ZINSERTEDAT TIMESTAMP, ZREGENERATEDAT TIMESTAMP, ZCLEANEDTEXT VARCHAR, ZCLEANUPMODEL VARCHAR, ZERRORREASON VARCHAR, " +
      "ZLANGUAGE VARCHAR, ZRAWTEXT VARCHAR, ZSOURCE VARCHAR, ZSTATUS VARCHAR, ZSTYLE VARCHAR, ZID BLOB );";
    const insert = `INSERT INTO ZTRANSCRIPTRECORD (Z_ENT, Z_OPT, ZID, ZCREATEDAT, ZLANGUAGE, ZSTYLE, ZRAWTEXT, ZSTATUS, ZSOURCE, ZAUDIOSECONDS) ` +
      `VALUES (1, 1, X'${ID}', 815902221.9, 'ru', 'verbatim', 'Скинь pull request, пожалуйста.', 'raw', 'keyboard', 4.2);`;
    const { success } = await new Deno.Command("sqlite3", { args: [`${murmur}/History.store`, schema + insert] }).output();
    assertEquals(success, true);
    await Deno.writeFile(`${murmur}/Recordings/${UUID}.m4a`, new Uint8Array([1, 2, 3]));
    const work = `${root}/work`;
    const result = await importMurmurFolder(`${root}/phone`, work, "test phone", null);
    assertEquals([result.rows, result.recordings, result.clips.length], [1, 1, 1]);
    assertEquals(result.clips[0].group, "mix");
    assertEquals(await Deno.readFile(`${work}/audio/${UUID}.m4a`), new Uint8Array([1, 2, 3]));
    // The manifest is written by the command, not by the import.
    assertEquals((await readManifest(work)).clips.length, 0);
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});

Deno.test("devicectl's device list, as far as the pull needs it", () => {
  const devices = parseDevices({
    result: {
      devices: [{
        identifier: "0A1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D",
        deviceProperties: { name: "iPhone" },
        hardwareProperties: { marketingName: "iPhone 16 Pro", udid: "00008140-0001A2B3C4D5E6F7" },
        connectionProperties: { transportType: "wired", tunnelState: "connected" },
      }],
    },
  });
  assertEquals(devices, [{ identifier: "0A1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D", name: "iPhone", model: "iPhone 16 Pro", state: "wired, connected" }]);
  assertEquals(parseDevices(null), []);
});
