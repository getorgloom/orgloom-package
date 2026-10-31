const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

test('native record requests require a feature grant without any subscription plan', () => {
  const window = { OrgLoom: {} };
  const context = { window };
  vm.runInNewContext(fs.readFileSync('web/platform.js', 'utf8'), context);
  vm.runInNewContext(fs.readFileSync('vendor/upstream/packages/canvas/src/public/js/canvas-cap.js', 'utf8'), context);
  const cap = window.OrgLoom.canvasCap.mount({ canvasState: { bulkRecords: [] }, isRecordModified: () => false, getShareCountByCanvasId: () => new Map(), renderBulkToolbar() {} });
  assert.equal(cap._canAuthorSlots(), false);
  cap.setCaps({ 'create-slot-canvas': false, 'run-script': false });
  assert.equal(cap._canAuthorSlots(), false);
  assert.equal(cap._canRunScripts(), false);
  cap.setCaps({ 'create-slot-canvas': true });
  assert.equal(cap._canAuthorSlots(), true);
  cap.setCaps({ 'create-slot-canvas': false });
  assert.equal(cap._canAuthorSlots(), false);
});
