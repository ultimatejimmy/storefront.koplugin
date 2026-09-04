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
    # Run each query twice: once for all repos (includes non-forks by default),
    # and once with fork:true to also capture fork-only repos (including 0-star forks).
    sub_queries = [
        (base_query, 10),
        (base_query + " fork:true", 10),
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

def is_prerelease_tag(tag):
    if not tag or not isinstance(tag, str):
        return False
    tag_lower = tag.lower()
    for kw in ["alpha", "beta", "rc", "dev", "preview", "test"]:
        if kw in tag_lower:
            return True
    return False

def parse_release_dict(rel):
    if not rel or not isinstance(rel, dict) or "tag_name" not in rel:
        return None
    tag_name = rel.get("tag_name", "")
    assets = rel.get("assets", [])
    parsed_assets = []
    download_url = None
    for asset in assets:
        asset_name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        if asset_name and url and asset_name.lower().endswith(".zip"):
            parsed_assets.append({
                "name": asset_name,
                "browser_download_url": url,
                "size": asset.get("size", 0),
                "content_type": asset.get("content_type", ""),
            })
            if not download_url:
                download_url = url
    if not download_url and "zipball_url" in rel:
        download_url = rel.get("zipball_url")
    return {
        "tag_name": tag_name,
        "published_at": rel.get("published_at") or "",
        "download_url": download_url,
        "name": rel.get("name") or "",
        "body": rel.get("body") or "",
        "prerelease": rel.get("prerelease", False),
        "assets": parsed_assets,
    }

def get_releases(owner, repo):
    url = f"{BASE_URL}/repos/{owner}/{repo}/releases?per_page=5"
    return make_request(url)

def get_latest_release(owner, repo):
    url = f"{BASE_URL}/repos/{owner}/{repo}/releases/latest"
    return make_request(url)

def fetch_patch_files(owner, repo, default_branch="main"):
    branches_to_try = [default_branch]
    for b in ["main", "master", "HEAD"]:
        if b not in branches_to_try:
            branches_to_try.append(b)

    for branch in branches_to_try:
        url = f"{BASE_URL}/repos/{owner}/{repo}/git/trees/{branch}?recursive=1"
        res = make_request(url)
        if res and "tree" in res and isinstance(res["tree"], list):
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
                        "download_url": f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}",
                        "branch": branch,
                    })
            return patch_files
    return []

from concurrent.futures import ThreadPoolExecutor, as_completed

def check_wiki_content(owner, repo):
    """
    Checks if the wiki actually has a Home page, filtering out repos 
    that just have the wiki feature enabled but no content.
    """
    urls_to_try = [
        f"https://raw.githubusercontent.com/wiki/{owner}/{repo}/Home.md",
        f"https://raw.githubusercontent.com/wiki/{owner}/{repo}/Home"
    ]
    for url in urls_to_try:
        try:
            # Use HEAD request to save bandwidth and time
            req = urllib.request.Request(url, method="HEAD")
            req.add_header("User-Agent", USER_AGENT)
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            continue
    return False

