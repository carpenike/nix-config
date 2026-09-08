import { readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { runSync, getCachedFeed, getSuggestions, getStatus } from './runtime/server/lib/partiful.js';
import { opsService, getUserBySub, upsertUserOnLogin } from './runtime/server/lib/service.js';
import { OperationCreateSchema } from './runtime/server/lib/types.js';
import { PartifulFirebaseClient } from './runtime/server/integrations/partiful-firebase.js';
import { fetchReferenceImage } from './runtime/server/lib/image-gen.js';
import { verifyNativeAccessIdentity, assertExternalAsConfig } from './runtime/server/lib/resource-server.js';
import { mintCrewSignupToken, deleteSignupToken } from './runtime/server/lib/pocketid-admin.js';
import { refreshCooklangIndex, warmParsedDocCache, fetchCooklangDoc } from './runtime/server/lib/cooklang.js';
import { sendMail } from './runtime/server/lib/mailer.js';
import { webPushChannel, upsertPushSubscription, deletePushSubscription, listPushSubscriptions } from './runtime/server/lib/web-push.js';

const privateInputs = () => JSON.parse(readFileSync('/run/atrium-n06/credentials/features.json', 'utf8'));
const partiful = (bad = false) => {
  const auth = JSON.parse(readFileSync('/run/atrium-n06/credentials/partiful.json', 'utf8'));
  return new PartifulFirebaseClient(bad ? { ...auth, refreshToken: randomBytes(32).toString('hex') } : auth);
};

async function changedEnv(name, value, operation) {
  const previous = process.env[name];
  process.env[name] = value;
  try {
    return await operation();
  } finally {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  }
}

export const featureActions = new Set([
  'calendar-sync', 'firestore-guests', 'firestore-schedule', 'partiful-upload',
  'external-issuer', 'pocketid-admin', 'recipe', 'mail', 'push',
]);

export async function feature(command) {
  if (command.action === 'calendar-sync') {
    if (!opsService.get('n06-linked-op')) {
      opsService.create(OperationCreateSchema.parse({
        title: 'Synthetic linked operation', realDate: '2031-01-01', startTime: '00:00',
        partifulUid: 'n06-linked-event', notes: 'Synthetic notes remain unchanged.',
      }), null, 'n06-linked-op');
      opsService.create(OperationCreateSchema.parse({
        title: 'Synthetic unlinked operation', realDate: '2031-07-02',
      }), null, 'n06-unlinked-op');
    }
    const before = opsService.get('n06-linked-op');
    const run = () => runSync({ logKind: 'manual' });
    const result = command.badCredential
      ? await changedEnv('PARTIFUL_CALENDAR_URL',
        'https://calendar.atrium.invalid/calendar.ics?token=' + randomBytes(32).toString('hex'), run)
      : await run();
    const after = opsService.get('n06-linked-op');
    return {
      ok: result.ok, feed_events: result.feedEvents, field_changes: result.fieldChanges,
      cached_events: getCachedFeed().events.length, suggestions: getSuggestions().length,
      schedule_matches: after.realDate === '2031-07-01' && after.startTime === '18:00',
      protected_fields_unchanged: after.title === before.title && after.notes === before.notes,
      schedule_unchanged: after.realDate === before.realDate && after.startTime === before.startTime,
      persisted_result_matches: getStatus().lastResult?.ok === result.ok,
    };
  }
  if (command.action === 'firestore-guests') {
    const result = await partiful(command.badCredential).getEventGuests(
      command.foreignEvent ? 'foreign-event' : 'synthetic-event',
    );
    return { ok: result.ok, count: result.ok ? result.guests.length : 0,
      going: result.ok && result.guests.every((guest) => guest.rsvpStatus === 'going'),
      reason: result.ok ? null : result.reason };
  }
  if (command.action === 'firestore-schedule') {
    const result = await partiful(command.badCredential).updateEventSchedule(
      command.foreignEvent ? 'foreign-event' : 'synthetic-event',
      new Date('2031-07-03T18:00:00.000Z'),
    );
    return { ok: result.ok, duration_preserved: result.ok
      && result.startDate === '2031-07-03T18:00:00.000Z'
      && result.endDate === '2031-07-03T21:00:00.000Z' && result.timezone === 'UTC',
      reason: result.ok ? null : result.reason };
  }
  if (command.action === 'partiful-upload') {
    const client = partiful(command.badCredential);
    await client.refreshIdToken();
    const image = await fetchReferenceImage('https://media.atrium.invalid/reference.png');
    const result = await client.uploadCoverImage(image.bytes, 'image/png');
    return { ok: result.ok, valid_upload: result.ok && result.upload.width === 2
      && result.upload.height === 2 && result.upload.contentType === 'image/png'
      && new URL(result.upload.url).origin === 'https://media.atrium.invalid' };
  }
  if (command.action === 'external-issuer') {
    assertExternalAsConfig(true);
    const tokens = privateInputs().external_tokens;
    const identity = await verifyNativeAccessIdentity(tokens[command.variant ?? 'valid']);
    return { ok: identity !== null, exact_identity: identity !== null
      && identity.issuer === 'https://identity.atrium.invalid'
      && identity.sub === 'n06-synthetic-user' && identity.scopes.includes('n06-read') };
  }
  if (command.action === 'pocketid-admin') {
    const mint = () => mintCrewSignupToken({
      ttlSeconds: command.invalidTtl ? 0 : 300,
      groupName: command.foreignGroup ? 'not-authorized' : 'n06-fixture-crew',
    });
    const result = command.badCredential
      ? await changedEnv('WWW_POCKETID_API_KEY', randomBytes(32).toString('hex'), mint)
      : await mint();
    if (!result.ok) return { ok: false, token_exposed: false };
    const deleted = await deleteSignupToken(result.value.id);
    const repeated = await deleteSignupToken(result.value.id);
    return { ok: true, secret_received_in_memory: typeof result.value.token === 'string',
      deleted: deleted.ok, repeat_delete_idempotent: repeated.ok, token_exposed: false };
  }
  if (command.action === 'recipe') {
    if (command.unknownRef) return { ok: (await fetchCooklangDoc('not-in-native-index')) !== null };
    const index = await refreshCooklangIndex();
    const warmed = await warmParsedDocCache();
    const doc = await fetchCooklangDoc('n06-recipe');
    return { ok: index.ok && doc !== null, index_count: index.ok ? index.count : 0,
      parsed_native_shape: doc !== null && doc.ingredients[0]?.name === 'fixture flour'
      && doc.ingredients[0]?.quantity === 2 && doc.ingredients[0]?.units === 'tbsp'
      && doc.cookware[0]?.name === 'fixture bowl'
      && doc.steps[0] === 'Mix fixture flour in a fixture bowl.',
      warmed: warmed.ok };
  }
  if (command.action === 'mail') {
    const send = () => sendMail({
      to: command.badRecipient ? 'invalid-recipient' : 'recipient@example.invalid',
      subject: 'Isolated N06 fixture', text: 'Synthetic non-delivering fixture message.',
    });
    const result = command.badCredential
      ? await changedEnv('WWW_MAILGUN_API_KEY', randomBytes(32).toString('hex'), send)
      : await send();
    return { ok: result.ok, native_receipt: result.ok && result.id === '<n06-fixture-message>' };
  }
  if (command.action === 'push') {
    if (!getUserBySub('n06-fixture-owner')) {
      upsertUserOnLogin({
        sub: 'n06-fixture-owner', email: 'fixture-owner@example.invalid',
        name: 'N06 fixture owner', seedRole: 'crew',
      });
    }
    const subscription = privateInputs().push_subscription;
    upsertPushSubscription({
      endpoint: subscription.endpoint, userSub: 'n06-fixture-owner',
      keysP256dh: subscription.p256dh,
      keysAuth: command.badCredential ? randomBytes(16).toString('base64url') : subscription.auth,
    });
    const foreignDelete = deletePushSubscription(subscription.endpoint, 'foreign-fixture-owner');
    const ownerPreserved = listPushSubscriptions('n06-fixture-owner').length === 1;
    const configured = webPushChannel.isConfigured();
    try {
      if (!configured) return { ok: false, configured };
      await webPushChannel.send({
        title: 'N06 fixture', message: 'Synthetic push only.',
        url: 'https://whiskey.atrium.invalid/fixture',
      });
      return { ok: true, configured, foreign_delete_refused: !foreignDelete,
        owner_preserved: ownerPreserved };
    } catch {
      return { ok: false, configured, foreign_delete_refused: !foreignDelete,
        owner_preserved: ownerPreserved };
    } finally {
      deletePushSubscription(subscription.endpoint, 'n06-fixture-owner');
    }
  }
  throw new Error('unclassified_feature_action');
}
