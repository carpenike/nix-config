import { db } from '/run/atrium-n03/whiskey/dist/server/db/client.js';
import { operations, taggedItems, dispatches } from '/run/atrium-n03/whiskey/dist/server/db/schema.js';
import { upsertUserOnLogin } from '/run/atrium-n03/whiskey/dist/server/lib/service.js';

const now = new Date();
db.insert(operations).values({
  id: 'n03-synthetic-operation', title: 'Synthetic isolated operation',
  host: 'Synthetic host', status: 'upcoming', attendees: [], createdAt: now, updatedAt: now,
}).run();
db.insert(taggedItems).values({
  id: 'n03-synthetic-item', collection: 'screenings', name: 'Synthetic fixture', createdAt: now,
}).run();
db.insert(dispatches).values({
  id: 'n03-synthetic-dispatch', name: 'Synthetic fixture', subject: 'Fixture', body: 'Non-actuating data',
}).run();
upsertUserOnLogin({
  sub: 'synthetic-ryan-subject', email: 'synthetic@example.invalid',
  name: 'Synthetic administrator', seedRole: 'host',
});
console.log(JSON.stringify({ ready: true, synthetic: true }));
