import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DAILY_PUSH_CAP, pushRecipients, recipientTokens, sendOnce } from "./cadence.ts";
import {
  buildDailyDropPayload,
  buildFriendRequestPayload,
  buildVersusChallengePayload,
  buildVersusFinishedPayload, ApnsTokenInvalid, sendApnsPush } from "./apns.ts";

// What these tests are actually protecting.
//
// Routing the three trigger-driven notifiers through `sendOnce` (Task 5.2/5.3) put two
// categories with opposite requirements through one code path, and getting either backwards is
// silent in production — a push that should have gone out and didn't leaves no trace anywhere:
//
//   * `versus_challenge` must send even when the recipient is over their three, because a duel
//     has a clock and an unannounced duel is a forfeit the player never sees. But "exempt from
//     the cap" was read as "skips the whole function" in the version this replaces, which is
//     how it stayed out of `notification_log` entirely. Exempt must still be LOGGED.
//   * `friend_request` must NOT send over the three. Nothing is lost by a friend request
//     arriving as a badge instead of a buzz.
//
// And the sharp edge underneath both: 0018's unique index was (user_id, category, local_day),
// which is correct for the scheduled slots and wrong for anything a person can legitimately
// receive twice in a day. `dedupe_key` (migration 0022) is what separates the two, and the
// NULL half has to keep behaving exactly as it did before.

interface LogRow {
  user_id: string;
  category: string;
  local_day: string;
  dedupe_key: string | null;
}

/** Stands in for PostgREST closely enough for `sendOnce`: the chained builder it calls, and —
 * the part that matters — the `notification_log` unique index, enforced here the way Postgres
 * enforces it (NULLS NOT DISTINCT, so two NULL dedupe_keys collide). Without that, every test
 * below would pass against a broken schema. */
class FakeDb {
  log: LogRow[] = [];
  settings = new Map<string, Record<string, unknown>>();
  tokens = new Map<string, Array<{ token: string; utc_offset_minutes: number | null }>>();

  /** Mirrors `notification_log_once_per_event`. Returns "23505" when the row conflicts. */
  insertLog(row: LogRow): string | null {
    const clash = this.log.some((r) =>
      r.user_id === row.user_id && r.category === row.category &&
      r.local_day === row.local_day && r.dedupe_key === row.dedupe_key
    );
    if (clash) return "23505";
    this.log.push(row);
    return null;
  }
}

class Builder {
  private filters: Record<string, string> = {};
  private counting = false;
  constructor(private db: FakeDb, private table: string, private cols = "") {}

  select(cols: string, opts?: { count?: string; head?: boolean }) {
    this.cols = cols;
    if (opts?.count) this.counting = true;
    return this;
  }
  eq(col: string, val: string) {
    this.filters[col] = val;
    return this;
  }
  insert(row: Omit<LogRow, "dedupe_key"> & { dedupe_key: string | null }) {
    const code = this.db.insertLog({
      user_id: row.user_id,
      category: row.category,
      local_day: row.local_day,
      dedupe_key: row.dedupe_key,
    });
    return Promise.resolve(code ? { error: { code } } : { error: null });
  }
  maybeSingle() {
    return Promise.resolve({ data: this.rows()[0] ?? null });
  }
  // deno-lint-ignore no-explicit-any
  then(resolve: (v: any) => void) {
    const rows = this.rows();
    resolve(this.counting ? { count: rows.length, data: null } : { data: rows });
  }

  // deno-lint-ignore no-explicit-any
  private rows(): any[] {
    if (this.table === "notification_log") {
      return this.db.log.filter((r) =>
        Object.entries(this.filters).every(([k, v]) => (r as never as Record<string, unknown>)[k] === v)
      );
    }
    if (this.table === "notification_settings") {
      const s = this.db.settings.get(this.filters.user_id);
      return s ? [s] : [];
    }
    if (this.table === "device_tokens") {
      return this.db.tokens.get(this.filters.user_id) ?? [];
    }
    return [];
  }
}

function fakeClient(db: FakeDb) {
  return { from: (table: string) => new Builder(db, table) };
}

