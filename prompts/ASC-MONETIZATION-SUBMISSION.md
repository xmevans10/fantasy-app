# Submitting the subscriptions + packs — the UI-only steps

**Why this is manual.** The App Store Connect REST API cannot attach in-app purchases or
subscriptions to a review submission. This was proved exhaustively:

- There is no IAP/subscription relationship on `reviewSubmissionItems` under any name.
- The standalone submit endpoint returns `FIRST_NON_CONSUMABLE_MUST_BE_SUBMITTED_ON_VERSION`.
- Submitting the subs alone returns **`SUBSCRIPTION_SUBMISSION_REQUIRES_GROUP_VERSION`** — a
  first subscription must go up together with its **subscription group version**.

Everything else in the release pipeline *is* scriptable (see the `testflight-release` skill).
This one flow is not.

**The single most important rule: all of it goes in ONE submission.** Splitting the app version,
the subscription group, and the products across separate submissions is exactly what failed
repeatedly. Apple wants one submission containing the app version **+ the subscription group
version + both subscriptions + both packs**.

---

## What is already done (do not redo)

| Item | Product ID | State |
|---|---|---|
| Pro Monthly ($4.99/mo) | `com.balliqfantasy.app.pro.monthly` | `READY_TO_SUBMIT` |
| Pro Yearly ($34.99/yr) | `com.balliqfantasy.app.pro.yearly` | `READY_TO_SUBMIT` |
| Draft & Spin Pack ($1.99) | `com.balliqfantasy.app.pack.draftspin` | `READY_TO_SUBMIT` |
| The Grid Pack ($2.99) | `com.balliqfantasy.app.pack.grid` | `READY_TO_SUBMIT` |

Subscription group: **"Pro"** (id `22239725`). Both subs already carry prices, en-US + es-MX
localizations, and review screenshots. The Paid Applications agreement is signed. Nothing in the
product configuration needs touching — this is purely the act of submitting them.

---

## State as of 2026-07-26 — everything up to the UI step is done

- **1.1 was pulled from review** (its submission is canceled; the version record was renamed to
  **1.2**, keeping all screenshots, description and review details).
- **Build 14 is uploaded, VALID, and attached to 1.2.**
- **1.2 is in `PREPARE_FOR_SUBMISSION`** — the editable state the IAP attachment requires.
- Release notes are written.

**1.2 was deliberately NOT submitted.** Submitting via the API would lock the version page and
make the four products un-attachable — which is the exact trap that made this a hand-off in the
first place. The version is being held open *for* step 3 below. Attach the products, then submit
once, from the UI.

---

## Steps

1. Go to **App Store Connect → Apps → BallIQ - Fantasy → App Store** tab.

2. Select the **1.2** version in the left sidebar. It should already be in **Prepare for
   Submission** (yellow dot) with build 14 attached.

3. Scroll to the **In-App Purchases and Subscriptions** section of that version page.
   (On newer ASC layouts this reads **"In-App Purchases"** with an **Add** / **+** button, or a
   blue **"Select In-App Purchases and Subscriptions"** link.)

4. Click **+ / Select**, then tick **all four**:
   - Pro Monthly
   - Pro Yearly
   - Draft & Spin Pack
   - The Grid Pack

   If the two subscriptions are greyed out or missing here, it means the **subscription group
   version** isn't being included. Go to **Monetization → Subscriptions → Pro** and make sure the
   group itself shows as ready to submit; the group version rides along with the subs
   automatically once they're selected on the version page. This is the exact thing
   `SUBSCRIPTION_SUBMISSION_REQUIRES_GROUP_VERSION` was complaining about.

5. Click **Done / Save**. The four products should now be listed on the 1.2 version page.

6. Confirm the rest of the version page is complete (build attached, screenshots, description,
   what's new, review notes) — it should already be.

7. Click **Add for Review**, then **Submit to App Review**.

8. Verify: each product's state should flip from `READY_TO_SUBMIT` to **`WAITING_FOR_REVIEW`**.
   You can check without the UI by running, from the repo root:

   ```bash
   python3 tools/release/asc.py GET "/v1/apps/6785275045/inAppPurchasesV2?fields[inAppPurchases]=name,state"
   ```

---

## Also still UI-only

**The Resolution Center reply** for the original 1.1 / build 11 rejection (Guideline 3.1.2(c),
the missing Terms of Use link) is not exposed in the REST API. If Apple asks again, reply there
with a screen recording showing the paywall's **Terms of Use (EULA)** and **Privacy Policy**
links — both are live in the build (verified on device 2026-07-26; the footer also carries the
auto-renewal disclosure and a per-plan billing-period line).

---

## If review comes back rejected on the IAPs

The most common first-submission rejections for this shape of product:

- **Guideline 3.1.2** — subscription purchase flow must show title, length, price, and what's
  included, plus functional EULA + Privacy links. All of that shipped in the 1.1 build-12 fix.
- **Guideline 2.1 — incomplete information** — reviewers must be able to *reach* the paywall.
  The review notes should say how (Profile → Playbook Pro, or any Pro-gated format).
