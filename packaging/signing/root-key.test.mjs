// Tests the pure crypto/format block of root-key.html under Node 22 WebCrypto, then cross-checks with OpenSSL 3.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "root-key.html"), "utf8");
const script = html.split("<script>")[1].split("</script>")[0];
const pure = script.split("// >>> pure")[1].split("// <<< pure")[0];
const names = "DEFAULT_UPDATE_KEY b64 unb64 hex sha256hex toPem fromPem ed25519Supported createMasterKey loadMasterKey importUpdateKey parseRevokedIds signingKeyJson revokedJson buildPublicFile".split(" ");
const P = new Function(pure.split("\n").slice(1).join("\n") + `\nreturn {${names.join(",")}};`)();

const dir = mkdtempSync(join(tmpdir(), "rootkey-"));
const f = n => join(dir, n);
let fails = 0;
const check = (name, ok, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${name}${extra ? "  " + extra : ""}`); if (!ok) fails++; };
const throwsAsync = async fn => { try { await fn(); return false; } catch { return true; } };
const ossl = (...a) => spawnSync("openssl", a, { encoding: "utf8" });
const verify = (pub, data, sig) => { const r = ossl("pkeyutl", "-verify", "-pubin", "-inkey", pub, "-rawin", "-in", data, "-sigfile", sig); return (r.stdout + r.stderr).trim(); };
const derSha = (args) => execFileSync("sh", ["-c", `openssl pkey ${args} -outform DER | sha256sum | cut -d' ' -f1`], { encoding: "utf8" }).trim();

// --- static checks on the page ---
new vm.Script(script); // whole page script parses
check("page script parses", true);
check("page has no network/storage APIs",
  !/(https?:|src=|<link|fetch\(|XMLHttpRequest|WebSocket|localStorage|sessionStorage|indexedDB|sendBeacon|<img|@import)/i.test(html.replace(/<meta http-equiv[^>]+>/, "")) && !/\burl\(/.test(html)); // CSS url( only; createObjectURL( is the download
check("CSP meta present", html.includes(`default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'`));
check("page under 400 lines", html.split("\n").length <= 400, `(${html.split("\n").length})`);

// --- create + bundle ---
check("Ed25519 supported in Node", await P.ed25519Supported());
const m = await P.createMasterKey();
writeFileSync(f("priv.pem"), m.privatePem);
writeFileSync(f("root.pem"), m.publicPem);
const pemLinesOk = pem => pem.split("\n").filter(l => l && !l.startsWith("-----")).every((l, i, a) => i === a.length - 1 ? l.length <= 64 : l.length === 64);
check("private key is PKCS#8 PEM, 64-char lines", m.privatePem.startsWith("-----BEGIN PRIVATE KEY-----\n") && m.privatePem.endsWith("-----END PRIVATE KEY-----\n") && pemLinesOk(m.privatePem));
check("root public key is SPKI PEM", m.publicPem.startsWith("-----BEGIN PUBLIC KEY-----\n") && pemLinesOk(m.publicPem));

const now = Date.UTC(2026, 10, 7, 12, 0, 0);
const revokedIn = "AAAA".repeat(16) + "\n\n" + "b".repeat(64) + "\n";
const bundle = JSON.parse(await P.buildPublicFile(m, await P.importUpdateKey(P.DEFAULT_UPDATE_KEY), "365", "3", revokedIn, now));
check("bundle has exactly the 6 fields", JSON.stringify(Object.keys(bundle)) === JSON.stringify(["root_pubkey_pem", "root_fingerprint", "signing_key_json_b64", "signing_key_sig_b64", "revoked_json_b64", "revoked_sig_b64"]));

const sk = Buffer.from(bundle.signing_key_json_b64, "base64");
const skSig = Buffer.from(bundle.signing_key_sig_b64, "base64");
const rv = Buffer.from(bundle.revoked_json_b64, "base64");
const rvSig = Buffer.from(bundle.revoked_sig_b64, "base64");
writeFileSync(f("bundle-root.pem"), bundle.root_pubkey_pem);
writeFileSync(f("signing-key.json"), sk); writeFileSync(f("signing-key.sig"), skSig);
writeFileSync(f("revoked.json"), rv); writeFileSync(f("revoked.sig"), rvSig);
writeFileSync(f("signing.pem"), P.DEFAULT_UPDATE_KEY);
check("signatures are 64 bytes, base64 padded std", skSig.length === 64 && rvSig.length === 64 && /^[A-Za-z0-9+/]+={0,2}$/.test(bundle.signing_key_sig_b64) && bundle.signing_key_sig_b64.length === 88);

const keyIdOssl = derSha(`-pubin -in ${f("signing.pem")}`);
const expectSk = `{"format":1,"kind":"5dive-signing-key","key_id":"${keyIdOssl}","pubkey":${JSON.stringify(P.DEFAULT_UPDATE_KEY)},"not_after":${Math.floor(now / 1000) + 365 * 86400}}`;
check("signing-key.json exact bytes (order, compact, not_after int)", sk.toString("utf8") === expectSk, `\n      ${sk.toString("utf8")}`);
check("revoked.json exact bytes (lowercased, deduped)", rv.toString("utf8") === `{"format":1,"kind":"5dive-revocations","serial":3,"revoked":["${"a".repeat(64)}","${"b".repeat(64)}"]}`, `\n      ${rv.toString("utf8")}`);
const empty = JSON.parse(await P.buildPublicFile(m, await P.importUpdateKey(P.DEFAULT_UPDATE_KEY), 365, 1, "", now));
check("default revoked.json is empty list", Buffer.from(empty.revoked_json_b64, "base64").toString() === `{"format":1,"kind":"5dive-revocations","serial":1,"revoked":[]}`);

// --- OpenSSL cross-checks ---
const v1 = verify(f("bundle-root.pem"), f("signing-key.json"), f("signing-key.sig"));
check("openssl verifies signing-key.json", v1 === "Signature Verified Successfully", `(${v1})`);
const v2 = verify(f("bundle-root.pem"), f("revoked.json"), f("revoked.sig"));
check("openssl verifies revoked.json", v2 === "Signature Verified Successfully", `(${v2})`);
check("key_id == sha256(openssl SPKI DER of signing key)", JSON.parse(sk).key_id === keyIdOssl, keyIdOssl);
check("root_fingerprint == sha256(openssl SPKI DER of root)", bundle.root_fingerprint === derSha(`-pubin -in ${f("root.pem")}`) && bundle.root_fingerprint === m.fingerprint);
const derived = ossl("pkey", "-in", f("priv.pem"), "-pubout").stdout;
check("openssl imports PKCS#8 and -pubout == root pubkey PEM", derived === m.publicPem && derived === bundle.root_pubkey_pem);

// --- negative controls ---
const tampered = Buffer.from(sk); tampered[tampered.length - 2] ^= 0x01;
writeFileSync(f("tampered.json"), tampered);
const v3 = verify(f("bundle-root.pem"), f("tampered.json"), f("signing-key.sig"));
check("NEG: one-byte change in signing-key.json fails openssl verify", v3 !== "Signature Verified Successfully" && /Failure/i.test(v3), `(${v3.split("\n")[0]})`);
const tamperedR = Buffer.from(rv); tamperedR[5] ^= 0x01; writeFileSync(f("tamperedR.json"), tamperedR);
check("NEG: one-byte change in revoked.json fails openssl verify", verify(f("bundle-root.pem"), f("tamperedR.json"), f("revoked.sig")) !== "Signature Verified Successfully");

// --- "I already have a master key" ---
const again = await P.loadMasterKey(m.privatePem);
check("reload own PEM -> same fingerprint", again.fingerprint === m.fingerprint && again.publicPem === m.publicPem);
const crlf = await P.loadMasterKey("  \r\n" + m.privatePem.replace(/\n/g, "\r\n") + "\r\n\r\n");
check("reload CRLF/whitespace-wrapped PEM -> same fingerprint", crlf.fingerprint === m.fingerprint);
execFileSync("openssl", ["genpkey", "-algorithm", "ed25519", "-out", f("ossl.pem")]);
const om = await P.loadMasterKey(readFileSync(f("ossl.pem"), "utf8"));
check("openssl-generated key loads, fingerprint matches openssl", om.fingerprint === derSha(`-in ${f("ossl.pem")} -pubout`));
const ob = JSON.parse(await P.buildPublicFile(om, await P.importUpdateKey(P.DEFAULT_UPDATE_KEY), 30, 2, "", now));
writeFileSync(f("o.json"), Buffer.from(ob.signing_key_json_b64, "base64")); writeFileSync(f("o.sig"), Buffer.from(ob.signing_key_sig_b64, "base64"));
check("loaded key's signature verifies with openssl's own copy of that key", ossl("pkeyutl", "-verify", "-inkey", f("ossl.pem"), "-rawin", "-in", f("o.json"), "-sigfile", f("o.sig")).stdout.trim() === "Signature Verified Successfully");

// --- input validation ---
check("update key: CRLF + surrounding whitespace normalised", (await P.importUpdateKey("\r\n " + P.DEFAULT_UPDATE_KEY.trim().replace(/\n/g, "\r\n") + "\r\n\r\n")).pem === P.DEFAULT_UPDATE_KEY);
execFileSync("openssl", ["genpkey", "-algorithm", "x25519", "-out", f("x.pem")]);
execFileSync("openssl", ["genpkey", "-algorithm", "rsa", "-pkeyopt", "rsa_keygen_bits:1024", "-out", f("rsa.pem")]);
const xPub = ossl("pkey", "-in", f("x.pem"), "-pubout").stdout, rsaPub = ossl("pkey", "-in", f("rsa.pem"), "-pubout").stdout;
check("NEG: X25519 public key rejected as update key", await throwsAsync(() => P.importUpdateKey(xPub)));
check("NEG: RSA public key rejected as update key", await throwsAsync(() => P.importUpdateKey(rsaPub)));
check("NEG: garbage / truncated PEM rejected", await throwsAsync(() => P.importUpdateKey("hello")) && await throwsAsync(() => P.importUpdateKey(P.DEFAULT_UPDATE_KEY.slice(0, 60))) && await throwsAsync(() => P.importUpdateKey("note\n" + P.DEFAULT_UPDATE_KEY)));
check("NEG: private key rejected as master if wrong type (X25519)", await throwsAsync(() => P.loadMasterKey(readFileSync(f("x.pem"), "utf8"))));
check("NEG: bad revoked id rejected", await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 365, 1, "abc", now)));
check("NEG: days 0 / 1.5 / 99999 rejected", await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 0, 1, "", now)) && await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 1.5, 1, "", now)) && await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 99999, 1, "", now)));
check("NEG: serial 0 rejected", await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 365, 0, "", now)));
check("NEG: master key refused as its own update key", await throwsAsync(async () => P.buildPublicFile(m, await P.importUpdateKey(m.publicPem), 365, 1, "", now)));
check("NEG: revoking the key being approved refused", await throwsAsync(() => P.buildPublicFile(m, { pem: P.DEFAULT_UPDATE_KEY, keyId: keyIdOssl }, 365, 1, keyIdOssl, now)));

rmSync(dir, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : "\nALL PASS");
process.exit(fails ? 1 : 0);