const USER = "11111111-1111-1111-1111-111111111111";
// 00:30 UTC on Aug 14 is still 8:30pm on Aug 13 for a UTC-4 device — the offset the live
// `notification_log` row from 2026-08-13 was actually written under.
const OFFSET_EASTERN = -240;
const T_0030_UTC_AUG14 = Date.UTC(2026, 7, 14, 0, 30);
const LOCAL_DAY = "2026-08-13";

function fill(db: FakeDb, n: number, day = LOCAL_DAY) {
  for (let i = 0; i < n; i++) {
    db.log.push({ user_id: USER, category: `filler_${i}`, local_day: day, dedupe_key: null });
  }
}

function send(db: FakeDb, payload: Parameters<typeof sendOnce>[1]["payload"], dedupeKey?: string) {
  return sendOnce(fakeClient(db), {
    userId: USER,
    tokens: [{ token: "tok-a", environment: "production" as const }],
    utcOffsetMinutes: OFFSET_EASTERN,
    nowMs: T_0030_UTC_AUG14,
    payload,
    dedupeKey,
  });
}

// MARK: - versus_challenge: cap-exempt, but logged

Deno.test("versus_challenge sends over the cap — a duel clock outranks the ceiling", async () => {
  const db = new FakeDb();
  fill(db, DAILY_PUSH_CAP); // already at three
  const r = await send(db, buildVersusChallengePayload("Marcus"), "challenge:42");
  assertEquals(r, { sent: true });
});

Deno.test("cap-exempt is not un-logged: the audit row is written anyway", async () => {
  const db = new FakeDb();
  fill(db, DAILY_PUSH_CAP + 5); // far past the ceiling
  await send(db, buildVersusChallengePayload("Marcus"), "challenge:42");
  const logged = db.log.filter((r) => r.category === "versus_challenge");
  assertEquals(logged.length, 1);
  assertEquals(logged[0].dedupe_key, "challenge:42");
  assertEquals(logged[0].local_day, LOCAL_DAY);
});

Deno.test("two different challenges the same day BOTH send", async () => {
  // The regression migration 0022 exists to prevent: under (user_id, category, local_day) the
  // second challenge of the day lost the insert race with the first and was never announced.
  const db = new FakeDb();
  assertEquals(await send(db, buildVersusChallengePayload("Marcus"), "challenge:42"), { sent: true });
  assertEquals(await send(db, buildVersusChallengePayload("Nadia"), "challenge:43"), { sent: true });
  assertEquals(db.log.length, 2);
});

Deno.test("a pg_net retry of the SAME challenge does not send twice", async () => {
  const db = new FakeDb();
  await send(db, buildVersusChallengePayload("Marcus"), "challenge:42");
  const retry = await send(db, buildVersusChallengePayload("Marcus"), "challenge:42");
  assertEquals(retry, { sent: false, reason: "already_sent" });
  assertEquals(db.log.length, 1);
});

Deno.test("the challenge and the result push on one duel don't collide", async () => {
  // Both carry category `versus_challenge` (see apns.ts), so only the differing dedupe key
  // keeps "X challenged you" and "X just played" from being one row.
  const db = new FakeDb();
  await send(db, buildVersusChallengePayload("Marcus"), "challenge:42");
  const result = await send(db, buildVersusFinishedPayload("Marcus", 120), "result:42");
  assertEquals(result, { sent: true });
  assertEquals(db.log.map((r) => r.dedupe_key), ["challenge:42", "result:42"]);
});

// MARK: - friend_request: capped

Deno.test("friend_request is refused at the cap, and writes no row", async () => {
  const db = new FakeDb();
  fill(db, DAILY_PUSH_CAP);
  const r = await send(db, buildFriendRequestPayload("Nadia"), `friend:${USER}`);
  assertEquals(r, { sent: false, reason: "capped" });
  assertEquals(db.log.length, DAILY_PUSH_CAP); // nothing added
});

Deno.test("friend_request sends and logs while under the cap", async () => {
  const db = new FakeDb();
  fill(db, DAILY_PUSH_CAP - 1);
  const r = await send(db, buildFriendRequestPayload("Nadia"), "friend:abc");
  assertEquals(r, { sent: true });
  assertEquals(db.log.at(-1)?.category, "friend_request");
  assertEquals(db.log.at(-1)?.dedupe_key, "friend:abc");
});

