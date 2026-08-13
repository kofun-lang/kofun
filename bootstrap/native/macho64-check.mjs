#!/usr/bin/env node

import fs from "node:fs";

function fail(message) {
  throw new Error(`native-macho64: ${message}`);
}

function expect(condition, message) {
  if (!condition) fail(message);
}

function u32(bytes, offset) {
  expect(offset + 4 <= bytes.length, `u32 outside image at ${offset}`);
  return bytes.readUInt32LE(offset);
}

function u64(bytes, offset) {
  expect(offset + 8 <= bytes.length, `u64 outside image at ${offset}`);
  return bytes.readBigUInt64LE(offset);
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
    alignment: 0,
    code: Buffer.from([0x31, 0xc0, 0xc3]),
  },
  {
    name: "AArch64",
    cpuType: 0x0100000c,
    cpuSubtype: 0,
    pageSize: 16384,
    alignment: 2,
    code: Buffer.from([
      0, 0, 0x80, 0x52,
      0xc0, 3, 0x5f, 0xd6,
    ]),
  },
];

function validate(bytes, profile) {
  expect(bytes.length === profile.pageSize, `${profile.name}: image size`);
  expect(u32(bytes, 0) === 0xfeedfacf, `${profile.name}: MH_MAGIC_64`);
  expect(u32(bytes, 4) === profile.cpuType, `${profile.name}: CPU type`);
  expect(u32(bytes, 8) === profile.cpuSubtype, `${profile.name}: CPU subtype`);
  expect(u32(bytes, 12) === 2, `${profile.name}: MH_EXECUTE`);
  expect(u32(bytes, 16) === 5, `${profile.name}: load-command count`);
  expect(u32(bytes, 20) === 304, `${profile.name}: load-command bytes`);
  expect(u32(bytes, 24) === 0x200085, `${profile.name}: Mach header flags`);
  expect(u32(bytes, 28) === 0, `${profile.name}: reserved header field`);

  const pagezero = 32;
  expect(u32(bytes, pagezero) === 0x19, `${profile.name}: pagezero command`);
  expect(u32(bytes, pagezero + 4) === 72, `${profile.name}: pagezero size`);
  expect(fixedName(bytes, pagezero + 8) === "__PAGEZERO", `${profile.name}: pagezero name`);
  expect(u64(bytes, pagezero + 24) === 0n, `${profile.name}: pagezero address`);
  expect(u64(bytes, pagezero + 32) === 0x100000000n, `${profile.name}: pagezero size`);
  expect(u64(bytes, pagezero + 40) === 0n, `${profile.name}: pagezero file offset`);
  expect(u64(bytes, pagezero + 48) === 0n, `${profile.name}: pagezero file size`);
  expect(u32(bytes, pagezero + 56) === 0, `${profile.name}: pagezero max protection`);
  expect(u32(bytes, pagezero + 60) === 0, `${profile.name}: pagezero protection`);
  expect(u32(bytes, pagezero + 64) === 0, `${profile.name}: pagezero sections`);

  const text = 104;
  expect(u32(bytes, text) === 0x19, `${profile.name}: text command`);
  expect(u32(bytes, text + 4) === 152, `${profile.name}: text command size`);
  expect(fixedName(bytes, text + 8) === "__TEXT", `${profile.name}: text segment name`);
  expect(u64(bytes, text + 24) === 0x100000000n, `${profile.name}: text address`);
  expect(u64(bytes, text + 32) === BigInt(profile.pageSize), `${profile.name}: text VM size`);
  expect(u64(bytes, text + 40) === 0n, `${profile.name}: text file offset`);
  expect(u64(bytes, text + 48) === BigInt(profile.pageSize), `${profile.name}: text file size`);
  expect(u32(bytes, text + 56) === 5, `${profile.name}: text max protection`);
  expect(u32(bytes, text + 60) === 5, `${profile.name}: text protection`);
  expect(u32(bytes, text + 64) === 1, `${profile.name}: text section count`);

  const section = text + 72;
  expect(fixedName(bytes, section) === "__text", `${profile.name}: section name`);
  expect(fixedName(bytes, section + 16) === "__TEXT", `${profile.name}: section segment`);
  expect(u64(bytes, section + 32) === 0x100000200n, `${profile.name}: section address`);
  expect(u64(bytes, section + 40) === BigInt(profile.code.length), `${profile.name}: section size`);
  const sectionOffset = u32(bytes, section + 48);
  expect(sectionOffset === 512, `${profile.name}: section offset`);
  expect(u32(bytes, section + 52) === profile.alignment, `${profile.name}: section alignment`);
  expect(u32(bytes, section + 56) === 0, `${profile.name}: relocation offset`);
  expect(u32(bytes, section + 60) === 0, `${profile.name}: relocation count`);
  expect(u32(bytes, section + 64) === 0x80000400, `${profile.name}: section flags`);
  expect(u32(bytes, section + 68) === 0, `${profile.name}: section reserved1`);
  expect(u32(bytes, section + 72) === 0, `${profile.name}: section reserved2`);
  expect(u32(bytes, section + 76) === 0, `${profile.name}: section reserved3`);

  const dylinker = 256;
  expect(u32(bytes, dylinker) === 0x0e, `${profile.name}: LC_LOAD_DYLINKER`);
  expect(u32(bytes, dylinker + 4) === 32, `${profile.name}: dylinker command size`);
  expect(u32(bytes, dylinker + 8) === 12, `${profile.name}: dylinker path offset`);
  expect(
    bytes.subarray(dylinker + 12, dylinker + 26).equals(Buffer.from("/usr/lib/dyld\0")),
    `${profile.name}: dylinker path`,
  );
  expect(bytes.subarray(dylinker + 26, dylinker + 32).every((byte) => byte === 0), `${profile.name}: dylinker padding`);

  const version = 288;
  expect(u32(bytes, version) === 0x32, `${profile.name}: LC_BUILD_VERSION`);
  expect(u32(bytes, version + 4) === 24, `${profile.name}: version command size`);
  expect(u32(bytes, version + 8) === 1, `${profile.name}: macOS platform`);
  expect(u32(bytes, version + 12) === 0x0b0000, `${profile.name}: minimum OS`);
  expect(u32(bytes, version + 16) === 0x0b0000, `${profile.name}: SDK contract`);
  expect(u32(bytes, version + 20) === 0, `${profile.name}: tool count`);

  const main = 312;
  expect(u32(bytes, main) === 0x80000028, `${profile.name}: LC_MAIN`);
  expect(u32(bytes, main + 4) === 24, `${profile.name}: main command size`);
  const entryOffset = u64(bytes, main + 8);
  expect(entryOffset === 512n, `${profile.name}: entry offset`);
  expect(u64(bytes, main + 16) === 0n, `${profile.name}: stack size`);

  let commandOffset = 32;
  for (let index = 0; index < 5; index += 1) {
    const commandSize = u32(bytes, commandOffset + 4);
    expect(commandSize >= 8 && commandSize % 8 === 0, `${profile.name}: aligned command ${index}`);
    commandOffset += commandSize;
  }
  expect(commandOffset === 336, `${profile.name}: command traversal end`);
  expect(Number(entryOffset) === sectionOffset, `${profile.name}: entry is not section start`);
  expect(
    bytes.subarray(sectionOffset, sectionOffset + profile.code.length).equals(profile.code),
    `${profile.name}: entry instructions`,
  );
  expect(
    bytes.subarray(sectionOffset + profile.code.length).every((byte) => byte === 0),
    `${profile.name}: nonzero image padding`,
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
  fail("usage: macho64-check.mjs X86_64.macho AARCH64.macho");
}

for (let index = 0; index < profiles.length; index += 1) {
  const bytes = fs.readFileSync(process.argv[index + 2]);
  const profile = profiles[index];
  validate(bytes, profile);
  mutationMustFail(bytes, profile, "magic", (image) => image.writeUInt32LE(0, 0));
  mutationMustFail(bytes, profile, "CPU", (image) => image.writeUInt32LE(0, 4));
  mutationMustFail(bytes, profile, "command size", (image) => image.writeUInt32LE(70, 36));
  mutationMustFail(bytes, profile, "section offset", (image) => image.writeUInt32LE(1024, 224));
  mutationMustFail(bytes, profile, "entry offset", (image) => image.writeBigUInt64LE(1024n, 320));
}

console.log("PASS: Mach-O 64 headers, CPUs, commands, entry code, layout, and mutations");