def process_single_repo(repo_item, is_patch):
    owner = repo_item.get("owner", {}).get("login", "")
    repo_name = repo_item.get("name", "")
    full_name = repo_item.get("full_name", f"{owner}/{repo_name}")
    default_branch = repo_item.get("default_branch", "main")
    stars = repo_item.get("stargazers_count", 0)
    is_fork = repo_item.get("fork", False)
    repo_id = repo_item.get("id", 0)
    
    # Check if the feature is on, and if so, verify it actually has content
    has_wiki_feature = repo_item.get("has_wiki", False)
    actual_wiki_exists = False
    if has_wiki_feature:
        actual_wiki_exists = check_wiki_content(owner, repo_name)

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
        "has_wiki": actual_wiki_exists,
        "pushed_at": repo_item.get("pushed_at") or "",
        "updated_at": repo_item.get("updated_at") or "",
        "html_url": repo_item.get("html_url") or f"https://github.com/{full_name}",
    }
    
    # Fetch latest release & pre-release only for non-forks or starred forks
    if not is_fork or stars > 0:
        releases = get_releases(owner, repo_name)
        stable_rel = None
        prerelease_rel = None
        if releases and isinstance(releases, list) and len(releases) > 0:
            for r in releases:
                if not r or not isinstance(r, dict) or r.get("draft"):
                    continue
                is_pre = r.get("prerelease") or is_prerelease_tag(r.get("tag_name"))
                if is_pre:
                    if not prerelease_rel:
                        prerelease_rel = r
                else:
                    if not stable_rel:
                        stable_rel = r
                if stable_rel and prerelease_rel:
                    break
        else:
            stable_rel = get_latest_release(owner, repo_name)

        if stable_rel:
            parsed_stable = parse_release_dict(stable_rel)
            if parsed_stable:
                record["latest_release"] = parsed_stable

        if prerelease_rel:
            parsed_pre = parse_release_dict(prerelease_rel)
            if parsed_pre and (not parsed_stable or parsed_pre.get("tag_name") != parsed_stable.get("tag_name")):
                record["latest_prerelease"] = parsed_pre
    
    if is_patch:
        patch_files = fetch_patch_files(owner, repo_name, default_branch)
        record["patch_files"] = patch_files or []
        
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
    
    # Fetch live ratings and bake into catalog items
    try:
        from ratings_tally import fetch_all_ratings
        ratings_data = fetch_all_ratings() or {}
    except Exception as e:
        print(f"Warning: could not import/fetch ratings_tally: {e}", file=sys.stderr)
        ratings_data = {}

    def get_rating_for_item(item):
        r_id = item.get("id") or item.get("repo_id")
        full_name = item.get("full_name") or ""
        owner = item.get("owner") or ""
        name = item.get("name") or ""
        author_key = f"{owner}/{name}" if owner and name else ""
        clean_name = name[:-9] if name.endswith(".koplugin") else name
        clean_key = f"{owner}/{clean_name}" if owner and name else ""

        return (
            ratings_data.get(r_id)
            or (isinstance(r_id, str) and r_id.isdigit() and ratings_data.get(int(r_id)))
            or (isinstance(r_id, int) and ratings_data.get(str(r_id)))
            or (full_name and ratings_data.get(full_name))
            or (full_name and ratings_data.get(full_name.lower()))
            or (author_key and ratings_data.get(author_key))
            or (author_key and ratings_data.get(author_key.lower()))
            or (clean_key and ratings_data.get(clean_key))
            or (clean_key and ratings_data.get(clean_key.lower()))
            or {}
        )

    for item in plugins + patches:
        r_info = get_rating_for_item(item)
        item["user_thumbs_up"] = int(r_info.get("up", 0))
        item["user_thumbs_down"] = int(r_info.get("down", 0))
        item["wilson_score"] = float(r_info.get("wilson", 0.0))

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    output_path = os.path.abspath(os.path.join(script_dir, "..", "catalog.json"))
    
    # Preserve fonts array if it exists in the current catalog.json
    existing_fonts = []
    if os.path.exists(output_path):
        try:
            with open(output_path, "r", encoding="utf-8") as f:
                old_catalog = json.load(f)
                if "fonts" in old_catalog:
                    existing_fonts = old_catalog["fonts"]
        except Exception as e:
            print(f"Warning: could not read existing catalog to preserve fonts: {e}")

    for font_item in existing_fonts:
        r_info = get_rating_for_item(font_item)
        font_item["user_thumbs_up"] = int(r_info.get("up", 0))
        font_item["user_thumbs_down"] = int(r_info.get("down", 0))
        font_item["wilson_score"] = float(r_info.get("wilson", 0.0))
            
    catalog = {
        "version": 1,
        "generated_at": now_iso,
        "generated_timestamp": int(time.time()),
        "stats": {
            "total_plugins": len(plugins),
            "total_patches": len(patches),
            "total_fonts": len(existing_fonts),
        },
        "fonts": existing_fonts,
        "plugins": plugins,
        "patches": patches,
    }
    
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        
    inner_output_path = os.path.abspath(os.path.join(script_dir, "..", "storefront.koplugin", "catalog.json"))
    if os.path.exists(os.path.dirname(inner_output_path)):
        try:
            with open(inner_output_path, "w", encoding="utf-8") as f:
                json.dump(catalog, f, indent=2, ensure_ascii=False)
            print(f"Synced catalog.json to inner plugin folder at {inner_output_path}")
        except Exception as e:
            print(f"Warning: could not write inner catalog.json: {e}")
            
    elapsed = time.time() - start_time
    print(f"Successfully generated catalog.json at {output_path} in {elapsed:.2f}s")
    print(f"Plugins: {len(plugins)}, Patches: {len(patches)}")

if __name__ == "__main__":
    main()
