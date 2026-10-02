// Builds Stylus's storage.local contents (the browser-extension-data/<id>/
// storage.js file) from catppuccin's Stylus export. See ../catppuccin-userstyles.nix
// for why the styles are written out fully compiled.
//
// usage: node build-storage.mjs <dir with Stylus js/*> <import.json> <std/v1.less> <out> <pins json>
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';

const [, , jsDir, importJson, libLess, outFile, pinsJson] = process.argv;
const pins = JSON.parse(pinsJson);

// --- run Stylus's own compiler outside the browser ---------------------------
// worker.js is Stylus's web worker script: it expects `self`, `importScripts`,
// and (through less.js) an XMLHttpRequest for @import.
// Running the shipped files, rather than a reimplementation, keeps the output
// identical to what Stylus itself builds on install.
const g = globalThis;
g.self = g;
g.window = g;
g.location = { href: 'https://userstyles.catppuccin.com/', pathname: '/' };
const LIB_URL_SUFFIX = '/lib/std/v1.less';
g.XMLHttpRequest = class {
  open(_method, url) {
    this.url = url;
  }
  setRequestHeader() {}
  getResponseHeader() {
    return null;
  }
  send() {
    // Every catppuccin style @imports this one file, and it imports nothing.
    // Anything else being fetched means upstream changed shape: fail the build
    // rather than silently emitting styles with a missing library.
    if (!this.url.endsWith(LIB_URL_SUFFIX)) {
      throw new Error(`unexpected @import fetch: ${this.url}`);
    }
    this.status = 200;
    this.responseText = fs.readFileSync(libLess, 'utf8');
    this.readyState = 4;
    queueMicrotask(() => this.onreadystatechange?.());
  }
};
g.importScripts = (...names) => {
  for (const name of names) {
    vm.runInThisContext(fs.readFileSync(`${jsDir}/${name}`, 'utf8'), { filename: name });
  }
};
// worker.js is a MessagePort worker: it registers `onmessage`, and a message
// carrying `data.id` is answered once on `ports[0]` with `{ id, res, err }`.
// worker.js idles itself out with `close()` after a job; there is no worker to close here.
g.close = () => {};
g.importScripts('worker.js');
let nextJobId = 0;
const compileUsercss = (code, preprocessor, vars) =>
  new Promise((resolve, reject) => {
    const id = ++nextJobId;
    const port = {
      postMessage({ res, err }) {
        if (err) reject(err[0]);
        else resolve(res);
      },
    };
    g.onmessage({
      data: { id, args: ['compileUsercss', code, preprocessor, vars] },
      ports: [port],
    });
  });

// --- the same three knobs as uncenter/catppuccin-userstyles-customizer -------
// The export's first element is `{ settings }`, Stylus's prefs blob. Those
// live in storage.sync, which can't be written from here, so it's dropped.
// Upstream bug: pronouns.cc and Google Drive have a few `--x: #lib.rgbify(@c);`
// lines missing the `[]` lookup that every sibling line has. The less in
// Stylus >= 2.4.14 (4.9) rejects a mixin call used as a property value
// ("Rulesets cannot be evaluated on a property"); older less let it through.
// Adding the `[]` is what upstream plainly meant, so do that rather than drop
// the style. Drop this once upstream fixes the export.
const fixRgbifyLookups = (code) => code.replace(/(:\s*#lib\.rgbify\([^)]*\))(\s*;)/g, '$1[]$2');

const styles = JSON.parse(fs.readFileSync(importJson, 'utf8')).filter((e) => e.usercssData);

const uuidFor = (namespace) => {
  const h = createHash('sha256').update(namespace).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};

// Stylus's fallback DB backend (background/db-chrome-storage.js) keeps each
// style under `style-<id>`; `dbInChromeStorage` switches it on.
const out = { dbInChromeStorage: true };
for (const [i, style] of styles.entries()) {
  const vars = style.usercssData.vars;
  for (const [name, value] of Object.entries(pins)) {
    if (vars[name]) vars[name].value = value;
  }
  const [sections] = await compileUsercss(
    fixRgbifyLookups(style.sourceCode),
    style.usercssData.preprocessor,
    structuredClone(vars),
  ).catch((e) => {
    throw new Error(`${style.name}: ${e?.message ?? JSON.stringify(e)}`);
  });
  if (!sections.length) throw new Error(`${style.name}: no sections built`);
  const id = i + 1;
  out[`style-${id}`] = {
    ...style,
    id,
    // Stylus only takes a stored style as-is when it has a string _id and
    // built sections; otherwise it discards it on startup.
    _id: uuidFor(style.usercssData.namespace),
    _rev: 1,
    sections,
  };
}
fs.writeFileSync(outFile, JSON.stringify(out));
// worker.js arms a 5 minute idle timer that would otherwise keep node alive.
process.exit(0);
