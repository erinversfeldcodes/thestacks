import { test, expect } from "@playwright/test";
import { mintSession, injectSession } from "./helpers";

/**
 * A group owner can see who is in the group and remove someone.
 *
 * Both halves were unreachable before: `list_group_members/2` had existed since
 * groups shipped with no route in front of it, so the members panel rendered
 * only the owner's raw UUID, and the DELETE endpoint had no client at all — an
 * owner could invite people and then never remove them.
 *
 * The group is built through the real invite-and-accept path rather than
 * fixtures, because the membership row that path creates is the thing the panel
 * reads. Note that `create_group` stores the creator's own membership with role
 * "member", so the Owner badge has to key off the group's `ownerId` — keying it
 * off the role produces a badge that can never render, and a fixture that
 * hand-sets role "owner" hides that.
 */

async function buildGroupWithTwoMembers(
  request: import("@playwright/test").APIRequestContext,
) {
  const owner = await mintSession(request, { displayName: "Ada Owner" });
  const member = await mintSession(request, { displayName: "Grace Member" });
  test.skip(
    owner === null || member === null,
    "test-session helper is not enabled here",
  );

  const ownerAuth = { Authorization: `Bearer ${owner!.token}` };
  const memberAuth = { Authorization: `Bearer ${member!.token}` };

  const created = await request.post("/api/groups", {
    headers: ownerAuth,
    data: {
      name: `Reading Circle ${Date.now()}`,
      type: "close_friends",
      visibility: "platform",
    },
  });
  expect(created.ok()).toBeTruthy();
  const { group } = await created.json();

  const invited = await request.post(`/api/groups/${group.id}/invitations`, {
    headers: ownerAuth,
    data: { identifier: member!.email },
  });
  expect(invited.ok()).toBeTruthy();
  const { invitation } = await invited.json();

  const accepted = await request.post(
    `/api/groups/${group.id}/invitations/${invitation.id}/accept`,
    { headers: memberAuth },
  );
  expect(accepted.ok()).toBeTruthy();

  return { owner: owner!, member: member!, group };
}

test.use({ storageState: { cookies: [], origins: [] } });

test.describe("Group membership", () => {
  test("the owner sees the members and can remove one", async ({
    page,
    request,
  }) => {
    const { owner, group } = await buildGroupWithTwoMembers(request);

    await injectSession(page, owner);
    await page.goto(`/groups/${group.id}`);

    // A minted owner has no placements, so the onboarding overlay opens over
    // the page and its backdrop swallows the Remove click.
    const overlay = page.getByTestId("onboarding-overlay");
    const appeared = await overlay
      .waitFor({ state: "visible", timeout: 3000 })
      .then(() => true)
      .catch(() => false);
    if (appeared) {
      await overlay.getByTestId("onboarding-skip-btn").click();
      await expect(overlay).not.toBeVisible();
    }

    const rows = page.locator(".groups-detail__member");
    await expect(rows).toHaveCount(2, { timeout: 15000 });

    // Real names, not raw ids — the panel used to print the owner's UUID.
    await expect(
      page.locator(".groups-detail__member-name", { hasText: "Grace Member" }),
    ).toBeVisible();

    const ownerRow = rows.filter({ hasText: "Ada Owner" });
    const memberRow = rows.filter({ hasText: "Grace Member" });

    await expect(
      ownerRow.locator(".groups-detail__member-role"),
    ).toHaveText("Owner");

    // Leaving is the owner's way out, so there is no Remove on yourself.
    await expect(
      ownerRow.locator(".groups-detail__member-remove"),
    ).toHaveCount(0);

    const remove = memberRow.locator(".groups-detail__member-remove");
    await expect(remove).toBeVisible();
    await remove.click();

    // The row goes. This is the half that was never verified: the server
    // returned 204 and really removed the member, while the list on screen
    // still showed them.
    await expect(rows).toHaveCount(1, { timeout: 10000 });
    await expect(
      page.locator(".groups-detail__member-name", { hasText: "Grace Member" }),
    ).toHaveCount(0);
  });
});
