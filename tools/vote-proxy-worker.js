/**
 * Storefront Ratings Backend - Cloudflare Worker + D1 Database
 *
 * Provides fast, instant voting and rating aggregation for KOReader Storefront.
 * Requires a D1 database binding named `DB`.
 */

function computeWilsonScore(up, down) {
  const n = up + down;
  if (n === 0) return 0;
  const z = 1.96; // 95% confidence
  const phat = up / n;
  const z2 = z * z;
  const score =
    (phat + z2 / (2 * n) - z * Math.sqrt((phat * (1 - phat) + z2 / (4 * n)) / n)) /
    (1 + z2 / n);
  return Math.max(0, score);
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

async function initSchema(db) {
  await db.batch([
    db.prepare(`
      CREATE TABLE IF NOT EXISTS votes (
        repo_id TEXT NOT NULL,
        device_uuid TEXT NOT NULL,
        direction TEXT NOT NULL,
        PRIMARY KEY (repo_id, device_uuid)
      );
    `),
    db.prepare(`
      CREATE TABLE IF NOT EXISTS ratings (
        repo_id TEXT PRIMARY KEY,
        up INTEGER DEFAULT 0,
        down INTEGER DEFAULT 0,
        wilson REAL DEFAULT 0.0
      );
    `),
  ]);
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    const url = new URL(request.url);
    const db = env.DB;

    if (!db) {
      return new Response(
        JSON.stringify({ error: "Cloudflare D1 database binding 'DB' not configured." }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Ensure database tables exist
    try {
      await initSchema(db);
    } catch (e) {
      // Schema initialization failover
    }

    // GET /ratings - Fetch all aggregated ratings
    if (request.method === "GET" && (url.pathname === "/ratings" || url.pathname === "/")) {
      try {
        const { results } = await db.prepare("SELECT repo_id, up, down, wilson FROM ratings").all();
        const ratingsMap = {};
        for (const row of results || []) {
          ratingsMap[row.repo_id] = {
            up: row.up,
            down: row.down,
            wilson: row.wilson,
          };
        }
        return new Response(JSON.stringify(ratingsMap), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      } catch (err) {
        return new Response(JSON.stringify({ error: err.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // POST /vote - Record or update a device's vote
    if (request.method === "POST") {
      let body;
      try {
        body = await request.json();
      } catch {
        return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const repo_id = String(body.repo_id || "");
      const device_uuid = String(body.device_uuid || "");
      const direction = String(body.direction || "none").toLowerCase();

      if (!repo_id || !device_uuid) {
        return new Response(
          JSON.stringify({ error: "Missing required fields: repo_id, device_uuid" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (!["up", "down", "none"].includes(direction)) {
        return new Response(
          JSON.stringify({ error: "Invalid direction: must be 'up', 'down', or 'none'" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      try {
        // 1. Update votes table
        if (direction === "none") {
          await db
            .prepare("DELETE FROM votes WHERE repo_id = ? AND device_uuid = ?")
            .bind(repo_id, device_uuid)
            .run();
        } else {
          await db
            .prepare(
              `INSERT INTO votes (repo_id, device_uuid, direction) 
               VALUES (?, ?, ?) 
               ON CONFLICT(repo_id, device_uuid) DO UPDATE SET direction = excluded.direction`
            )
            .bind(repo_id, device_uuid, direction)
            .run();
        }

        // 2. Tally votes for this repo_id
        const { results: countResults } = await db
          .prepare(
            `SELECT direction, COUNT(*) as count FROM votes WHERE repo_id = ? GROUP BY direction`
          )
          .bind(repo_id)
          .all();

        let up = 0;
        let down = 0;
        for (const row of countResults || []) {
          if (row.direction === "up") up = row.count;
          if (row.direction === "down") down = row.count;
        }

        const wilson = computeWilsonScore(up, down);

        // 3. Upsert ratings summary table
        if (up === 0 && down === 0) {
          await db.prepare("DELETE FROM ratings WHERE repo_id = ?").bind(repo_id).run();
        } else {
          await db
            .prepare(
              `INSERT INTO ratings (repo_id, up, down, wilson) 
               VALUES (?, ?, ?, ?) 
               ON CONFLICT(repo_id) DO UPDATE SET up = excluded.up, down = excluded.down, wilson = excluded.wilson`
            )
            .bind(repo_id, up, down, wilson)
            .run();
        }

        return new Response(
          JSON.stringify({ success: true, repo_id, up, down, wilson }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      } catch (err) {
        return new Response(JSON.stringify({ error: err.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    return new Response(JSON.stringify({ error: "Not Found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  },
};
