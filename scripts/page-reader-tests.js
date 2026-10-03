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
article.innerText = 'x'.repeat(25000) + '\nMorgan Example plays soccer in Harbour NSW.';
assert.match(JSON.parse(vm.runInNewContext(script, { document, location: { href: page.url } })).text, /Morgan Example/,
  'Names beyond the former 20,000-character cutoff remain readable');
document.body = {innerText: 'A separate introductory article.\n' + article.innerText, querySelectorAll: () => []};
document.querySelector = () => ({innerText: 'First unrelated article. '.repeat(30), querySelectorAll: () => []});
assert.match(JSON.parse(vm.runInNewContext(script, {document, location: {href: page.url}})).text, /Morgan Example/,
  'A first article must not hide later articles or page captions');
console.log('Public-page extraction, navigable links, deduplication and text bounds passed');
const searchScript = source.match(/private static let searchExtractor = #"""([\s\S]*?)"""#/)[1];
const heading = (title, href, summary = '') => ({innerText: title, closest: () => ({href}), parentElement: {innerText: title + '\n' + summary, parentElement: null}});
const searchDocument = {
  title: 'Search results',
  querySelectorAll: () => [
    heading('Jane Example — clinic', 'https://clinic.example/jane'),
    heading('Duplicate', 'https://clinic.example/jane'),
    heading('Publications', 'https://www.google.com/url?q=https%3A%2F%2Fjournal.example%2Fjane'),
    heading('Search help', 'https://www.google.com/search?q=help'),
    heading('Unsafe', 'javascript:alert(1)'),
    heading('File', 'file:///private/data'),
  ]
};
const search = JSON.parse(vm.runInNewContext(searchScript, {document: searchDocument, location: {href: 'https://www.google.com/search?q=Jane'}, URL}));
assert.deepEqual(search.links, [
  {title: 'Jane Example — clinic', url: 'https://clinic.example/jane'},
  {title: 'Publications', url: 'https://journal.example/jane'},
]);
searchDocument.querySelectorAll = () => [heading('Harbour United launches soccer teams', 'https://news.example/soccer', 'Morgan Example practises with Harbour United.')];
const captionResult = JSON.parse(vm.runInNewContext(searchScript, {document: searchDocument, location: {href: 'https://www.google.com/search'}, URL}));
assert.match(captionResult.links[0].summary || '', /Morgan Example/);
searchDocument.querySelectorAll = () => [];
assert.equal(JSON.parse(vm.runInNewContext(searchScript, {document: searchDocument, location: {href: 'https://www.google.com/search'}, URL})).links.length, 0);
console.log('Rendered search extraction, redirects, duplicate and non-web URL rejection passed');
