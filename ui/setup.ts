#!/usr/bin/env bun
// `5dive ui setup` — interactive password setup for the local dashboard.
//
// Writes ~/.config/5dive/ui.json with an argon2id hash + a random
// session-signing secret. Idempotent — re-running rotates the secret.
//
// Accepts:
//   • interactive TTY: prompts twice (password + confirm), hides input
//   • piped stdin: reads password from stdin (used by tests / automation)

import { randomBytes } from "crypto";
import { loadConfig, saveConfig, CONFIG_FILE } from "./lib/config";

const MIN_PASSWORD_LEN = 8;

async function readPasswordTTY(prompt: string): Promise<string> {
  process.stdout.write(prompt);
  process.stdin.setRawMode?.(true);
  return new Promise((resolve, reject) => {
    let pw = "";
    const handler = (chunk: Buffer) => {
      const s = chunk.toString();
      for (const ch of s) {
        const code = ch.charCodeAt(0);
        if (code === 13 || code === 10) {
          process.stdin.setRawMode?.(false);
          process.stdin.off("data", handler);
          process.stdin.pause();
          process.stdout.write("\n");
          resolve(pw);
          return;
        }
        if (code === 3) { // Ctrl-C
          process.stdin.setRawMode?.(false);
          process.stdout.write("\n");
          reject(new Error("interrupted"));
          return;
        }
        if (code === 127 || code === 8) { // backspace / DEL
          pw = pw.slice(0, -1);
        } else if (code >= 32) {
          pw += ch;
        }
      }
    };
    process.stdin.on("data", handler);
    process.stdin.resume();
  });
}

async function readPasswordStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString().trim();
}

async function promptPassword(): Promise<string> {
  if (!process.stdin.isTTY) {
    const pw = await readPasswordStdin();
    if (pw.length < MIN_PASSWORD_LEN) {
      console.error(`error: password must be at least ${MIN_PASSWORD_LEN} characters`);
      process.exit(2);
    }
    return pw;
  }

  while (true) {
    const pw = await readPasswordTTY("Set 5dive UI password: ");
    if (pw.length < MIN_PASSWORD_LEN) {
      console.error(`  password must be at least ${MIN_PASSWORD_LEN} characters`);
      continue;
    }
    const confirm = await readPasswordTTY("Confirm password:    ");
    if (pw !== confirm) {
      console.error("  passwords don't match");
      continue;
    }
    return pw;
  }
}

async function main() {
  const pw = await promptPassword();
  // Bun.password.hash defaults to argon2id with sensible parameters
  // (memoryCost ~64MiB, timeCost 2, parallelism 1).
  const hash = await Bun.password.hash(pw, "argon2id");
  const sessionSecret = randomBytes(32).toString("base64");

  const cfg = loadConfig();
  cfg.auth = { mode: "password", passwordHash: hash, sessionSecret };
  saveConfig(cfg);

  console.log(`✓ UI auth configured`);
  console.log(`  config: ${CONFIG_FILE}`);
  console.log(`  next:   5dive ui   (you'll be prompted to log in)`);
}

main().catch((e) => {
  console.error(`setup failed: ${(e as Error).message}`);
  process.exit(1);
});
