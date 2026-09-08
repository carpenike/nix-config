import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

// Native helpers retain their networking; only fixture console output is suppressed.
console.log = () => {};
console.warn = () => {};
console.error = () => {};
const { callAnthropic } = await import('./runtime/server/lib/anthropic.js');
const { generateImageBytes, fetchReferenceImage } = await import('./runtime/server/lib/image-gen.js');
const { getConfiguration } = await import('./runtime/server/lib/oidc.js');
const { PartifulFirebaseClient } = await import('./runtime/server/integrations/partiful-firebase.js');
const { getPlexMachineId } = await import('./runtime/server/lib/plex.js');

const reply = (body) => process.stdout.write(JSON.stringify({ pid: process.pid, uid: process.getuid(), ...body }) + '\n');
const processStatus = readFileSync('/proc/self/status', 'utf8');
reply({
  ready: true, node: process.version,
  direct_anthropic_present: Object.hasOwn(process.env, 'ANTHROPIC_API_KEY'),
  direct_anthropic_model_present: Object.hasOwn(process.env, 'ANTHROPIC_MODEL'),
  capabilities: processStatus.match(/^CapEff:\s+(\w+)/m)?.[1],
  no_new_privileges: processStatus.match(/^NoNewPrivs:\s+(\d+)/m)?.[1],
});
const input = createInterface({ input: process.stdin, terminal: false });
for await (const line of input) {
  const command = JSON.parse(line);
  if (command.action === 'stop') break;
  try {
    if (command.action === 'text') {
      const result = await callAnthropic(
        'Synthetic isolated N06 prompt.',
        [{ role: 'user', content: 'Synthetic egress test only.' }],
        { maxTokens: 27, signal: AbortSignal.timeout(15000) },
      );
      reply({ status: result.status, text: result.text, stop_reason: result.stopReason });
    } else if (command.action === 'image') {
      const reference = command.reference ? await fetchReferenceImage('https://media.atrium.invalid/reference.png') : null;
      const result = await generateImageBytes({ prompt: 'A synthetic square.', provider: command.provider, reference });
      reply({ ok: true, provider: result.provider, mime: result.mime, width: result.width, height: result.height, sha256: createHash('sha256').update(result.bytes).digest('hex') });
    } else if (command.action === 'identity') {
      const { opts } = await getConfiguration();
      reply({ ok: opts.issuer === 'https://identity.atrium.invalid' });
    } else if (command.action === 'partiful') {
      const auth = JSON.parse(readFileSync('/run/atrium-n06/credentials/partiful.json', 'utf8'));
      const client = new PartifulFirebaseClient(auth);
      const result = await client.getEventComments('synthetic-event');
      reply({ ok: result.ok });
    } else if (command.action === 'plex') {
      reply({ ok: (await getPlexMachineId()) === 'synthetic-plex' });
    } else if (command.action === 'reference') {
      const image = await fetchReferenceImage(command.url);
      reply({ ok: true, bytes: image.bytes.length, mime: image.mime });
    } else if (command.action === 'fetch') {
      const response = await fetch(command.url, {
        method: command.method ?? 'GET',
        headers: command.useOpenaiKey ? { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` } : {},
        signal: AbortSignal.timeout(3000),
      });
      await response.arrayBuffer();
      reply({ status: response.status });
    } else throw new Error('unsupported_fixture_action');
  } catch (error) {
    reply({ ok: false, error_type: error.name, error_code: error.code ?? null });
  }
}
input.close();
process.stdin.destroy();
