#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";

function fail(message) {
  throw new Error(`native-macho64-signed: ${message}`);
}

function expect(condition, message) {
  if (!condition) fail(message);
}

function u32le(bytes, offset) {
  expect(offset + 4 <= bytes.length, `u32le outside image at ${offset}`);
  return bytes.readUInt32LE(offset);
}

function u64le(bytes, offset) {
  expect(offset + 8 <= bytes.length, `u64le outside image at ${offset}`);
  return bytes.readBigUInt64LE(offset);
}

function u32be(bytes, offset) {
  expect(offset + 4 <= bytes.length, `u32be outside image at ${offset}`);
  return bytes.readUInt32BE(offset);
}

function u64be(bytes, offset) {
  expect(offset + 8 <= bytes.length, `u64be outside image at ${offset}`);
  return bytes.readBigUInt64BE(offset);
}

function fixedName(bytes, offset) {
  const field = bytes.subarray(offset, offset + 16);
  const zero = field.indexOf(0);
  return field.subarray(0, zero < 0 ? field.length : zero).toString("ascii");
}

const profiles = [
  {
    name: "x86-64",
    cpuType: 0x01000007,
    cpuSubtype: 3,
    pageSize: 4096,
    pageShift: 12,
    alignment: 0,
    code: Buffer.from([0xb8, 1, 0, 0, 2, 0x31, 0xff, 0x0f, 5]),
  },
  {
    name: "AArch64",
    cpuType: 0x0100000c,
    cpuSubtype: 0,
    pageSize: 16384,
    pageShift: 14,
    alignment: 2,
    code: Buffer.from([
      0, 0, 0x80, 0xd2,
      0x30, 0, 0x80, 0xd2,
      1, 0x10, 0, 0xd4,
    ]),
  },
];

