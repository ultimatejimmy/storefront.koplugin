#!/usr/bin/env python3
"""
tools/sync_discussions.py

Ensures that every item in catalog.json has a corresponding GitHub Discussion thread
under the "Ratings" category.
"""

import os
import sys
import json
import urllib.request

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ultimatejimmy/storefront.koplugin")
GRAPHQL_URL = "https://api.github.com/graphql"

if not GITHUB_TOKEN:
    print("Warning: GITHUB_TOKEN not set, skipping discussions sync.", file=sys.stderr)
    sys.exit(0)

OWNER, REPO = GITHUB_REPOSITORY.split("/", 1) if "/" in GITHUB_REPOSITORY else ("ultimatejimmy", "storefront.koplugin")

def graphql_query(query, variables=None):
    req = urllib.request.Request(GRAPHQL_URL)
    req.add_header("Authorization", f"Bearer {GITHUB_TOKEN}")
    req.add_header("User-Agent", "KOReader-Storefront-DiscussionSync/1.0")
    req.add_header("Content-Type", "application/json")
    
    payload = {"query": query, "variables": variables or {}}
    data = json.dumps(payload).encode("utf-8")
    try:
        with urllib.request.urlopen(req, data=data) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"GraphQL error: {e}", file=sys.stderr)
        return None

def main():
    print("=== Syncing GitHub Discussions for Catalog Items ===")
    
    query = """
    query GetRepoInfo($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        id
        discussionCategories(first: 20) {
          nodes {
            id
            name
          }
        }
      }
    }
    """
    res = graphql_query(query, {"owner": OWNER, "name": REPO})
    if not res or "data" not in res or not res["data"].get("repository"):
        print("Could not fetch repository info.", file=sys.stderr)
        return
        
    repo_node_id = res["data"]["repository"]["id"]
    categories = res["data"]["repository"]["discussionCategories"]["nodes"]
    ratings_cat_id = None
    for cat in categories:
        if cat["name"].lower() == "ratings":
            ratings_cat_id = cat["id"]
            break
            
    if not ratings_cat_id:
        print("Warning: 'Ratings' category not found in GitHub Discussions. Using first category.", file=sys.stderr)
        if categories:
            ratings_cat_id = categories[0]["id"]
        else:
            print("Error: No discussion categories available.", file=sys.stderr)
            return

    query_discs = """
    query GetExistingDiscussions($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        discussions(first: 100, after: $after) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            body
          }
        }
      }
    }
    """
    existing_repo_ids = set()
    has_next = True
    after = None
    while has_next:
        r_disc = graphql_query(query_discs, {"owner": OWNER, "name": REPO, "after": after})
        if not r_disc or "data" not in r_disc or not r_disc["data"].get("repository"):
            break
        disc_conn = r_disc["data"]["repository"]["discussions"]
        for d in disc_conn.get("nodes", []):
            body = d.get("body", "")
            import re
            m = re.search(r"<!--\s*storefront:repo_id=(\d+)\s*-->", body)
            if m:
                existing_repo_ids.add(int(m.group(1)))
        page_info = disc_conn.get("pageInfo", {})
        has_next = page_info.get("hasNextPage", False)
        after = page_info.get("endCursor")

    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    catalog_path = os.path.abspath(os.path.join(script_dir, "..", "catalog.json"))
    if not os.path.exists(catalog_path):
        print(f"Catalog file not found at {catalog_path}", file=sys.stderr)
        return

    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    all_items = catalog.get("plugins", []) + catalog.get("patches", []) + catalog.get("fonts", [])
    
    created_count = 0
    mutation_create = """
    mutation CreateDiscussion($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
      createDiscussion(input: {repositoryId: $repoId, categoryId: $catId, title: $title, body: $body}) {
        discussion {
          id
          url
        }
      }
    }
    """

    for item in all_items:
        r_id = item.get("id") or item.get("repo_id")
        if not r_id or r_id in existing_repo_ids:
            continue

        name = item.get("name") or item.get("full_name") or f"Item #{r_id}"
        owner_name = item.get("owner") or ""
        desc = item.get("description") or "No description provided."
        stars = item.get("stars", 0)
        html_url = item.get("html_url") or (f"https://github.com/{item.get('full_name')}" if item.get("full_name") else "")

        title = f"[Rating] {name}"
        body_lines = [
            f"## {name}",
            f"**Author:** {owner_name}" if owner_name else "",
            f"**GitHub Stars:** ⭐ {stars}" if stars else "",
            f"**URL:** [{html_url}]({html_url})" if html_url else "",
            "",
            f"### Description",
            desc,
            "",
            "---",
            f"*This discussion thread collects in-app user ratings for KOReader Storefront.*",
            f"<!-- storefront:repo_id={r_id} -->"
        ]
        body = "\n".join([line for line in body_lines if line is not None])

        res_c = graphql_query(mutation_create, {
            "repoId": repo_node_id,
            "catId": ratings_cat_id,
            "title": title,
            "body": body
        })
        if res_c and "data" in res_c and res_c["data"].get("createDiscussion"):
            created_count += 1
            existing_repo_ids.add(r_id)

    print(f"Sync complete. Created {created_count} new Discussion rating threads.")

if __name__ == "__main__":
    main()
