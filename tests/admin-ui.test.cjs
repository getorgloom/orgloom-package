const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { JSDOM } = require('jsdom');
const tick = () => new Promise(resolve => setImmediate(resolve));

function setup(t) {
  const page = fs.readFileSync('force-app/main/default/pages/OrgLoomNativeAdmin.page', 'utf8');
  const dom = new JSDOM(page, { runScripts: 'outside-only' });
  t.after(() => dom.window.close());
  const w = dom.window, pending = [];
  w.Visualforce = { remoting: { Manager: { invokeAction(remote, op, body, callback) {
    pending.push({ op, body: JSON.parse(body), reply(data, status = 200) { callback(JSON.stringify({ status, data }), { status: true }); } });
  } } } };
  w.eval(fs.readFileSync('web/admin.js', 'utf8'));
  const take = op => {
    const index = pending.findIndex(request => request.op === op);
    assert.notEqual(index, -1, `Expected ${op} request`);
    return pending.splice(index, 1)[0];
  };
  const select = id => { const user = w.document.getElementById('user'); user.value = id; user.dispatchEvent(new w.Event('change')); };
  const features = (assigned = false) => [
    { id: 'browse-records', label: 'Browse', enabled: true, assigned, implemented: true },
    { id: 'future', label: 'Future', enabled: true, assigned: false, implemented: false }
  ];
  const cells = () => w.document.querySelector('#features tr').children;
  return { w, take, select, features, cells };
}

test('org settings load without users and remain editable when search has no matches', async t => {
  const { w, take, features, cells } = setup(t);
  const initial = take('features'); assert.deepEqual(initial.body, {});
  initial.reply(features()); await tick();
  assert.equal(cells().length, 2);
  assert.equal(w.document.getElementById('user-feature-heading').hidden, true);
  assert.doesNotMatch(w.document.querySelector('thead').textContent, /Availability/);
  assert.equal(cells()[1].querySelector('input').disabled, false);
  assert.equal(w.document.querySelectorAll('#features tr')[1].querySelector('input').disabled, true);
  take('users').reply([]); await tick();
  take('features').reply(features()); await tick();
  cells()[1].querySelector('input').click();
  const policy = take('policy');
  assert.deepEqual(policy.body, { capability: 'browse-records', enabled: false });
  policy.reply({ ok: true }); await tick();
  const updated = features(); updated[0].enabled = false;
  take('features').reply(updated); await tick();
  assert.equal(cells()[1].querySelector('input').checked, false);
});

test('user column follows selection, grants target that user, and stale responses cannot replace org settings', async t => {
  const { w, take, select, features, cells } = setup(t);
  take('features').reply(features());
  take('users').reply([{ Id: 'alice', Name: 'Alice', Username: 'alice@example.invalid' }, { Id: 'bob', Name: 'Bob', Username: 'bob@example.invalid' }]);
  await tick(); take('features').reply(features()); await tick();
  select('alice');
  assert.equal(cells().length, 3);
  assert.equal(w.document.getElementById('user-feature-heading').hidden, false);
  assert.equal(cells()[2].querySelector('input').disabled, true);
  const alice = take('features'); assert.deepEqual(alice.body, { userId: 'alice' });
  alice.reply(features()); await tick();
  cells()[2].querySelector('input').click();
  const grant = take('grant'); assert.deepEqual(grant.body, { capability: 'browse-records', enabled: true, userId: 'alice' });
  grant.reply({ ok: true }); await tick(); take('features').reply(features(true)); await tick();
  assert.equal(cells()[2].querySelector('input').checked, true);
  select('bob'); const bob = take('features');
  select(''); const org = take('features');
  assert.equal(cells().length, 2);
  assert.equal(w.document.getElementById('user-feature-heading').hidden, true);
  org.reply(features()); await tick();
  bob.reply(features(true)); await tick();
  assert.equal(cells().length, 2);
  assert.equal(cells()[1].querySelector('input').disabled, false);
});

test('failed user refresh keeps org settings and does not expose stale grants', async t => {
  const { w, take, select, features, cells } = setup(t);
  take('features').reply(features());
  take('users').reply([{ Id: 'alice', Name: 'Alice', Username: 'alice@example.invalid' }]);
  await tick(); take('features').reply(features()); await tick();
  select('alice'); take('features').reply({ message: 'User no longer has access.' }, 400); await tick();
  assert.equal(cells()[1].querySelector('input').disabled, false);
  assert.equal(cells()[2].querySelector('input').disabled, true);
  assert.match(w.document.getElementById('status').textContent, /no longer has access/);
});
