import os
import sys
import json
import urllib.request

GITHUB_TOKEN = os.environ.get("RATINGS_BOT_TOKEN") or os.environ.get("GITHUB_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ultimatejimmy/storefront.koplugin")

if not GITHUB_TOKEN:
    print("Error: GITHUB_TOKEN or RATINGS_BOT_TOKEN environment variable required.", file=sys.stderr)
    sys.exit(1)

OWNER, REPO = GITHUB_REPOSITORY.split("/", 1) if "/" in GITHUB_REPOSITORY else ("ultimatejimmy", "storefront.koplugin")
GRAPHQL_URL = "https://api.github.com/graphql"

def graphql_query(query, variables=None):
    req = urllib.request.Request(GRAPHQL_URL)
    req.add_header("Authorization", f"Bearer {GITHUB_TOKEN}")
    req.add_header("User-Agent", "Storefront-Discussion-Deleter/1.0")
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
    print("=== Bulk Deleting Storefront Rating Discussions ===")
    
    query = """
    query GetDiscussions($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        discussions(first: 100, after: $after) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            title
            body
          }
        }
      }
    }
    """
    
    delete_mutation = """
    mutation DeleteDiscussion($id: ID!) {
      deleteDiscussion(input: {id: $id}) {
        discussion {
          id
        }
      }
    }
    """
    
    has_next = True
    after = None
    deleted_count = 0
    
    while has_next:
        res = graphql_query(query, {"owner": OWNER, "name": REPO, "after": after})
        if not res or "data" not in res or not res["data"].get("repository"):
            print("Failed to fetch discussions.", file=sys.stderr)
            break
            
        disc_conn = res["data"]["repository"]["discussions"]
        nodes = disc_conn.get("nodes", [])
        
        for d in nodes:
            disc_id = d["id"]
            title = d.get("title", "")
            body = d.get("body", "")
            
            # Check if this discussion was created for storefront ratings
            if "[Rating]" in title or "<!-- storefront:repo_id=" in body:
                print(f"Deleting discussion: {title} ({disc_id})...")
                del_res = graphql_query(delete_mutation, {"id": disc_id})
                if del_res and "data" in del_res and del_res["data"].get("deleteDiscussion"):
                    deleted_count += 1
                else:
                    print(f"Failed to delete {disc_id}: {del_res}", file=sys.stderr)
                    
        page_info = disc_conn.get("pageInfo", {})
        has_next = page_info.get("hasNextPage", False)
        after = page_info.get("endCursor")

    print(f"\nFinished! Deleted {deleted_count} storefront discussion(s).")

if __name__ == "__main__":
    main()
