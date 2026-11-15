// Deletes the signed-in Bloom user, and only them.
//
// 1. Verifies the caller from the Authorization bearer token.
// 2. For each pregnancy they belong to:
//    - another member remains -> hand `pregnancies.created_by` to that member if needed
//      (created_by cascades on user delete), and remove the photos of the meds this user
//      takes (those rows cascade away with the user).
//    - nobody else remains -> remove all of the pregnancy's photos and delete the pregnancy
//      (milestones, medications, follows, dose logs and tokens cascade).
// 3. Deletes the auth user; profiles, memberships, follows and device tokens cascade.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

const BUCKETS = ["milestone-photos", "medication-photos"] as const;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "Server not configured" }, 500);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "Not signed in" }, 401);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: "Not signed in" }, 401);
  const userId = userData.user.id;

  try {
    const { data: memberships, error: mErr } = await admin
      .from("pregnancy_members")
      .select("pregnancy_id")
      .eq("user_id", userId);
    if (mErr) throw mErr;

    for (const { pregnancy_id: pid } of memberships ?? []) {
      const { data: others, error: oErr } = await admin
        .from("pregnancy_members")
        .select("user_id")
        .eq("pregnancy_id", pid)
        .neq("user_id", userId);
      if (oErr) throw oErr;

      if (others && others.length > 0) {
        // Keep the pregnancy for the partner.
        const { error: tErr } = await admin
          .from("pregnancies")
          .update({ created_by: others[0].user_id })
          .eq("id", pid)
          .eq("created_by", userId);
        if (tErr) throw tErr;

        const { data: myMeds, error: medErr } = await admin
          .from("medications")
          .select("photo_path")
          .eq("pregnancy_id", pid)
          .eq("taken_by", userId)
          .not("photo_path", "is", null);
        if (medErr) throw medErr;
        const paths = (myMeds ?? []).map((m) => m.photo_path as string).filter(Boolean);
        if (paths.length) await admin.storage.from("medication-photos").remove(paths);
      } else {
        // Last member: remove every photo, then the pregnancy itself.
        for (const bucket of BUCKETS) await removeFolder(admin, bucket, pid);
        const { error: dErr } = await admin.from("pregnancies").delete().eq("id", pid);
        if (dErr) throw dErr;
      }
    }

    const { error: delErr } = await admin.auth.admin.deleteUser(userId);
    if (delErr) throw delErr;

    return json({ deleted: true });
  } catch (e) {
    console.error("delete-account failed", e);
    return json({ error: "Couldn't delete the account. Please try again." }, 500);
  }
});

// deno-lint-ignore no-explicit-any
async function removeFolder(admin: any, bucket: string, pid: string) {
  const folder = String(pid).toLowerCase();
  for (;;) {
    const { data, error } = await admin.storage.from(bucket).list(folder, { limit: 100 });
    if (error || !data || data.length === 0) return;
    const paths = data.map((f: { name: string }) => `${folder}/${f.name}`);
    const { error: rmErr } = await admin.storage.from(bucket).remove(paths);
    if (rmErr) return;
  }
}