function validate(bytes, profile) {
  expect(bytes.length === profile.pageSize + 160, `${profile.name}: image size`);
  expect(u32le(bytes, 0) === 0xfeedfacf, `${profile.name}: MH_MAGIC_64`);
  expect(u32le(bytes, 4) === profile.cpuType, `${profile.name}: CPU type`);
  expect(u32le(bytes, 8) === profile.cpuSubtype, `${profile.name}: CPU subtype`);
  expect(u32le(bytes, 12) === 2, `${profile.name}: MH_EXECUTE`);
  expect(u32le(bytes, 16) === 7, `${profile.name}: load-command count`);
  expect(u32le(bytes, 20) === 392, `${profile.name}: load-command bytes`);
  expect(u32le(bytes, 24) === 0x200085, `${profile.name}: Mach flags`);
  expect(u32le(bytes, 28) === 0, `${profile.name}: reserved header field`);

  const pagezero = 32;
  expect(u32le(bytes, pagezero) === 0x19, `${profile.name}: pagezero command`);
  expect(u32le(bytes, pagezero + 4) === 72, `${profile.name}: pagezero size`);
  expect(fixedName(bytes, pagezero + 8) === "__PAGEZERO", `${profile.name}: pagezero name`);
  expect(u64le(bytes, pagezero + 24) === 0n, `${profile.name}: pagezero address`);
  expect(u64le(bytes, pagezero + 32) === 0x100000000n, `${profile.name}: pagezero VM size`);
  expect(u64le(bytes, pagezero + 40) === 0n, `${profile.name}: pagezero file offset`);
  expect(u64le(bytes, pagezero + 48) === 0n, `${profile.name}: pagezero file size`);

  const text = 104;
  expect(u32le(bytes, text) === 0x19, `${profile.name}: text command`);
  expect(u32le(bytes, text + 4) === 152, `${profile.name}: text command size`);
  expect(fixedName(bytes, text + 8) === "__TEXT", `${profile.name}: text name`);
  expect(u64le(bytes, text + 24) === 0x100000000n, `${profile.name}: text address`);
  expect(u64le(bytes, text + 32) === BigInt(profile.pageSize), `${profile.name}: text VM size`);
  expect(u64le(bytes, text + 40) === 0n, `${profile.name}: text file offset`);
  expect(u64le(bytes, text + 48) === BigInt(profile.pageSize), `${profile.name}: text file size`);
  expect(u32le(bytes, text + 56) === 5, `${profile.name}: text max protection`);
  expect(u32le(bytes, text + 60) === 5, `${profile.name}: text protection`);
  expect(u32le(bytes, text + 64) === 1, `${profile.name}: text section count`);

  const section = 176;
  expect(fixedName(bytes, section) === "__text", `${profile.name}: section name`);
  expect(fixedName(bytes, section + 16) === "__TEXT", `${profile.name}: section segment`);
  expect(u64le(bytes, section + 32) === 0x100000200n, `${profile.name}: section address`);
  expect(u64le(bytes, section + 40) === BigInt(profile.code.length), `${profile.name}: section size`);
  expect(u32le(bytes, section + 48) === 512, `${profile.name}: section offset`);
  expect(u32le(bytes, section + 52) === profile.alignment, `${profile.name}: section alignment`);
  expect(u32le(bytes, section + 64) === 0x80000400, `${profile.name}: section flags`);

  const linkedit = 256;
  expect(u32le(bytes, linkedit) === 0x19, `${profile.name}: linkedit command`);
  expect(u32le(bytes, linkedit + 4) === 72, `${profile.name}: linkedit size`);
  expect(fixedName(bytes, linkedit + 8) === "__LINKEDIT", `${profile.name}: linkedit name`);
  expect(
    u64le(bytes, linkedit + 24) === 0x100000000n + BigInt(profile.pageSize),
    `${profile.name}: linkedit address`,
  );
  expect(u64le(bytes, linkedit + 32) === 160n, `${profile.name}: linkedit VM size`);
  expect(u64le(bytes, linkedit + 40) === BigInt(profile.pageSize), `${profile.name}: linkedit file offset`);
  expect(u64le(bytes, linkedit + 48) === 160n, `${profile.name}: linkedit file size`);
  expect(u32le(bytes, linkedit + 56) === 1, `${profile.name}: linkedit max protection`);
  expect(u32le(bytes, linkedit + 60) === 1, `${profile.name}: linkedit protection`);
  expect(u32le(bytes, linkedit + 64) === 0, `${profile.name}: linkedit sections`);

  const dylinker = 328;
  expect(u32le(bytes, dylinker) === 0x0e, `${profile.name}: LC_LOAD_DYLINKER`);
  expect(u32le(bytes, dylinker + 4) === 32, `${profile.name}: dylinker size`);
  expect(u32le(bytes, dylinker + 8) === 12, `${profile.name}: dylinker path offset`);
  expect(
    bytes.subarray(dylinker + 12, dylinker + 26).equals(Buffer.from("/usr/lib/dyld\0")),
    `${profile.name}: dylinker path`,
  );

  const version = 360;
  expect(u32le(bytes, version) === 0x32, `${profile.name}: LC_BUILD_VERSION`);
  expect(u32le(bytes, version + 4) === 24, `${profile.name}: version size`);
  expect(u32le(bytes, version + 8) === 1, `${profile.name}: macOS platform`);
  expect(u32le(bytes, version + 12) === 0x0b0000, `${profile.name}: minimum OS`);
  expect(u32le(bytes, version + 16) === 0x0b0000, `${profile.name}: SDK`);
  expect(u32le(bytes, version + 20) === 0, `${profile.name}: tool count`);

  const main = 384;
  expect(u32le(bytes, main) === 0x80000028, `${profile.name}: LC_MAIN`);
  expect(u32le(bytes, main + 4) === 24, `${profile.name}: main size`);
  expect(u64le(bytes, main + 8) === 512n, `${profile.name}: entry offset`);
  expect(u64le(bytes, main + 16) === 0n, `${profile.name}: stack size`);

  const codeSignature = 408;
  expect(u32le(bytes, codeSignature) === 0x1d, `${profile.name}: LC_CODE_SIGNATURE`);
  expect(u32le(bytes, codeSignature + 4) === 16, `${profile.name}: signature command size`);
  expect(u32le(bytes, codeSignature + 8) === profile.pageSize, `${profile.name}: signature offset`);
  expect(u32le(bytes, codeSignature + 12) === 160, `${profile.name}: signature size`);

  let commandOffset = 32;
  for (let index = 0; index < 7; index += 1) {
    const commandSize = u32le(bytes, commandOffset + 4);
    expect(commandSize >= 8 && commandSize % 8 === 0, `${profile.name}: aligned command ${index}`);
    commandOffset += commandSize;
  }
  expect(commandOffset === 424, `${profile.name}: command traversal end`);
  expect(bytes.subarray(424, 512).every((byte) => byte === 0), `${profile.name}: header padding`);
  expect(
    bytes.subarray(512, 512 + profile.code.length).equals(profile.code),
    `${profile.name}: entry code`,
  );
  expect(
    bytes.subarray(512 + profile.code.length, profile.pageSize).every((byte) => byte === 0),
    `${profile.name}: signed page padding`,
  );

  const signature = profile.pageSize;
  expect(u32be(bytes, signature) === 0xfade0cc0, `${profile.name}: SuperBlob magic`);
  expect(u32be(bytes, signature + 4) === 160, `${profile.name}: SuperBlob length`);
  expect(u32be(bytes, signature + 8) === 1, `${profile.name}: SuperBlob count`);
  expect(u32be(bytes, signature + 12) === 0, `${profile.name}: CodeDirectory slot`);
  expect(u32be(bytes, signature + 16) === 20, `${profile.name}: CodeDirectory offset`);

  const directory = signature + 20;
  expect(u32be(bytes, directory) === 0xfade0c02, `${profile.name}: CodeDirectory magic`);
  expect(u32be(bytes, directory + 4) === 140, `${profile.name}: CodeDirectory length`);
  expect(u32be(bytes, directory + 8) === 0x20400, `${profile.name}: CodeDirectory version`);
  expect(u32be(bytes, directory + 12) === 0x20002, `${profile.name}: ad-hoc flags`);
  expect(u32be(bytes, directory + 16) === 108, `${profile.name}: hash offset`);
  expect(u32be(bytes, directory + 20) === 88, `${profile.name}: identifier offset`);
  expect(u32be(bytes, directory + 24) === 0, `${profile.name}: special slots`);
  expect(u32be(bytes, directory + 28) === 1, `${profile.name}: code slots`);
  expect(u32be(bytes, directory + 32) === profile.pageSize, `${profile.name}: code limit`);
  expect(bytes[directory + 36] === 32, `${profile.name}: hash size`);
  expect(bytes[directory + 37] === 2, `${profile.name}: SHA-256 hash type`);
  expect(bytes[directory + 38] === 0, `${profile.name}: platform`);
  expect(bytes[directory + 39] === profile.pageShift, `${profile.name}: page exponent`);
  expect(u32be(bytes, directory + 40) === 0, `${profile.name}: spare2`);
  expect(u32be(bytes, directory + 44) === 0, `${profile.name}: scatter offset`);
  expect(u32be(bytes, directory + 48) === 0, `${profile.name}: team offset`);
  expect(u32be(bytes, directory + 52) === 0, `${profile.name}: spare3`);
  expect(u64be(bytes, directory + 56) === 0n, `${profile.name}: codeLimit64`);
  expect(u64be(bytes, directory + 64) === 0n, `${profile.name}: executable base`);
  expect(u64be(bytes, directory + 72) === BigInt(profile.pageSize), `${profile.name}: executable limit`);
  expect(u64be(bytes, directory + 80) === 1n, `${profile.name}: main executable flag`);
  expect(
    bytes.subarray(directory + 88, directory + 93).equals(Buffer.from("kofun")),
    `${profile.name}: identifier`,
  );
  expect(
    bytes.subarray(directory + 93, directory + 108).every((byte) => byte === 0),
    `${profile.name}: identifier padding`,
  );

  const embeddedHash = bytes.subarray(directory + 108, directory + 140);
  const recomputedHash = crypto.createHash("sha256")
    .update(bytes.subarray(0, profile.pageSize))
    .digest();
  expect(embeddedHash.equals(recomputedHash), `${profile.name}: code page SHA-256`);
  return { directory, signature };
}

