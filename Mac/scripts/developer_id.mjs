#!/usr/bin/env node
// Creates the "Developer ID Application" certificate Murmur for Mac is signed with for the
// download from simplymurmur.com, from a key made on this Mac, and imports both into the login
// keychain. Does nothing when this Mac already has a Developer ID identity.
//
// Usage: node Mac/scripts/developer_id.mjs
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { api } from "./asc.mjs";

const identities = execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" });
const existing = identities.split("\n").find((line) => line.includes("Developer ID Application"));
if (existing) {
  console.log(`✔ already here: ${existing.trim()}`);
  process.exit(0);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "murmur-devid-"));
try {
  const keyFile = path.join(work, "key.pem");
  const csrFile = path.join(work, "request.csr");
  execFileSync("openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyFile,
    "-out", csrFile, "-subj", "/CN=Murmur Developer ID"], { stdio: "ignore" });
  const csrContent = fs.readFileSync(csrFile, "utf8").replace(/-----[^-]+-----|\s/g, "");
  let created;
  let lastError;
  for (const certificateType of ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"]) {
    try {
      created = await api("POST", "/v1/certificates", {
        data: { type: "certificates", attributes: { certificateType, csrContent } },
      });
      break;
    } catch (error) {
      lastError = error;
      console.log(`… ${certificateType}: ${error.message}`);
    }
  }
  if (!created) throw lastError;
  const certFile = path.join(work, "cert.cer");
  fs.writeFileSync(certFile, Buffer.from(created.data.attributes.certificateContent, "base64"));
  const pemFile = path.join(work, "cert.pem");
  execFileSync("openssl", ["x509", "-inform", "DER", "-in", certFile, "-out", pemFile]);
  // SHA1/3DES: the only PKCS#12 encryption `security import` accepts.
  const p12File = path.join(work, "identity.p12");
  const password = crypto.randomBytes(12).toString("hex");
  execFileSync("openssl", ["pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
    "-macalg", "sha1", "-inkey", keyFile, "-in", pemFile, "-out", p12File, "-passout", `pass:${password}`],
    { stdio: "ignore" });
  execFileSync("security", ["import", p12File, "-k", path.join(os.homedir(), "Library/Keychains/login.keychain-db"),
    "-P", password, "-T", "/usr/bin/codesign"], { stdio: "inherit" });
  console.log(`✔ created ${created.data.attributes.certificateType} ${created.data.id} "${created.data.attributes.name}", expires ${created.data.attributes.expirationDate?.slice(0, 10)}`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
