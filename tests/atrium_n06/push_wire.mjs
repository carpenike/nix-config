import { createECDH } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

// This is the fixture receiver, using the sender's existing locked RFC8188 library.
const require = createRequire(import.meta.url);
const ece = require('./node_modules/http_ece/ece.js');
try {
  const input = JSON.parse(readFileSync(0, 'utf8'));
  const receiver = createECDH('prime256v1');
  receiver.setPrivateKey(Buffer.from(input.private_key, 'base64'));
  const bytes = ece.decrypt(Buffer.from(input.body, 'base64'), {
    version: 'aes128gcm',
    privateKey: receiver,
    authSecret: Buffer.from(input.auth, 'base64'),
  });
  const body = JSON.parse(bytes.toString('utf8'));
  process.stdout.write(JSON.stringify({ ok: true, body }));
} catch {
  process.stdout.write(JSON.stringify({ ok: false }));
  process.exitCode = 1;
}
