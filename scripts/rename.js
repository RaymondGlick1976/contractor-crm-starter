#!/usr/bin/env node
// =============================================
// RENAME THE APP
//   node scripts/rename.js "Summit Field CRM"
//
// Replaces the current app name (stored in package.json → "crm.appName")
// everywhere it appears: page titles, emails, sign-in pages, SQL headers,
// docs. Also swaps the one-letter brand mark on the sign-in pages.
// Safe to run again later with a different name.
// =============================================

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const pkgPath = path.join(ROOT, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));

const newName = (process.argv[2] || '').trim();
if (!newName) {
  console.error('Usage: node scripts/rename.js "Your App Name"');
  process.exit(1);
}

const oldName = (pkg.crm && pkg.crm.appName) || 'YourCRM';
if (oldName === newName) {
  console.log(`App is already named "${newName}". Nothing to do.`);
  process.exit(0);
}

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const oldSlug = slug(oldName);
const newSlug = slug(newName);
const oldMark = oldName.trim()[0].toUpperCase();
const newMark = newName.trim()[0].toUpperCase();

const TEXT_EXT = new Set(['.html', '.js', '.css', '.sql', '.md', '.toml', '.json', '.txt', '.svg']);
const SKIP_DIRS = new Set(['node_modules', '.git', '.netlify']);

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) continue;
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (TEXT_EXT.has(path.extname(entry.name))) out.push(p);
  }
  return out;
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
let touched = 0;

for (const file of walk(ROOT)) {
  if (file === __filename || file === pkgPath) continue;
  const before = fs.readFileSync(file, 'utf8');
  let after = before
    .replace(new RegExp(esc(oldName), 'g'), newName)
    .replace(new RegExp(esc(oldName.toUpperCase()), 'g'), newName.toUpperCase())
    .replace(new RegExp(esc(oldSlug), 'g'), newSlug)
    .replace(new RegExp(esc(oldName.toLowerCase()), 'g'), newName.toLowerCase());
  if (oldMark !== newMark) {
    after = after
      .replace(new RegExp(`<span class="auth-brand-mark">${esc(oldMark)}</span>`, 'g'), `<span class="auth-brand-mark">${newMark}</span>`)
      .replace(new RegExp(`<span class="mark">${esc(oldMark)}</span>`, 'g'), `<span class="mark">${newMark}</span>`);
  }
  if (after !== before) {
    fs.writeFileSync(file, after);
    touched++;
  }
}

pkg.name = newSlug;
pkg.description = pkg.description.replace(oldName, newName);
pkg.crm = { ...(pkg.crm || {}), appName: newName };
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

console.log(`Renamed "${oldName}" → "${newName}" in ${touched} files (plus package.json).`);
console.log('Next: replace public/images/logo-placeholder.svg with your own logo, then commit.');