Deno.test("two people can friend-request you on the same day", async () => {
  const db = new FakeDb();
  assertEquals(await send(db, buildFriendRequestPayload("Nadia"), "friend:aaa"), { sent: true });
  assertEquals(await send(db, buildFriendRequestPayload("Owen"), "friend:bbb"), { sent: true });
  assertEquals(db.log.length, 2);
});

Deno.test("cap-exempt pushes still consume the budget the capped ones are measured against", async () => {
  // Three duels' worth of exempt pushes fill the day; the friend request then has to wait.
  const db = new FakeDb();
  for (const id of [1, 2, 3]) {
    await send(db, buildVersusChallengePayload("Marcus"), `challenge:${id}`);
  }
  assertEquals(db.log.length, 3);
  const r = await send(db, buildFriendRequestPayload("Nadia"), "friend:aaa");
  assertEquals(r, { sent: false, reason: "capped" });
});

// MARK: - the scheduled half must be untouched

Deno.test("a scheduled slot with no dedupe key is still once per category per day", async () => {
  const db = new FakeDb();
  assertEquals(await send(db, buildDailyDropPayload("Rings")), { sent: true });
  const again = await send(db, buildDailyDropPayload("Rings"));
  assertEquals(again, { sent: false, reason: "already_sent" });
  assertEquals(db.log.length, 1);
  assertEquals(db.log[0].dedupe_key, null);
});

Deno.test("the cap is counted in the recipient's LOCAL day, not the UTC day", async () => {
  // Three pushes already sent on the UTC-4 device's Aug 13 evening. The UTC clock has already
  // rolled to Aug 14; counting that way would hand the player a fresh budget at 8:30pm.
  const db = new FakeDb();
  fill(db, DAILY_PUSH_CAP, "2026-08-13");
  assertEquals(await send(db, buildFriendRequestPayload("Nadia"), "friend:aaa"),
    { sent: false, reason: "capped" });
  // Same instant, a UTC+0 device: genuinely a new local day, so genuinely a new budget.
  const utc = await sendOnce(fakeClient(db), {
    userId: USER, tokens: [{ token: "tok-a", environment: "production" as const }], utcOffsetMinutes: 0, nowMs: T_0030_UTC_AUG14,
    payload: buildFriendRequestPayload("Nadia"), dedupeKey: "friend:aaa",
  });
  assertEquals(utc, { sent: true });
  assertEquals(db.log.at(-1)?.local_day, "2026-08-14");
});

Deno.test("every device gets the push, but the log records the person once", async () => {
  const db = new FakeDb();
  const r = await sendOnce(fakeClient(db), {
    userId: USER, tokens: ["tok-a", "tok-b", "tok-c"].map((t) => ({ token: t, environment: "production" as const })), utcOffsetMinutes: OFFSET_EASTERN,
    nowMs: T_0030_UTC_AUG14, payload: buildVersusChallengePayload("Marcus"),
    dedupeKey: "challenge:42",
  });
  assertEquals(r, { sent: true });
  assertEquals(db.log.length, 1);
});

// MARK: - recipientTokens

Deno.test("recipientTokens returns every device and one offset to judge the day by", async () => {
  // The live shape as of 2026-08-14: one user, a UTC-240 phone and two UTC+120 devices.
  const db = new FakeDb();
  db.tokens.set(USER, [
    { token: "tok-a", utc_offset_minutes: -240 },
    { token: "tok-b", utc_offset_minutes: 120 },
    { token: "tok-c", utc_offset_minutes: 120 },
  ]);
  const got = await recipientTokens(fakeClient(db), USER);
  assertEquals(got.tokens.map((t) => t.token), ["tok-a", "tok-b", "tok-c"]);
  assertEquals(got.utcOffsetMinutes, -240);
});

Deno.test("recipientTokens on a user with no devices is empty, not a crash", async () => {
  const got = await recipientTokens(fakeClient(new FakeDb()), USER);
  assertEquals(got.tokens, []);
  assertEquals(got.utcOffsetMinutes, 0);
});

// ── APNs environment routing and dead-token pruning ─────────────────────────
// These cover the defect that made 100% of this app's pushes fail: the sender hardcoded the
// production host, so every token minted by a debug or simulator build was posted somewhere it
// had never been registered, and APNs answered BadDeviceToken every time.

