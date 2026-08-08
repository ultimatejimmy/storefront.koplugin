#!/usr/bin/env python3
"""
tools/ratings_tally.py

Fetches user ratings from Cloudflare D1 Backend Worker, with fallback to GitHub Discussions API.
Returns a dict mapping repo_id -> {"up": int, "down": int, "wilson": float}.
"""

import os
import sys
import json
import re
import urllib.request

WORKER_RATINGS_URL = "https://storefront-vote.ultimatejimmy.workers.dev/ratings"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
GITHUB_REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ultimatejimmy/storefront.koplugin")
GRAPHQL_URL = "https://api.github.com/graphql"

def fetch_ratings_from_worker():
    try:
        req = urllib.request.Request(WORKER_RATINGS_URL)
        req.add_header("User-Agent", "KOReader-Storefront-CatalogBuilder/1.0")
        req.add_header("Accept", "application/json")
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                ratings_data = {}
                for k, v in data.items():
                    try:
                        key = int(k)
                    except ValueError:
                        key = k
                    if isinstance(v, dict):
                        ratings_data[key] = {
                            "up": int(v.get("up", 0)),
                            "down": int(v.get("down", 0)),
                            "wilson": float(v.get("wilson", 0.0))
                        }
                print(f"Fetched live ratings for {len(ratings_data)} items from D1 Worker.", file=sys.stderr)
                return ratings_data
    except Exception as e:
        print(f"Warning: Could not fetch ratings from D1 worker: {e}", file=sys.stderr)
    return None

def fetch_ratings_from_github():
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
                    
                    # Extract repo_id from comment tag <!-- storefront:repo_id=12345 -->
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
            print(f"Error fetching ratings tally from GitHub: {e}", file=sys.stderr)
            break
            
    return ratings_data

def fetch_all_ratings():
    worker_data = fetch_ratings_from_worker()
    if worker_data is not None:
        return worker_data
    return fetch_ratings_from_github()

if __name__ == "__main__":
    r = fetch_all_ratings()
    print(json.dumps(r, indent=2))
