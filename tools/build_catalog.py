#!/usr/bin/env python3
"""
tools/build_catalog.py

Aggregates KOReader plugins and user patches from GitHub into a single catalog.json.
Can be run locally or in GitHub Actions.
Uses GITHUB_TOKEN environment variable if available for high rate-limits.
"""

import os
import sys
import json
import time
import urllib.request
import urllib.parse
from datetime import datetime, timezone

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
BASE_URL = "https://api.github.com"
USER_AGENT = "KOReader-Storefront-CatalogBuilder/1.0"

PLUGIN_QUERIES = [
    "topic:koreader-plugin",
    'in:name ".koplugin"',
]

PATCH_QUERIES = [
    "topic:koreader-user-patch",
    'in:name "KOReader.patches"',
    'in:name "koreader-patches"',
    'in:name "koreader-user-patches"',
]

rate_limit_errors = 0
MAX_RATE_LIMIT_ERRORS = 3

def make_request(url):
    global rate_limit_errors
    if rate_limit_errors >= MAX_RATE_LIMIT_ERRORS:
        return None
        
    req = urllib.request.Request(url)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Accept", "application/vnd.github+json")
    if GITHUB_TOKEN and len(GITHUB_TOKEN.strip()) > 0:
        req.add_header("Authorization", f"Bearer {GITHUB_TOKEN.strip()}")
    
    try:
        with urllib.request.urlopen(req) as resp:
            data = resp.read().decode("utf-8")
            rate_limit_errors = 0  # reset on success
            return json.loads(data)
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            rate_limit_errors += 1
            if rate_limit_errors >= MAX_RATE_LIMIT_ERRORS:
                print(f"Rate limit reached ({e.code}). Skipping further API calls in this run.", file=sys.stderr)
            return None
        if e.code == 401 and GITHUB_TOKEN:
            req2 = urllib.request.Request(url)
            req2.add_header("User-Agent", USER_AGENT)
            req2.add_header("Accept", "application/vnd.github+json")
            try:
                with urllib.request.urlopen(req2) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except Exception:
                return None
        if e.code in (404, 409):
            return None
        if e.code != 404 and e.code != 409:
            print(f"HTTP Error {e.code} for {url}: {e.reason}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Request error for {url}: {e}", file=sys.stderr)
        return None

def search_repositories(base_query):
    all_items = []
    # Search non-forks (up to 3 pages / 300 repos) and forks (up to 2 pages / 200 repos)
    sub_queries = [
        (base_query, 3),
        (base_query + " fork:only", 2),
    ]
    
    for q, max_pages in sub_queries:
        page = 1
        per_page = 100
        while page <= max_pages:
            encoded_q = urllib.parse.quote(q)
            url = f"{BASE_URL}/search/repositories?q={encoded_q}&sort=stars&order=desc&per_page={per_page}&page={page}"
            print(f"Searching GitHub (page {page}/{max_pages}): {q}")
            res = make_request(url)
            if not res or "items" not in res:
                break
            items = res.get("items", [])
            if not items:
                break
            all_items.extend(items)
            if len(items) < per_page:
                break
            page += 1
            
    return all_items

def get_latest_release(owner, repo):
    url = f"{BASE_URL}/repos/{owner}/{repo}/releases/latest"
    return make_request(url)

def fetch_patch_files(owner, repo, default_branch="HEAD"):
    url = f"{BASE_URL}/repos/{owner}/{repo}/git/trees/{default_branch}?recursive=1"
    res = make_request(url)
    if not res or "tree" not in res:
        return []
    
    patch_files = []
    for item in res["tree"]:
        path = item.get("path", "")
        if item.get("type") == "blob" and (path.endswith(".lua") or path.endswith(".lua.disabled")):
            filename = os.path.basename(path)
            patch_files.append({
                "path": path,
                "filename": filename,
                "sha": item.get("sha", ""),
                "size": item.get("size", 0),
                "download_url": f"https://raw.githubusercontent.com/{owner}/{repo}/{default_branch}/{path}",
                "branch": default_branch,
            })
    return patch_files