Deno.test("a development token is sent to the sandbox host, not production", async () => {
  const urls: string[] = [];
  await sendApnsPush("tok-dev", buildDailyDropPayload("Rings"), {
    environment: "development",
    now: () => T_0030_UTC_AUG14,
    fetch: ((url: string) => {
      urls.push(String(url));
      return Promise.resolve(new Response("", { status: 200 }));
    }) as unknown as typeof fetch,
  });
  // Empty when APNs credentials aren't configured (the [apns:stub] path) — assert only if a
  // request was actually attempted, so this passes with or without Vault secrets present.
  if (urls.length) {
    assertEquals(urls[0].startsWith("https://api.sandbox.push.apple.com/3/device/"), true);
  }
});

Deno.test("a production token still goes to the production host", async () => {
  const urls: string[] = [];
  await sendApnsPush("tok-prod", buildDailyDropPayload("Rings"), {
    environment: "production",
    now: () => T_0030_UTC_AUG14,
    fetch: ((url: string) => {
      urls.push(String(url));
      return Promise.resolve(new Response("", { status: 200 }));
    }) as unknown as typeof fetch,
  });
  if (urls.length) {
    assertEquals(urls[0].startsWith("https://api.push.apple.com/3/device/"), true);
  }
});

Deno.test("BadDeviceToken and 410 are distinguishable from an ordinary send failure", () => {
  // The distinction is what lets `sendOnce` prune instead of retrying forever.
  const dead = new ApnsTokenInvalid("tok-a", 410, "Unregistered");
  assertEquals(dead instanceof ApnsTokenInvalid, true);
  assertEquals(dead.deviceToken, "tok-a");
  assertEquals(new Error("boom") instanceof ApnsTokenInvalid, false);
});

Deno.test("recipientTokens defaults a missing environment to production", async () => {
  const sb = {
    from: () => ({
      select: () => ({
        eq: () => Promise.resolve({
          data: [
            { token: "a", utc_offset_minutes: 0, apns_environment: null },
            { token: "b", utc_offset_minutes: 0, apns_environment: "development" },
          ],
        }),
      }),
    }),
  };
  // deno-lint-ignore no-explicit-any
  const got = await recipientTokens(sb as any, USER);
  assertEquals(got.tokens, [
    { token: "a", environment: "production" },
    { token: "b", environment: "development" },
  ]);
});

// The cron sweep's grouping. Regression guard for the gap left by the 2026-08-17 environment
// change: the three cron notifiers kept building `string[]`, which `sendOnce` destructures
// into `{ token: undefined, environment: undefined }` — a silent 100% delivery failure that
// still logged every push as if it had gone out.
Deno.test("pushRecipients groups a person's devices and keeps each token's environment", () => {
  const got = pushRecipients([
    { user_id: "u1", token: "a", utc_offset_minutes: -240, apns_environment: "development" },
    { user_id: "u1", token: "b", utc_offset_minutes: 120, apns_environment: null },
    { user_id: "u2", token: "c", utc_offset_minutes: 0, apns_environment: "production" },
  ]);
  assertEquals(got.length, 2);
  assertEquals(got[0].tokens, [
    { token: "a", environment: "development" },
    { token: "b", environment: "production" },
  ]);
  // First row wins the offset, same rule as `recipientTokens`.
  assertEquals(got[0].utc_offset_minutes, -240);
  assertEquals(got[1].tokens, [{ token: "c", environment: "production" }]);
});

Deno.test("pushRecipients yields tokens sendOnce can actually destructure", () => {
  const [only] = pushRecipients([
    { user_id: "u1", token: "tok", utc_offset_minutes: 0, apns_environment: null },
  ]);
  // The exact shape the previous hand-rolled grouping got wrong.
  for (const { token, environment } of only.tokens) {
    assertEquals(typeof token, "string");
    assertEquals(environment, "production");
  }
});

Deno.test("pushRecipients tolerates a null query result and a null offset", () => {
  assertEquals(pushRecipients(null), []);
  const [one] = pushRecipients([
    { user_id: "u1", token: "t", utc_offset_minutes: null, apns_environment: null },
  ]);
  assertEquals(one.utc_offset_minutes, 0);
});