function mutationMustFail(bytes, profile, name, mutate) {
  const changed = Buffer.from(bytes);
  mutate(changed);
  let refused = false;
  try {
    validate(changed, profile);
  } catch {
    refused = true;
  }
  expect(refused, `${profile.name}: ${name} mutation was accepted`);
}

if (process.argv.length !== 4) {
  fail("usage: macho64-signed-check.mjs X86_64.macho AARCH64.macho");
}

for (let index = 0; index < profiles.length; index += 1) {
  const bytes = fs.readFileSync(process.argv[index + 2]);
  const profile = profiles[index];
  const { directory, signature } = validate(bytes, profile);
  mutationMustFail(bytes, profile, "magic", (image) => image.writeUInt32LE(0, 0));
  mutationMustFail(bytes, profile, "signature offset", (image) => image.writeUInt32LE(0, 416));
  mutationMustFail(bytes, profile, "SuperBlob magic", (image) => image.writeUInt32BE(0, signature));
  mutationMustFail(bytes, profile, "CodeDirectory length", (image) => image.writeUInt32BE(0, directory + 4));
  mutationMustFail(bytes, profile, "signed code", (image) => { image[512] ^= 1; });
  mutationMustFail(bytes, profile, "embedded hash", (image) => { image[directory + 108] ^= 1; });
}

console.log("PASS: Mach-O ad-hoc SuperBlob, CodeDirectory, page hashes, layout, and mutations");
