(() => {
  'use strict';
  const status = document.getElementById('status'), user = document.getElementById('user'), rows = document.getElementById('features');
  const findButton = document.getElementById('find'), userHeading = document.getElementById('user-feature-heading');
  function call(op, body) {
    return new Promise((resolve, reject) => Visualforce.remoting.Manager.invokeAction(window.__ORGLOOM_ADMIN_REMOTE__, op, JSON.stringify(body), (result, event) => {
      if (!event.status) return reject(new Error(event.message || 'Salesforce did not confirm the change.'));
      try { const response = JSON.parse(result); if (response.status !== 200) throw Error(response.data.message); resolve(response.data); } catch (e) { reject(e); }
    }, { escape: false, buffer: false, timeout: 30000 }));
  }
  function error(e) { status.textContent = e.message; }
  let generation = 0, searchGeneration = 0, busy = false, loading = false, features = [], loadedUser = null;
  function render() {
    const selectedUser = user.value;
    userHeading.hidden = !selectedUser;
    rows.replaceChildren();
    for (const f of features) {
      const tr = document.createElement('tr'), label = document.createElement('td');
      label.textContent = f.label; tr.append(label);
      const columns = [['policy', 'enabled']];
      if (selectedUser) columns.push(['grant', 'assigned']);
      for (const [operation, key] of columns) {
        const td = document.createElement('td'), box = document.createElement('input');
        box.type = 'checkbox';
        box.checked = operation === 'grant' && loadedUser !== selectedUser ? false : f[key];
        box.disabled = busy || loading || !f.implemented || (operation === 'grant' && loadedUser !== selectedUser);
        box.setAttribute('aria-label', `${f.label}: ${operation === 'grant' ? 'enabled for user' : 'enabled for org'}`);
        box.addEventListener('change', async () => {
          if (busy || loading) { box.checked = !box.checked; return; }
          const enabled = box.checked;
          busy = true; user.disabled = true; findButton.disabled = true;
          rows.querySelectorAll('input').forEach(el => el.disabled = true);
          try {
            const body = { capability: f.id, enabled };
            if (operation === 'grant') body.userId = selectedUser;
            await call(operation, body);
            f[key] = enabled;
            status.textContent = 'Saved. Existing Salesforce permissions still apply.';
          } catch (e) { error(e); }
          finally {
            busy = false; user.disabled = false; findButton.disabled = false;
            await refresh();
          }
        });
        td.append(box); tr.append(td);
      }
      rows.append(tr);
    }
  }
  async function refresh() {
    const own = ++generation, selectedUser = user.value;
    loading = true; render();
    try {
      const result = await call('features', selectedUser ? { userId: selectedUser } : {});
      if (own !== generation) return;
      features = result.sort((a, b) => a.label.localeCompare(b.label));
      loadedUser = selectedUser;
    } catch (e) {
      if (own === generation) { loadedUser = null; error(e); }
    } finally {
      if (own === generation) { loading = false; render(); }
    }
  }
  async function find() {
    if (busy) return;
    const own = ++searchGeneration;
    status.textContent = 'Loading users…';
    const users = await call('users', { search: document.getElementById('search').value });
    if (own !== searchGeneration || busy) return;
    user.replaceChildren();
    const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = 'Select a user'; user.append(placeholder);
    for (const u of users) {
      const option = document.createElement('option'); option.value = u.Id; option.textContent = `${u.Name} (${u.Username})`; user.append(option);
    }
    status.textContent = users.length ? '' : 'No active users match.';
    await refresh();
  }
  findButton.addEventListener('click', () => find().catch(error));
  user.addEventListener('change', () => refresh());
  document.getElementById('search').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); find().catch(error); } });
  refresh();
  find().catch(error);
})();
