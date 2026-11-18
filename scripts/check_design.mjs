#!/usr/bin/env node
// 디자인시스템 검사(#135). web 은 회사 디자인시스템 sandcorp-design 의 토큰만 쓴다 — 첫 PR(#5)이
// styles.css 에 일반 회색·파란 팔레트를 하드코딩했고, 막는 장치가 없었다.
//   1. web/package.json 에 sandcorp-design 의존성(github: 태그 고정)이 있어야 한다.
//   2. web/src 의 CSS·TS·TSX 에 색 리터럴(hex·rgb()·rgba()·hsl()·hsla())이 없어야 한다. 주석은 보지 않는다.
//      꼭 필요하면 scripts/design-allowlist.txt 에 `경로[:줄] — 까닭` 한 줄.
// 사용: node scripts/check_design.mjs [저장소 루트]   (기본: 이 스크립트의 저장소)
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, relative, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];

// 1. 의존성
const pkgPath = join(root, "web/package.json");
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
const spec = pkg.dependencies?.["sandcorp-design"];
if (!spec) {
  failures.push(
    "web/package.json 에 sandcorp-design 의존성이 없다 — cd web && npm install 'sandcorp-design@github:sandcorporation/sandcorp-design#vX.Y.Z' 로 태그를 고정해 더하라",
  );
} else if (!/^github:sandcorporation\/sandcorp-design#v\d+\.\d+\.\d+$/.test(spec)) {
  failures.push(
    `web/package.json 의 sandcorp-design 이 태그 고정이 아니다(${spec}) — "github:sandcorporation/sandcorp-design#vX.Y.Z" 꼴로 고쳐라`,
  );
}

// 2. 허용 목록
const allowPath = join(root, "scripts/design-allowlist.txt");
const allowFiles = new Set();
const allowLines = new Set();
if (existsSync(allowPath)) {
  readFileSync(allowPath, "utf8")
    .split("\n")
    .forEach((raw, i) => {
      const line = raw.trim();
      if (!line || line.startsWith("#")) return;
      const m = /^(\S+?)(?::(\d+))?\s+—\s+\S/.exec(line);
      if (!m) {
        failures.push(`scripts/design-allowlist.txt:${i + 1} 형식 — \`경로[:줄] — 까닭\` 으로 쓴다(까닭 필수)`);
        return;
      }
      if (m[2]) allowLines.add(`${m[1]}:${m[2]}`);
      else allowFiles.add(m[1]);
    });
}

// 주석을 같은 길이의 공백으로 바꾼다(줄 번호 유지). 문자열 안의 `//`(URL)는 건드리지 않는다.
function stripComments(src, css) {
  let out = "";
  let i = 0;
  let quote = null;
  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    if (quote) {
      out += c;
      if (c === "\\") {
        out += n ?? "";
        i += 2;
        continue;
      }
      if (c === quote || (c === "\n" && quote !== "`")) quote = null;
      i++;
      continue;
    }
    if (c === "/" && n === "*") {
      const end = src.indexOf("*/", i + 2);
      const stop = end === -1 ? src.length : end + 2;
      out += src.slice(i, stop).replace(/[^\n]/g, " ");
      i = stop;
      continue;
    }
    if (!css && c === "/" && n === "/") {
      const end = src.indexOf("\n", i);
      const stop = end === -1 ? src.length : end;
      out += " ".repeat(stop - i);
      i = stop;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") quote = c;
    out += c;
    i++;
  }
  return out;
}

const COLOR = /#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-zA-Z_-])|\b(?:rgba?|hsla?)\(/gi;

function walk(dir) {
  const files = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) files.push(...walk(p));
    else if (/\.(css|ts|tsx)$/.test(name)) files.push(p);
  }
  return files;
}

const srcDir = join(root, "web/src");
for (const file of existsSync(srcDir) ? walk(srcDir).sort() : []) {
  const rel = relative(root, file).split(sep).join("/");
  if (allowFiles.has(rel)) continue;
  const lines = stripComments(readFileSync(file, "utf8"), file.endsWith(".css")).split("\n");
  lines.forEach((line, i) => {
    COLOR.lastIndex = 0;
    if (!COLOR.test(line)) return;
    if (allowLines.has(`${rel}:${i + 1}`)) return;
    failures.push(
      `${rel}:${i + 1} 색 리터럴 — 디자인 토큰(sandcorp-design)을 써라. 꼭 필요하면 scripts/design-allowlist.txt 에 까닭과 함께`,
    );
  });
}

if (failures.length) {
  for (const f of failures) console.error(f);
  process.exit(1);
}
console.log("ok   디자인시스템: sandcorp-design 의존성, web/src 색 리터럴 없음");
