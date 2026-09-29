import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [registryFile, workspace, mode] = process.argv.slice(2);
const entry = JSON.parse(readFileSync(registryFile, 'utf8'));
const clientId = `nix-rb10-${mode}`;
const channel = 'agenthost-terminal://nix/rb10-smoke';
const socket = new WebSocket(
  `ws://127.0.0.1:${entry.endpoint.port}/?tkn=${encodeURIComponent(entry.connectionToken)}`,
);
const deadline = setTimeout(() => {
  console.error('AHP smoke test timed out');
  process.exit(1);
}, 30000);
let nextId = 0;
const pending = new Map();
socket.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  if (message.error) request.reject(new Error(
    `AHP ${request.method} failed (${message.error.code}): ${message.error.message}`,
  ));
  else request.resolve(message.result);
});
const call = (method, params) => new Promise((resolve, reject) => {
  const id = ++nextId;
  pending.set(id, { resolve, reject, method });
  socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
});
try {
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', () => reject(new Error('WebSocket connection failed')), { once: true });
  });
  const initialized = await call('initialize', {
    channel: 'ahp-root://',
    clientId,
    protocolVersions: ['0.9.0'],
    initialSubscriptions: [],
  });
  assert.equal(initialized.protocolVersion, '0.9.0');
  if (mode === 'dispatch') {
    await call('createTerminal', {
      channel,
      claim: { kind: 'client', clientId },
      cwd: pathToFileURL(workspace).href,
      name: 'RB-10 isolated compatibility fixture',
      cols: 100,
      rows: 30,
    });
    await call('subscribe', { channel });
    socket.send(JSON.stringify({
      jsonrpc: '2.0',
      method: 'dispatchAction',
      params: {
        channel,
        clientSeq: 1,
        action: {
          type: 'terminal/input',
          data: 'id -u; uname -s; sleep 2; python3 coding_task.py\r',
        },
      },
    }));
    await call('ping', { channel: 'ahp-root://' });
  } else if (mode === 'reconnect') {
    const snapshot = await call('subscribe', { channel });
    assert.match(JSON.stringify(snapshot), /NATIVE_TASK_OK/);
    await call('disposeTerminal', { channel });
  } else {
    const sessions = await call('listSessions', { channel: 'ahp-root://' });
    assert.deepEqual(sessions.items, []);
  }
  socket.close();
  await new Promise((resolve) => socket.addEventListener('close', resolve, { once: true }));
  clearTimeout(deadline);
  console.log(`AHP ${mode}: passed`);
} catch (error) {
  const reason = String(error.message).replaceAll(entry.connectionToken, '[redacted]');
  console.error(`AHP ${mode}: failed: ${reason}`);
  socket.close();
  clearTimeout(deadline);
  process.exitCode = 1;
}
