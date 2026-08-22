// Build-time half of vscode-vibrancy-continued.
//
// Called from the derivation's postFixup with the (still writable) app/out
// directory and a checkout of the extension. It does what the extension's
// activate() does to the two files that matter on Linux, by calling the
// extension's OWN transforms rather than reimplementing the regexes -- those
// anchors move with VS Code releases and a private copy would silently rot.
//
// Linux deliberately gets less than Windows/macOS: no runtime import, no
// injectVisualEffectState (macOS-only), no native addon. Transparency on Linux
// is purely `frame:false,transparent:true` on the BrowserWindow plus a
// compositor that blurs behind it, so the parts of the extension that need the
// live `vscode` API -- and therefore cannot run at build time -- are not needed.
//
// Usage: node vibrancy-patch.cjs <app dir> <vibrancy checkout>
//
// <app dir> is resources/app -- the parent of out/, because product.json (which
// lives beside out/) has to be rewritten too. See the checksum note below.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [appRoot, vibrancySrc] = process.argv.slice(2);

if (!appRoot || !vibrancySrc) {
  console.error('usage: vibrancy-patch.cjs <appRoot> <vibrancySrc>');
  process.exit(1);
}

const appDir = path.join(appRoot, 'out');
const productJsonPath = path.join(appRoot, 'product.json');

const { injectElectronOptions, patchCSP } = require(
  path.join(vibrancySrc, 'extension', 'file-transforms.js')
);

// Fail loudly rather than silently producing an unpatched VS Code: a build that
// "succeeds" without transparency is worse than one that stops and says why.
function die(msg) {
  console.error(`vibrancy-patch: ${msg}`);
  process.exit(1);
}

// --- Resolve the target files -------------------------------------------
//
// Mirrors extension/index.js activate(): electron-main/main.js merged into the
// top-level main.js in newer builds, and 1.102 renamed electron-sandbox to
// electron-browser. Both are probed rather than assumed.

const JSFile = path.join(appDir, 'main.js');
if (!fs.existsSync(JSFile)) die(`no main.js under ${appDir}`);

let ElectronJSFile = path.join(appDir, 'vs/code/electron-main/main.js');
if (!fs.existsSync(ElectronJSFile)) ElectronJSFile = JSFile;

const htmlCandidates = [
  'vs/code/electron-sandbox/workbench/workbench.html',
  'vs/code/electron-browser/workbench/workbench.html',
  'vs/code/electron-sandbox/workbench/workbench.esm.html',
].map((p) => path.join(appDir, p));

const HTMLFile = htmlCandidates.find((p) => fs.existsSync(p));
if (!HTMLFile) die(`no workbench html under ${appDir}; tried:\n  ${htmlCandidates.join('\n  ')}`);

console.log(`vibrancy-patch: electron js -> ${path.relative(appDir, ElectronJSFile)}`);
console.log(`vibrancy-patch: workbench   -> ${path.relative(appDir, HTMLFile)}`);

// --- 1. Frameless + transparent BrowserWindow ---------------------------

const electronJS = fs.readFileSync(ElectronJSFile, 'utf-8');
const patchedJS = injectElectronOptions(electronJS, {
  frameless: true,
  isMacos: false,
  transparent: true,
});

if (patchedJS === electronJS) {
  die(
    'injectElectronOptions changed nothing. The BrowserWindow anchor no longer ' +
      'matches this VS Code build -- re-check the extension against this version ' +
      'instead of shipping an unpatched editor.'
  );
}
if (!patchedJS.includes('frame:false,transparent:true')) {
  die('injection ran but the expected options are absent from the result');
}

fs.writeFileSync(ElectronJSFile, patchedJS, 'utf-8');
console.log('vibrancy-patch: injected frame:false,transparent:true');

// --- 1b. Stop Electron painting an opaque colour behind the page --------
//
// The same options object also carries `backgroundColor:<opaque hex>` from
// getBackgroundColor(). Electron fills the window with it beneath the rendered
// page, so `transparent:true` on its own composites over a solid colour and
// nothing shows through -- the window is frameless but not see-through.
//
// The extension never hits this because its runtime calls
// window.setBackgroundColor('#00000000') on every dom-ready (runtime/index.mjs).
// That runtime cannot be used here: it reads `global.vscode_vibrancy_plugin`,
// the live-settings blob only the extension host can build. Rewriting the
// literal to a fully transparent ARGB value gets the same result with no
// runtime, and Electron accepts the #AARRGGBB form.
const bgAnchor = 'backgroundColor:r.getBackgroundColor()';
const withClearBg = patchedJS.replace(bgAnchor, "backgroundColor:'#00000000'");

if (withClearBg === patchedJS) {
  die(
    `could not find ${bgAnchor}. Electron would paint an opaque colour behind ` +
      'the page and the window would not be see-through; re-check this anchor ' +
      'against the current VS Code build.'
  );
}

fs.writeFileSync(ElectronJSFile, withClearBg, 'utf-8');
console.log('vibrancy-patch: cleared the opaque window backgroundColor');

// --- 2. Trusted-types CSP -----------------------------------------------
//
// The workbench HTML restricts which trusted-types policies may be created.
// Kept even though this build does not inject the runtime: without it any
// later user CSS/JS injection through the same policy name is refused, and it
// is inert when unused.

const html = fs.readFileSync(HTMLFile, 'utf-8');
const csp = patchCSP(html);

if (csp.noMetaTag) die(`no CSP meta tag in ${HTMLFile}`);
if (csp.alreadyPatched) {
  console.log('vibrancy-patch: CSP already carries the policy');
} else {
  fs.writeFileSync(HTMLFile, csp.result, 'utf-8');
  console.log('vibrancy-patch: added VscodeVibrancyContinued to trusted-types');
}

// --- 3. Re-checksum the workbench HTML ----------------------------------
//
// product.json carries base64(sha256) digests for a handful of files, and
// workbench.html is one of them. VS Code verifies them at startup and shows
// "Your Code installation appears to be corrupt. Please reinstall." when one
// does not match -- which editing the CSP guarantees.
//
// The extension never has to deal with this: it patches an installation the
// user already accepted, and the nag is dismissible. A derivation should not
// ship an editor that greets you with a corruption warning on every launch, so
// the digest is recomputed here. Padding is stripped because that is the form
// product.json stores.
const digest = (file) =>
  crypto.createHash('sha256').update(fs.readFileSync(file)).digest('base64').replace(/=+$/, '');

const product = JSON.parse(fs.readFileSync(productJsonPath, 'utf-8'));
const checksums = product.checksums || {};
const htmlKey = path.relative(appDir, HTMLFile);

if (!(htmlKey in checksums)) {
  // Not fatal: older builds did not checksum this file. Worth saying out loud
  // rather than silently skipping, in case the key was merely renamed.
  console.log(`vibrancy-patch: no checksum entry for ${htmlKey}, nothing to update`);
} else {
  const before = checksums[htmlKey];
  const after = digest(HTMLFile);
  if (before !== after) {
    checksums[htmlKey] = after;
    product.checksums = checksums;
    fs.writeFileSync(productJsonPath, JSON.stringify(product, null, '\t') + '\n', 'utf-8');
    console.log(`vibrancy-patch: rechecksummed ${htmlKey}`);
  }
}
