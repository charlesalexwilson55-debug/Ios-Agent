const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const source = fs.readFileSync('App/Web/PageReader.swift', 'utf8');
const script = source.match(/private static let extractor = #"""([\s\S]*?)"""#/)[1];
const article = { innerText: 'Public profile\n' + 'Readable public information. '.repeat(25), querySelectorAll: () => [] };
const anchors = [
  { innerText: 'Club roster', href: 'https://club.example/roster' },
  { innerText: 'Duplicate', href: 'https://club.example/roster' },
  { innerText: 'Unsafe', href: 'javascript:alert(1)' },
  { innerText: 'Local file', href: 'file:///private/data' },
  { innerText: '', href: 'https://club.example/empty' },
  { innerText: '  Match   report ', href: 'https://news.example/report' },
];
const document = {
  title: 'Player profile', body: article,
  querySelector: () => article,
  querySelectorAll: selector => selector === 'a[href]' ? anchors : [],
};
const page = JSON.parse(vm.runInNewContext(script, { document, location: { href: 'https://club.example/player' } }));
assert.equal(page.title, 'Player profile');
assert.equal(page.url, 'https://club.example/player');
assert.match(page.text, /Readable public information/);
assert.deepEqual(page.links, [
  { title: 'Club roster', url: 'https://club.example/roster' },
  { title: 'Match report', url: 'https://news.example/report' },
]);
article.innerText = 'x'.repeat(25000);
assert.equal(JSON.parse(vm.runInNewContext(script, { document, location: { href: page.url } })).text.length, 20000);
console.log('Public-page extraction, navigable links, deduplication and text bounds passed');
