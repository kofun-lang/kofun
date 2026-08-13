#!/usr/bin/env node

import fs from "node:fs";

function fail(message) {
  throw new Error(`native-pe32plus: ${message}`);
}

function expect(condition, message) {
  if (!condition) fail(message);
}

function u16(bytes, offset) {
  expect(offset + 2 <= bytes.length, `u16 outside image at ${offset}`);
  return bytes.readUInt16LE(offset);
}

function u32(bytes, offset) {
  expect(offset + 4 <= bytes.length, `u32 outside image at ${offset}`);
  return bytes.readUInt32LE(offset);
}

function u64(bytes, offset) {
  expect(offset + 8 <= bytes.length, `u64 outside image at ${offset}`);
  return bytes.readBigUInt64LE(offset);
}

const profiles = [
  {
    name: "x86-64",
    machine: 0x8664,
    code: Buffer.from([0x31, 0xc0, 0xc3]),
  },
  {
    name: "AArch64",
    machine: 0xaa64,
    code: Buffer.from([0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]),
  },
];

function validate(bytes, profile) {
  expect(bytes.length === 1024, `${profile.name}: image size is not 1024`);
  expect(bytes.subarray(0, 2).equals(Buffer.from("MZ")), `${profile.name}: MZ`);

  const pe = u32(bytes, 0x3c);
  expect(pe === 128, `${profile.name}: e_lfanew is not 128`);
  expect(
    bytes.subarray(pe, pe + 4).equals(Buffer.from([0x50, 0x45, 0, 0])),
    `${profile.name}: PE signature`,
  );

  const coff = pe + 4;
  expect(u16(bytes, coff) === profile.machine, `${profile.name}: machine`);
  expect(u16(bytes, coff + 2) === 1, `${profile.name}: section count`);
  expect(u32(bytes, coff + 4) === 0, `${profile.name}: timestamp`);
  expect(u32(bytes, coff + 8) === 0, `${profile.name}: symbol table`);
  expect(u32(bytes, coff + 12) === 0, `${profile.name}: symbol count`);
  expect(u16(bytes, coff + 16) === 240, `${profile.name}: optional size`);
  expect(u16(bytes, coff + 18) === 0x23, `${profile.name}: characteristics`);

  const optional = coff + 20;
  expect(u16(bytes, optional) === 0x20b, `${profile.name}: PE32+ magic`);
  expect(u32(bytes, optional + 4) === 512, `${profile.name}: code size`);
  const entryRva = u32(bytes, optional + 16);
  expect(entryRva === 0x1000, `${profile.name}: entry RVA`);
  expect(u32(bytes, optional + 20) === 0x1000, `${profile.name}: code RVA`);
  expect(u64(bytes, optional + 24) === 0x140000000n, `${profile.name}: image base`);
  expect(u32(bytes, optional + 32) === 4096, `${profile.name}: section alignment`);
  expect(u32(bytes, optional + 36) === 512, `${profile.name}: file alignment`);
  expect(u32(bytes, optional + 56) === 8192, `${profile.name}: image size`);
  expect(u32(bytes, optional + 60) === 512, `${profile.name}: header size`);
  expect(u16(bytes, optional + 68) === 3, `${profile.name}: console subsystem`);
  expect(u32(bytes, optional + 108) === 16, `${profile.name}: data directories`);
  expect(
    bytes.subarray(optional + 112, optional + 240).every((byte) => byte === 0),
    `${profile.name}: absent directories are not zero`,
  );

  const section = optional + 240;
  expect(
    bytes.subarray(section, section + 8).equals(Buffer.from(".text\0\0\0")),
    `${profile.name}: section name`,
  );
  expect(u32(bytes, section + 8) === profile.code.length, `${profile.name}: virtual size`);
  const sectionRva = u32(bytes, section + 12);
  const rawSize = u32(bytes, section + 16);
  const rawOffset = u32(bytes, section + 20);
  expect(sectionRva === 4096, `${profile.name}: section RVA`);
  expect(rawSize === 512, `${profile.name}: raw size`);
  expect(rawOffset === 512, `${profile.name}: raw offset`);
  expect(u32(bytes, section + 36) === 0x60000020, `${profile.name}: section flags`);

  expect(entryRva >= sectionRva, `${profile.name}: entry before section`);
  const entryOffset = rawOffset + entryRva - sectionRva;
  expect(entryOffset < rawOffset + rawSize, `${profile.name}: entry after section`);
  expect(
    bytes.subarray(entryOffset, entryOffset + profile.code.length).equals(profile.code),
    `${profile.name}: entry instructions`,
  );
  expect(
    bytes.subarray(entryOffset + profile.code.length).every((byte) => byte === 0),
    `${profile.name}: nonzero section padding`,
  );
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
  fail("usage: pe32plus-check.mjs X86_64.pe AARCH64.pe");
}

for (let index = 0; index < profiles.length; index += 1) {
  const bytes = fs.readFileSync(process.argv[index + 2]);
  const profile = profiles[index];
  validate(bytes, profile);
  mutationMustFail(bytes, profile, "magic", (image) => { image[0] = 0; });
  mutationMustFail(bytes, profile, "machine", (image) => { image.writeUInt16LE(0, 132); });
  mutationMustFail(bytes, profile, "entry", (image) => { image.writeUInt32LE(0x3000, 168); });
  mutationMustFail(bytes, profile, "alignment", (image) => { image.writeUInt32LE(512, 184); });
}

console.log("PASS: PE32+ headers, machines, entry code, layout, and mutations");
