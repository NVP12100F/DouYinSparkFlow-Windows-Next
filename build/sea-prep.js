// Build-time helper: convert core/protocol_sender.mjs to a CJS single file
// for Node SEA, generate sea-config.json. The source file is never touched.
// Usage: node sea-prep.js <source-mjs> <work-dir>
const fs = require("fs");
const path = require("path");

const [srcMjs, workDir] = process.argv.slice(2);
if (!srcMjs || !workDir) {
  console.error("usage: node sea-prep.js <source.mjs> <work-dir>");
  process.exit(1);
}
fs.mkdirSync(workDir, { recursive: true });

let code = fs.readFileSync(srcMjs, "utf8");

// Mechanical ESM -> CJS for the handful of builtin imports used here.
code = code.replace(
  /^import\s+([A-Za-z_$][\w$]*)\s+from\s+"(node:[^"]+)";/gm,
  'const $1 = require("$2");'
);
code = code.replace(
  /^import\s+\{([^}]+)\}\s+from\s+"(node:[^"]+)";/gm,
  "const { $1 } = require(\"$2\");"
);

const remaining = (code.match(/^import\s/mg) || []).length;
if (remaining > 0) {
  console.error(`unconverted import statements remain: ${remaining}`);
  process.exit(1);
}

const cjsPath = path.join(workDir, "protocol-sender.cjs");
fs.writeFileSync(cjsPath, code, "utf8");
console.log("CJS written:", cjsPath, code.length, "bytes");

const seaConfig = {
  main: cjsPath,
  output: path.join(workDir, "sea-prep.blob"),
  disableExperimentalSEAWarning: true,
};
fs.writeFileSync(
  path.join(workDir, "sea-config.json"),
  JSON.stringify(seaConfig, null, 2),
  "utf8"
);
console.log("sea-config.json written");
