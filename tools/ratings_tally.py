#!/usr/bin/env python3
"""
tools/ratings_tally.py

Fetches user ratings from GitHub Discussions (Ratings category) via GraphQL API
and returns a dict mapping repo_id -> {"up": int, "down": int, "url": str}.
"""

import os
import sys
import json
import re
import urllib.request

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ultimatejimmy/storefront.koplugin")
GRAPHQL_URL = "https://api.github.com/graphql"

def fetch_all_ratings():
    if not GITHUB_TOKEN:
        print("Warning: GITHUB_TOKEN not set for ratings tally, returning empty ratings.", file=sys.stderr)
        return {}

    owner, repo = GITHUB_REPOSITORY.split("/", 1) if "/" in GITHUB_REPOSITORY else ("ultimatejimmy", "storefront.koplugin")
    
    query = """
    query GetRatingsDiscussions($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        discussions(first: 100, after: $after) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            url
            title
            body
            category {
              name
            }
            comments(first: 100) {
              nodes {
                body
              }
            }
          }
        }
      }
    }
    """

    ratings_data = {}
    has_next = True
    after_cursor = None

    while has_next:
        req = urllib.request.Request(GRAPHQL_URL)
        req.add_header("Authorization", f"Bearer {GITHUB_TOKEN}")
        req.add_header("User-Agent", "KOReader-Storefront-CatalogBuilder/1.0")
        req.add_header("Content-Type", "application/json")
        
        payload = {"query": query, "variables": {"owner": owner, "name": repo, "after": after_cursor}}
        data = json.dumps(payload).encode("utf-8")
        
        try:
            with urllib.request.urlopen(req, data=data) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                if "errors" in res or not res.get("data") or not res["data"].get("repository"):
                    break
                    
                disc_conn = res["data"]["repository"]["discussions"]
                nodes = disc_conn.get("nodes", [])
                
                for disc in nodes:
                    body = disc.get("body", "")
                    disc_url = disc.get("url", "")
                    
                    m = re.search(r"<!--\s*storefront:repo_id=(\d+)\s*-->", body)
                    if not m:
                        continue
                    repo_id = int(m.group(1))
                    
                    up_votes = 0
                    down_votes = 0
                    device_votes = {}
                    
                    comments = disc.get("comments", {}).get("nodes", [])
                    for comment in comments:
                        c_body = comment.get("body", "")
                        cm = re.search(r"<!--\s*storefront_vote:device_uuid=([^\s]+)\s+vote=([^\s]+)\s*-->", c_body)
                        if cm:
                            dev_id = cm.group(1)
                            vote_dir = cm.group(2).lower()
                            device_votes[dev_id] = vote_dir
                            
                    for dev_id, vote_dir in device_votes.items():
                        if vote_dir == "up":
                            up_votes += 1
                        elif vote_dir == "down":
                            down_votes += 1
                            
                    ratings_data[repo_id] = {
                        "up": up_votes,
                        "down": down_votes,
                        "discussion_url": disc_url,
                    }
                    
                page_info = disc_conn.get("pageInfo", {})
                has_next = page_info.get("hasNextPage", False)
                after_cursor = page_info.get("endCursor")
        except Exception as e:
            print(f"Error fetching ratings tally: {e}", file=sys.stderr)
            break
            
    return ratings_data