from concurrent.futures import ThreadPoolExecutor, as_completed

def process_single_repo(repo_item, is_patch):
    owner = repo_item.get("owner", {}).get("login", "")
    repo_name = repo_item.get("name", "")
    full_name = repo_item.get("full_name", f"{owner}/{repo_name}")
    default_branch = repo_item.get("default_branch", "main")
    stars = repo_item.get("stargazers_count", 0)
    is_fork = repo_item.get("fork", False)
    repo_id = repo_item.get("id", 0)
    
    # Prepare normalized record
    record = {
        "id": repo_id,
        "repo_id": repo_id,
        "name": repo_name,
        "owner": owner,
        "full_name": full_name,
        "description": repo_item.get("description") or "",
        "stars": stars,
        "stargazers_count": stars,
        "fork": is_fork,
        "language": repo_item.get("language") or "",
        "homepage": repo_item.get("homepage") or "",
        "default_branch": default_branch,
        "pushed_at": repo_item.get("pushed_at") or "",
        "updated_at": repo_item.get("updated_at") or "",
        "html_url": repo_item.get("html_url") or f"https://github.com/{full_name}",
    }
    
    # Fetch latest release only for non-forks or starred forks
    if not is_fork or stars > 0:
        rel = get_latest_release(owner, repo_name)
        if rel and type(rel) == dict and "tag_name" in rel:
            tag_name = rel.get("tag_name", "")
            assets = rel.get("assets", [])
            download_url = None
            for asset in assets:
                asset_name = asset.get("name", "")
                if asset_name.endswith(".zip"):
                    download_url = asset.get("browser_download_url")
                    break
            if not download_url and "zipball_url" in rel:
                download_url = rel.get("zipball_url")
                
            record["latest_release"] = {
                "tag_name": tag_name,
                "published_at": rel.get("published_at") or "",
                "download_url": download_url,
                "name": rel.get("name") or "",
            }
    
    if is_patch and (not is_fork or stars > 0):
        patch_files = fetch_patch_files(owner, repo_name, default_branch)
        record["patch_files"] = patch_files
        
    return record

def process_repos(queries, is_patch=False):
    repo_map = {}
    for q in queries:
        items = search_repositories(q)
        for item in items:
            repo_id = item.get("id")
            if repo_id and repo_id not in repo_map:
                repo_map[repo_id] = item
    
    print(f"Fetching details for {len(repo_map)} repositories (parallel)...")
    processed = []
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = [executor.submit(process_single_repo, repo, is_patch) for repo in repo_map.values()]
        for future in as_completed(futures):
            try:
                res = future.result()
                if res:
                    processed.append(res)
            except Exception as e:
                print(f"Error processing repo: {e}", file=sys.stderr)
                
    # Sort deterministically by stars desc, then name
    processed.sort(key=lambda r: (-r.get("stars", 0), r.get("name", "").lower()))
    return processed

def main():
    print("=== KOReader Storefront Catalog Builder ===")
    start_time = time.time()
    
    plugins = process_repos(PLUGIN_QUERIES, is_patch=False)
    patches = process_repos(PATCH_QUERIES, is_patch=True)
    
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    catalog = {
        "version": 1,
        "generated_at": now_iso,
        "generated_timestamp": int(time.time()),
        "stats": {
            "total_plugins": len(plugins),
            "total_patches": len(patches),
        },
        "plugins": plugins,
        "patches": patches,
    }
    
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    output_path = os.path.abspath(os.path.join(script_dir, "..", "catalog.json"))
    
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        
    elapsed = time.time() - start_time
    print(f"Successfully generated catalog.json at {output_path} in {elapsed:.2f}s")
    print(f"Plugins: {len(plugins)}, Patches: {len(patches)}")

if __name__ == "__main__":
    main()
