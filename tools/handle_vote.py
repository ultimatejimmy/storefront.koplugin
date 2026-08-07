#!/usr/bin/env python3
"""
tools/handle_vote.py

Processes a user vote dispatched from KOReader Storefront.
Environment variables:
- GITHUB_TOKEN: GitHub PAT or workflow token
- GITHUB_REPOSITORY: owner/repo (e.g. ultimatejimmy/storefront.koplugin)
- REPO_ID: ID of the catalog item being voted on
- DIRECTION: "up", "down", or "none"
- DEVICE_UUID: Anonymous UUID string from KOReader device
- ITEM_KIND: "plugin", "patch", or "font"
"""

import os
import sys
import json
import urllib.request
import urllib.parse

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ultimatejimmy/storefront.koplugin")
REPO_ID = os.environ.get("REPO_ID")
DIRECTION = os.environ.get("DIRECTION", "up").lower()
DEVICE_UUID = os.environ.get("DEVICE_UUID", "").strip()
ITEM_KIND = os.environ.get("ITEM_KIND", "plugin")

if not GITHUB_TOKEN:
    print("Error: GITHUB_TOKEN not set.", file=sys.stderr)
    sys.exit(1)

if not REPO_ID or not DEVICE_UUID:
    print("Error: REPO_ID and DEVICE_UUID are required.", file=sys.stderr)
    sys.exit(1)

OWNER, REPO = GITHUB_REPOSITORY.split("/", 1) if "/" in GITHUB_REPOSITORY else ("ultimatejimmy", "storefront.koplugin")
GRAPHQL_URL = "https://api.github.com/graphql"

def graphql_query(query, variables=None):
    req = urllib.request.Request(GRAPHQL_URL)
    req.add_header("Authorization", f"Bearer {GITHUB_TOKEN}")
    req.add_header("User-Agent", "KOReader-Storefront-VoteHandler/1.0")
    req.add_header("Content-Type", "application/json")
    
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
        
    data = json.dumps(payload).encode("utf-8")
    try:
        with urllib.request.urlopen(req, data=data) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            if "errors" in res:
                print(f"GraphQL Errors: {res['errors']}", file=sys.stderr)
            return res
    except Exception as e:
        print(f"GraphQL HTTP Error: {e}", file=sys.stderr)
        return None

def get_repository_and_categories():
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
        return None, None
    repo_id = res["data"]["repository"]["id"]
    categories = res["data"]["repository"]["discussionCategories"]["nodes"]
    ratings_cat_id = None
    for cat in categories:
        if cat["name"].lower() == "ratings":
            ratings_cat_id = cat["id"]
            break
    if not ratings_cat_id and categories:
        ratings_cat_id = categories[0]["id"]
    return repo_id, ratings_cat_id

def find_or_create_discussion(cat_id):
    search_tag = f"<!-- storefront:repo_id={REPO_ID} -->"
    query = """
    query SearchDiscussions($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        discussions(first: 100) {
          nodes {
            id
            title
            body
          }
        }
      }
    }
    """
    res = graphql_query(query, {"owner": OWNER, "name": REPO})
    if res and "data" in res and res["data"].get("repository"):
        for disc in res["data"]["repository"]["discussions"]["nodes"]:
            if search_tag in disc["body"]:
                return disc["id"]
                
    title = f"[Rating] {ITEM_KIND.capitalize()} #{REPO_ID}"
    body = f"User ratings thread for {ITEM_KIND} (ID: {REPO_ID}).\n\n{search_tag}"
    
    mutation = """
    mutation CreateDiscussion($repoId: ID!, $catId: ID!, $title: String!, $body: String!) {
      createDiscussion(input: {repositoryId: $repoId, categoryId: $catId, title: $title, body: $body}) {
        discussion {
          id
        }
      }
    }
    """
    res_c = graphql_query(mutation, {"repoId": GITHUB_REPO_ID, "catId": cat_id, "title": title, "body": body})
    if res_c and "data" in res_c and res_c["data"].get("createDiscussion"):
        return res_c["data"]["createDiscussion"]["discussion"]["id"]
    return None

def process_comment_vote(discussion_id):
    vote_tag_prefix = f"<!-- storefront_vote:device_uuid={DEVICE_UUID}"
    vote_tag_full = f"<!-- storefront_vote:device_uuid={DEVICE_UUID} vote={DIRECTION} -->"
    short_uuid = DEVICE_UUID[:8]
    comment_body = f"{vote_tag_full}\nDevice `...{short_uuid}` voted: **{DIRECTION}**"
    
    query = """
    query GetComments($discId: ID!) {
      node(id: $discId) {
        ... on Discussion {
          comments(first: 100) {
            nodes {
              id
              body
            }
          }
        }
      }
    }
    """
    res = graphql_query(query, {"discId": discussion_id})
    existing_comment_id = None
    
    if res and "data" in res and res["data"].get("node"):
        comments = res["data"]["node"].get("comments", {}).get("nodes", [])
        for comment in comments:
            if vote_tag_prefix in comment["body"]:
                existing_comment_id = comment["id"]
                break
                
    if existing_comment_id:
        if DIRECTION == "none":
            mutation = """
            mutation DeleteComment($id: ID!) {
              deleteDiscussionComment(input: {id: $id}) {
                comment { id }
              }
            }
            """
            graphql_query(mutation, {"id": existing_comment_id})
            print(f"Deleted vote for device {short_uuid}")
        else:
            mutation = """
            mutation UpdateComment($id: ID!, $body: String!) {
              updateDiscussionComment(input: {commentId: $id, body: $body}) {
                comment { id }
              }
            }
            """
            graphql_query(mutation, {"id": existing_comment_id, "body": comment_body})
            print(f"Updated vote to {DIRECTION} for device {short_uuid}")
    else:
        if DIRECTION != "none":
            mutation = """
            mutation AddComment($discId: ID!, $body: String!) {
              addDiscussionComment(input: {discussionId: $discId, body: $body}) {
                comment { id }
              }
            }
            """
            graphql_query(mutation, {"discId": discussion_id, "body": comment_body})
            print(f"Added new vote {DIRECTION} for device {short_uuid}")

def main():
    global GITHUB_REPO_ID
    repo_id, cat_id = get_repository_and_categories()
    if not repo_id or not cat_id:
        print("Failed to retrieve repository or categories info", file=sys.stderr)
        sys.exit(1)
    GITHUB_REPO_ID = repo_id
    
    disc_id = find_or_create_discussion(cat_id)
    if not disc_id:
        print("Failed to find or create discussion thread", file=sys.stderr)
        sys.exit(1)
        
    process_comment_vote(disc_id)

if __name__ == "__main__":
    main()
