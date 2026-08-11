import { test, expect } from "@playwright/test";
import type { APIRequestContext } from "@playwright/test";
import { ownerAdminToken, uniqueEmail } from "./helpers";

/**
 * The closed-beta gate itself, driven against the real stack with
 * INVITE_ONLY_REGISTRATION=true — the launch posture. register.spec.ts covers
 * registration once the door is open; this file covers the DOOR: uninvited
 * refusal, the code lifecycle, revocation, and single use.
 */

async function adminAuth(request: APIRequestContext) {
  return { Authorization: `Bearer ${await ownerAdminToken(request)}` };
}

async function mintInvite(
  request: APIRequestContext,
  data: Record<string, unknown> = {},
): Promise<{ id: string; code: string }> {
  const created = await request.post("/api/admin/invites", {
    headers: await adminAuth(request),
    data: { note: "invite-gate.spec", ...data },
  });
  expect(created.status(), "invite create").toBe(201);
  const invite = (await created.json()).invite;
  return { id: invite.id as string, code: invite.code as string };
}

function registration(email: string, invite_code?: string) {
  return {
    email,
    password: "a-strong-password",
    display_name: "Gate Walker",
    ...(invite_code ? { invite_code } : {}),
  };
}

test.describe("Invite gate — the wire", () => {
  test("uninvited registration is refused, with and without a guessed code", async ({
    request,
  }) => {
    const bare = await request.post("/api/auth/register", {
      data: registration(uniqueEmail()),
    });
    expect(bare.status(), "no code → 403").toBe(403);
    expect((await bare.json()).error).toBe("invite_required");

    const guessed = await request.post("/api/auth/register", {
      data: registration(uniqueEmail(), "STK-0000-0000"),
    });
    expect(guessed.status(), "unknown code → 403").toBe(403);
    expect((await guessed.json()).error).toBe("invite_invalid");
  });

  test("a code admits exactly one account, and the check endpoint tracks its lifecycle", async ({
    request,
  }) => {
    const { code } = await mintInvite(request);

    const check = await request.get(`/api/auth/invite/${code}`);
    expect(check.status(), "fresh code checks valid").toBe(200);
    expect((await check.json()).valid).toBe(true);

    const first = await request.post("/api/auth/register", {
      data: registration(uniqueEmail(), code),
    });
    expect(first.status(), "invited registration").toBe(201);

    const spent = await request.get(`/api/auth/invite/${code}`);
    expect(spent.status(), "spent code checks exhausted").toBe(409);

    const second = await request.post("/api/auth/register", {
      data: registration(uniqueEmail(), code),
    });
    expect(second.status(), "second redemption refused").toBe(409);
    expect((await second.json()).error).toBe("invite_exhausted");
  });

  test("a revoked code stops working, and the reader cannot tell revoked from expired", async ({
    request,
  }) => {
    const { id, code } = await mintInvite(request);

    const revoke = await request.delete(`/api/admin/invites/${id}`, {
      headers: await adminAuth(request),
    });
    expect(revoke.status(), "revoke").toBe(200);

    const check = await request.get(`/api/auth/invite/${code}`);
    expect(check.status(), "revoked code → 403").toBe(403);

    const attempt = await request.post("/api/auth/register", {
      data: registration(uniqueEmail(), code),
    });
    expect(attempt.status()).toBe(403);
    expect((await attempt.json()).error).toBe("invite_revoked");
  });

  test("an email-bound code refuses every other address", async ({ request }) => {
    const bound = uniqueEmail("e2e-bound");
    const { code } = await mintInvite(request, { invited_email: bound });

    const wrong = await request.post("/api/auth/register", {
      data: registration(uniqueEmail(), code),
    });
    expect(wrong.status(), "wrong address → 403").toBe(403);
    expect((await wrong.json()).error).toBe("invite_email_mismatch");

    const right = await request.post("/api/auth/register", {
      data: registration(bound.toUpperCase(), code),
    });
    expect(right.status(), "the bound address, any casing → 201").toBe(201);
  });

  test("the admin list shows a prefix, never a full code", async ({ request }) => {
    const { code } = await mintInvite(request);

    const list = await request.get("/api/admin/invites", {
      headers: await adminAuth(request),
    });
    expect(list.status()).toBe(200);
    const { invites } = await list.json();

    expect(invites.length).toBeGreaterThan(0);
    for (const invite of invites) {
      expect(invite.code, "list rows never carry a code").toBeUndefined();
      expect(invite.code_prefix.length).toBeLessThan(code.length);
    }
  });
});
