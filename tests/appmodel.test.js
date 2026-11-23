// Regression tests for the pure helpers in AppModel.js.
//
// Run with: node tests/appmodel.test.js
//
// AppModel is a .pragma library, so it is not loadable as a plain CommonJS
// module. Strip that line and evaluate it in a vm context with a module object,
// which exercises exactly the code the widget runs.
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const vm = require('vm')

const source = fs.readFileSync(path.join(__dirname, '..', 'AppModel.js'), 'utf8')
const sandbox = { module: { exports: {} }, console: console }
vm.runInNewContext(
  source.replace(/^\.pragma library\s*/, '')
    + '\nmodule.exports = { plainText, wheelWindowIndex, windowsFor, normalizeApps, unpinnedRecords }',
  sandbox)
const AppModel = sandbox.module.exports

let passed = 0
function test(name, fn) {
  fn()
  passed++
  console.log('ok - ' + name)
}

// ---------------------------------------------------------------- plainText

test('plainText strips markup-shaped input', () => {
  assert.strictEqual(
    AppModel.plainText('<img src="https://example.invalid/tracker">Firefox'),
    'Firefox')
})

test('plainText leaves no angle brackets or control characters', () => {
  const result = AppModel.plainText('A <b>bold\u202e</b>\ttitle')
  assert.ok(!/[<>]/.test(result), result)
  assert.ok(!/[\u0000-\u001f\u202a-\u202e]/.test(result), result)
})

test('plainText caps hostile lengths', () => {
  const result = AppModel.plainText('x'.repeat(5000), 40)
  assert.strictEqual(result.length, 40)
  assert.ok(result.endsWith('\u2026'))
})

test('plainText tolerates non-strings', () => {
  assert.strictEqual(AppModel.plainText(null), '')
  assert.strictEqual(AppModel.plainText(undefined), '')
  assert.strictEqual(AppModel.plainText(42), '42')
})

// -------------------------------------------------------- wheelWindowIndex

const windows = [{ address: 'a' }, { address: 'b' }, { address: 'c' }]

test('wheelWindowIndex walks forward and wraps', () => {
  assert.strictEqual(AppModel.wheelWindowIndex(windows, 'b', -1), 2)
  assert.strictEqual(AppModel.wheelWindowIndex(windows, 'c', -1), 0)
})

test('wheelWindowIndex walks backward and wraps', () => {
  assert.strictEqual(AppModel.wheelWindowIndex(windows, 'b', 1), 0)
  assert.strictEqual(AppModel.wheelWindowIndex(windows, 'a', 1), 2)
})

test('wheelWindowIndex starts from an end when nothing is focused', () => {
  assert.strictEqual(AppModel.wheelWindowIndex(windows, '', -1), 0)
  assert.strictEqual(AppModel.wheelWindowIndex(windows, '', 1), 2)
})

test('wheelWindowIndex has nothing to do without windows or delta', () => {
  assert.strictEqual(AppModel.wheelWindowIndex([], 'a', -1), -1)
  assert.strictEqual(AppModel.wheelWindowIndex(windows, 'a', 0), -1)
})

// ---------------------------------------------------------------- matching

test('windowsFor matches the derived desktop-id pattern', () => {
  const records = AppModel.normalizeApps(['code'])
  const matched = AppModel.windowsFor(records[0], [
    { address: '1', appId: 'code', cls: 'Code', title: 'a' },
    { address: '2', appId: 'codes', cls: 'Codes', title: 'b' }
  ])
  assert.strictEqual(matched.map(function(w) { return w.address }).join(','), '1')
})

test('unpinnedRecords skips windows a pin already claims', () => {
  const records = AppModel.normalizeApps(['code'])
  const open = [
    { address: '1', appId: 'code', cls: 'Code', title: 'a' },
    { address: '2', appId: 'firefox', cls: 'firefox', title: 'b' }
  ]
  const unpinned = AppModel.unpinnedRecords(records, open)
  assert.strictEqual(unpinned.map(function(r) { return r.desktopId }).join(','), 'firefox')
})

console.log('\n' + passed + ' tests passed')
