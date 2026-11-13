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
import re
import argparse
import threading
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
BASE_URL = "https://api.github.com"
GRAPHQL_URL = "https://api.github.com/graphql"
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

# Hard floor requirements for catalog integrity
MIN_PLUGINS = 650
MIN_PATCHES = 50
MIN_FONTS = 20
MAX_DROP_RATIO = 0.15


class RateLimitTracker:
    def __init__(self):
        self.lock = threading.Lock()
        self.buckets = {
            "search": {"remaining": None, "reset": None, "limit": None},
            "core": {"remaining": None, "reset": None, "limit": None},
            "graphql": {"remaining": None, "reset": None, "limit": None},
        }
        self.search_failed = False
        self.core_failed = False

    def get_bucket(self, url):
        if "/search/" in url:
            return "search"
        if "/graphql" in url:
            return "graphql"
        return "core"

    def record_response(self, bucket, headers):
        if not headers:
            return
        rem = headers.get("x-ratelimit-remaining")
        reset_ts = headers.get("x-ratelimit-reset")
        limit = headers.get("x-ratelimit-limit")
        with self.lock:
            if rem is not None:
                try:
                    self.buckets[bucket]["remaining"] = int(rem)
                except (ValueError, TypeError):
                    pass
            if reset_ts is not None:
                try:
                    self.buckets[bucket]["reset"] = int(reset_ts)
                except (ValueError, TypeError):
                    pass
            if limit is not None:
                try:
                    self.buckets[bucket]["limit"] = int(limit)
                except (ValueError, TypeError):
                    pass

    def check_and_wait(self, bucket):
        with self.lock:
            info = self.buckets.get(bucket, {})
            remaining = info.get("remaining")
            reset_ts = info.get("reset")

        # Proactively wait if search remaining is critical
        if bucket == "search" and remaining is not None and remaining <= 1 and reset_ts:
            sleep_needed = max(1, min(70, reset_ts - int(time.time()) + 1))
            if sleep_needed > 0:
                print(f"Notice: GitHub Search API remaining={remaining}. Pausing {sleep_needed}s for reset...", file=sys.stderr)
                time.sleep(sleep_needed)
                with self.lock:
                    self.buckets[bucket]["remaining"] = None

    def get_remaining(self, bucket):
        with self.lock:
            return self.buckets.get(bucket, {}).get("remaining")


RATE_TRACKER = RateLimitTracker()


def make_request(url, method="GET", json_body=None, max_retries=3):
    bucket = RATE_TRACKER.get_bucket(url)
    
    for attempt in range(max_retries):
        RATE_TRACKER.check_and_wait(bucket)

        req_data = None
        if json_body is not None:
            req_data = json.dumps(json_body).encode("utf-8")

        req = urllib.request.Request(url, data=req_data, method=method)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Accept", "application/vnd.github+json")
        if json_body is not None:
            req.add_header("Content-Type", "application/json")
        if GITHUB_TOKEN and len(GITHUB_TOKEN.strip()) > 0:
            req.add_header("Authorization", f"Bearer {GITHUB_TOKEN.strip()}")

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                RATE_TRACKER.record_response(bucket, resp.headers)
                data = resp.read().decode("utf-8")
                return json.loads(data)
        except urllib.error.HTTPError as e:
            RATE_TRACKER.record_response(bucket, e.headers)
            rem = e.headers.get("x-ratelimit-remaining")
            reset_ts = e.headers.get("x-ratelimit-reset")
            retry_after = e.headers.get("retry-after")

            if e.code in (403, 429):
                sleep_secs = 5
                if retry_after:
                    try:
                        sleep_secs = max(1, min(90, int(retry_after)))
                    except (ValueError, TypeError):
                        pass
                elif reset_ts:
                    try:
                        wait = int(reset_ts) - int(time.time()) + 1
                        sleep_secs = max(1, min(90, wait))
                    except (ValueError, TypeError):
                        pass

                print(f"Rate limit / throttle hit ({e.code}) for {url} [bucket={bucket}, remaining={rem}]. Attempt {attempt+1}/{max_retries}. Sleeping {sleep_secs}s...", file=sys.stderr)
                time.sleep(sleep_secs)
                continue

            if e.code == 401 and GITHUB_TOKEN:
                # Retry unauthenticated as last ditch
                req2 = urllib.request.Request(url, data=req_data, method=method)
                req2.add_header("User-Agent", USER_AGENT)
                req2.add_header("Accept", "application/vnd.github+json")
                if json_body is not None:
                    req2.add_header("Content-Type", "application/json")
                try:
                    with urllib.request.urlopen(req2, timeout=15) as resp:
                        return json.loads(resp.read().decode("utf-8"))
                except Exception:
                    return None

            if e.code in (404, 409):
                return None

            print(f"HTTP Error {e.code} for {url}: {e.reason}", file=sys.stderr)
            return None
        except Exception as e:
            if attempt < max_retries - 1:
                time.sleep(1 + attempt)
                continue
            print(f"Request error for {url}: {e}", file=sys.stderr)
            return None

    if bucket == "search":
        RATE_TRACKER.search_failed = True
    elif bucket == "core":
        RATE_TRACKER.core_failed = True
    return None


def search_repositories(base_query):
    all_items = []
    # Using fork:only stars:>0 excludes useless zero-star clones while fetching active community forks
    sub_queries = [
        (base_query, 10),
        (base_query + " fork:only stars:>0", 10),
    ]

    for q, max_pages in sub_queries:
        page = 1
        per_page = 100
        while page <= max_pages:
            encoded_q = urllib.parse.quote(q)
            url = f"{BASE_URL}/search/repositories?q={encoded_q}&sort=stars&order=desc&per_page={per_page}&page={page}"
            print(f"Searching GitHub (page {page}/{max_pages}): {q}")
            res = make_request(url)
            # Gentle pacing to avoid bursting search limit (30 req/min = 1 req / 2s max, 0.5s pace)
            time.sleep(0.5)

            if not res or "items" not in res:
                if res is None:
                    print(f"Warning: Search request failed or rate-limited for query '{q}' (page {page})", file=sys.stderr)
                    RATE_TRACKER.search_failed = True
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


def is_valid_version_tag(tag):
    if not tag or not isinstance(tag, str):
        return False
    cleaned = tag.strip()
    for prefix in ["release-", "release_", "version-", "version_", "plugin-", "plugin_"]:
        if cleaned.lower().startswith(prefix):
            cleaned = cleaned[len(prefix):]
    if cleaned.lower().startswith("v") and len(cleaned) > 1 and cleaned[1].isdigit():
        cleaned = cleaned[1:]
    return bool(cleaned and cleaned[0].isdigit())


def fetch_plugin_meta_version(owner, repo, default_branch="main"):
    # 1. Zero-API-cost direct raw content fetch for default branch
    direct_paths = [
        f"https://raw.githubusercontent.com/{owner}/{repo}/{default_branch}/_meta.lua",
        f"https://raw.githubusercontent.com/{owner}/{repo}/{default_branch}/{repo}/_meta.lua",
    ]
    for raw_url in direct_paths:
        try:
            req = urllib.request.Request(raw_url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=4) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                m = re.search(r'version\s*=\s*["\']([^"\']+)["\']', body)
                if m:
                    return m.group(1).strip()
        except Exception:
            pass

    # 2. Fall back to recursive git tree on default_branch only
    url = f"{BASE_URL}/repos/{owner}/{repo}/git/trees/{default_branch}?recursive=1"
    res = make_request(url)
    if res and "tree" in res and isinstance(res["tree"], list):
        for item in res["tree"]:
            path = item.get("path", "")
            if path.endswith("_meta.lua"):
                raw_url = f"https://raw.githubusercontent.com/{owner}/{repo}/{default_branch}/{path}"
                try:
                    req = urllib.request.Request(raw_url, headers={"User-Agent": USER_AGENT})
                    with urllib.request.urlopen(req, timeout=4) as resp:
                        body = resp.read().decode("utf-8", errors="replace")
                        m = re.search(r'version\s*=\s*["\']([^"\']+)["\']', body)
                        if m:
                            return m.group(1).strip()
                except Exception:
                    pass
    return None


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
        "prerelease": rel.get("prerelease", False),
        "assets": parsed_assets,
    }


def get_releases(owner, repo):
    url = f"{BASE_URL}/repos/{owner}/{repo}/releases?per_page=10"
    return make_request(url)


def prefetch_releases_graphql(repos_to_fetch):
    """
    Prefetches releases for up to 40 repos per request using GitHub GraphQL API.
    Returns dict: {(owner.lower(), repo_name.lower()): [release_dict, ...]}
    """
    if not GITHUB_TOKEN or not repos_to_fetch:
        return {}

    results = {}
    chunk_size = 40
    repos_list = list(repos_to_fetch)

    for i in range(0, len(repos_list), chunk_size):
        chunk = repos_list[i : i + chunk_size]
        query_parts = []
        for idx, (owner, name) in enumerate(chunk):
            alias = f"repo_{idx}"
            safe_owner = json.dumps(owner)
            safe_name = json.dumps(name)
            part = f"""
            {alias}: repository(owner: {safe_owner}, name: {safe_name}) {{
                releases(first: 10, orderBy: {{field: CREATED_AT, direction: DESC}}) {{
                    nodes {{
                        tagName
                        isPrerelease
                        isDraft
                        publishedAt
                        name
                        zipballUrl
                        releaseAssets(first: 10) {{
                            nodes {{
                                name
                                downloadUrl
                                size
                                contentType
                            }}
                        }}
                    }}
                }}
            }}
            """
            query_parts.append(part)

        query = "query {\n" + "\n".join(query_parts) + "\n}"
        res = make_request(GRAPHQL_URL, method="POST", json_body={"query": query})
        if not res or "data" not in res:
            continue

        data = res["data"]
        for idx, (owner, name) in enumerate(chunk):
            alias = f"repo_{idx}"
            repo_data = data.get(alias)
            key = (owner.lower(), name.lower())
            if not repo_data or not repo_data.get("releases"):
                results[key] = []
                continue

            rel_nodes = repo_data["releases"].get("nodes", [])
            parsed_list = []
            for node in rel_nodes:
                if not node:
                    continue
                assets_nodes = (node.get("releaseAssets") or {}).get("nodes", [])
                converted_assets = []
                for a in assets_nodes:
                    converted_assets.append({
                        "name": a.get("name", ""),
                        "browser_download_url": a.get("downloadUrl", ""),
                        "size": a.get("size", 0),
                        "content_type": a.get("contentType", ""),
                    })
                converted_rel = {
                    "tag_name": node.get("tagName", ""),
                    "prerelease": bool(node.get("isPrerelease")),
                    "draft": bool(node.get("isDraft")),
                    "published_at": node.get("publishedAt") or "",
                    "name": node.get("name") or "",
                    "zipball_url": node.get("zipballUrl") or "",
                    "assets": converted_assets,
                }
                parsed_list.append(converted_rel)
            results[key] = parsed_list

    return results


def fetch_patch_files(owner, repo, default_branch="main"):
    # Try default branch first, then common names
    branches_to_try = [default_branch]
    for b in ["main", "master"]:
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
            if patch_files:
                return patch_files
    return []


def check_wiki_content(owner, repo):
    urls_to_try = [
        f"https://raw.githubusercontent.com/wiki/{owner}/{repo}/Home.md",
        f"https://raw.githubusercontent.com/wiki/{owner}/{repo}/Home",
    ]
    for url in urls_to_try:
        try:
            req = urllib.request.Request(url, method="HEAD")
            req.add_header("User-Agent", USER_AGENT)
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            continue
    return False


def process_single_repo(repo_item, is_patch, existing_record=None, prefetch_map=None):
    owner = repo_item.get("owner", {}).get("login", "")
    repo_name = repo_item.get("name", "")
    full_name = repo_item.get("full_name", f"{owner}/{repo_name}")
    default_branch = repo_item.get("default_branch", "main")
    stars = repo_item.get("stargazers_count", 0)
    is_fork = repo_item.get("fork", False)
    repo_id = repo_item.get("id", 0)

    # Exclude 0-star forks completely
    if is_fork and stars == 0:
        return None, False

    # Check wiki content (zero API quota: raw HTTP HEAD)
    has_wiki_feature = repo_item.get("has_wiki", False)
    actual_wiki_exists = False
    if has_wiki_feature:
        actual_wiki_exists = check_wiki_content(owner, repo_name)

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

    # Incremental cache check: if repo git refs haven't been pushed since cached run,
    # reuse existing releases/patches (0 API requests)
    curr_pushed = record["pushed_at"]
    if existing_record and curr_pushed and existing_record.get("pushed_at") == curr_pushed:
        if is_patch and existing_record.get("patch_files"):
            record["patch_files"] = existing_record["patch_files"]
            return record, True
        elif not is_patch and ("latest_release" in existing_record or "latest_prerelease" in existing_record):
            if "latest_release" in existing_record:
                record["latest_release"] = existing_record["latest_release"]
            if "latest_prerelease" in existing_record:
                record["latest_prerelease"] = existing_record["latest_prerelease"]
            if "version" in existing_record:
                record["version"] = existing_record["version"]
            return record, True

    if not is_patch:
        # Check prefetch map first (GraphQL), else make REST call
        releases = None
        key = (owner.lower(), repo_name.lower())
        if prefetch_map and key in prefetch_map:
            releases = prefetch_map[key]
        else:
            releases = get_releases(owner, repo_name)

        stable_rel = None
        prerelease_rel = None

        if releases and isinstance(releases, list) and len(releases) > 0:
            for r in releases:
                if not r or not isinstance(r, dict) or r.get("draft"):
                    continue
                tag = r.get("tag_name")
                if not is_valid_version_tag(tag):
                    continue
                is_pre = r.get("prerelease") or is_prerelease_tag(tag)
                if is_pre:
                    if not prerelease_rel:
                        prerelease_rel = r
                else:
                    if not stable_rel:
                        stable_rel = r
                if stable_rel and prerelease_rel:
                    break

        # Fall back to non-version scoped tags for download capability (e.g. monorepo webapp tags)
        if not stable_rel and not prerelease_rel and releases and isinstance(releases, list) and len(releases) > 0:
            for r in releases:
                if r and isinstance(r, dict) and not r.get("draft"):
                    stable_rel = r
                    break

        parsed_stable = None
        if stable_rel:
            parsed_stable = parse_release_dict(stable_rel)
            if parsed_stable:
                if not is_valid_version_tag(parsed_stable.get("tag_name")):
                    meta_ver = fetch_plugin_meta_version(owner, repo_name, default_branch)
                    if meta_ver:
                        parsed_stable["release_tag_name"] = parsed_stable["tag_name"]
                        parsed_stable["version"] = meta_ver
                        parsed_stable["tag_name"] = f"v{meta_ver}"
                        record["version"] = meta_ver
                record["latest_release"] = parsed_stable

        if prerelease_rel:
            parsed_pre = parse_release_dict(prerelease_rel)
            if parsed_pre and (not parsed_stable or parsed_pre.get("tag_name") != parsed_stable.get("tag_name")):
                if not is_valid_version_tag(parsed_pre.get("tag_name")):
                    meta_ver = fetch_plugin_meta_version(owner, repo_name, default_branch)
                    if meta_ver:
                        parsed_pre["release_tag_name"] = parsed_pre["tag_name"]
                        parsed_pre["version"] = meta_ver
                        parsed_pre["tag_name"] = f"v{meta_ver}"
                record["latest_prerelease"] = parsed_pre

    if is_patch:
        patch_files = fetch_patch_files(owner, repo_name, default_branch)
        if not patch_files:
            if existing_record and existing_record.get("patch_files"):
                record["patch_files"] = existing_record["patch_files"]
                return record, True
            return None, False  # Drop empty patch repos
        record["patch_files"] = patch_files
    else:
        # Require plugins to have at least one usable release or pre-release
        if "latest_release" not in record and "latest_prerelease" not in record:
            if existing_record and ("latest_release" in existing_record or "latest_prerelease" in existing_record):
                # Fall back to existing cached record if transient API error/rate-limit hit
                if "latest_release" in existing_record:
                    record["latest_release"] = existing_record["latest_release"]
                if "latest_prerelease" in existing_record:
                    record["latest_prerelease"] = existing_record["latest_prerelease"]
                if "version" in existing_record:
                    record["version"] = existing_record["version"]
                return record, True
            return None, False

    return record, False


def process_repos(queries, is_patch=False, existing_by_id=None):
    if existing_by_id is None:
        existing_by_id = {}
    repo_map = {}
    for q in queries:
        items = search_repositories(q)
        for item in items:
            repo_id = item.get("id")
            if repo_id and repo_id not in repo_map:
                repo_map[repo_id] = item

    print(f"Discovered {len(repo_map)} candidate repositories (is_patch={is_patch})...")

    # If plugins, batch-prefetch releases via GraphQL for cache misses
    prefetch_map = {}
    if not is_patch and GITHUB_TOKEN:
        cache_misses = []
        for repo_item in repo_map.values():
            r_id = repo_item.get("id")
            pushed_at = repo_item.get("pushed_at") or ""
            ex = existing_by_id.get(r_id)
            if not (ex and pushed_at and ex.get("pushed_at") == pushed_at and ("latest_release" in ex or "latest_prerelease" in ex)):
                owner = (repo_item.get("owner") or {}).get("login", "")
                name = repo_item.get("name", "")
                if owner and name:
                    cache_misses.append((owner, name))
        if cache_misses:
            print(f"Prefetching releases via GraphQL for {len(cache_misses)} cache-miss plugin repos...")
            prefetch_map = prefetch_releases_graphql(cache_misses)
            print(f"Prefetched releases for {len(prefetch_map)} repos via GraphQL.")

    processed = []
    cached_hits = 0
    fresh_fetches = 0
    # Use max_workers=5 to avoid secondary burst limits
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {
            executor.submit(process_single_repo, repo, is_patch, existing_by_id.get(repo.get("id")), prefetch_map): repo
            for repo in repo_map.values()
        }
        for future in as_completed(futures):
            try:
                res, from_cache = future.result()
                if res:
                    processed.append(res)
                    if from_cache:
                        cached_hits += 1
                    else:
                        fresh_fetches += 1
            except Exception as e:
                repo = futures[future]
                existing = existing_by_id.get(repo.get("id"))
                if existing:
                    processed.append(existing)
                    cached_hits += 1
                else:
                    print(f"Error processing repo: {e}", file=sys.stderr)

    # Sort deterministically by stars desc, then name
    processed.sort(key=lambda r: (-r.get("stars", 0), r.get("name", "").lower()))
    print(f"Processed {len(processed)} repositories ({cached_hits} reused from cache, {fresh_fetches} fetched remotely)")
    return processed


def load_catalog_data(source):
    if isinstance(source, str):
        if source.startswith("http://") or source.startswith("https://"):
            try:
                req = urllib.request.Request(source, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except Exception as e:
                print(f"Notice: Failed to fetch baseline from {source}: {e}", file=sys.stderr)
                return None
        elif os.path.isfile(source):
            try:
                with open(source, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"Notice: Failed to read baseline file {source}: {e}", file=sys.stderr)
                return None
    return None


def validate_catalog(catalog, baseline_stats, search_failed=False, allow_shrink=False):
    if search_failed:
        print("ERROR: Catalog build aborted because one or more GitHub search queries failed or hit rate limits!", file=sys.stderr)
        return False

    plugins = catalog.get("plugins", [])
    patches = catalog.get("patches", [])
    fonts = catalog.get("fonts", [])

    if len(plugins) < MIN_PLUGINS:
        print(f"ERROR: Built catalog plugins ({len(plugins)}) is below minimum required threshold of {MIN_PLUGINS}!", file=sys.stderr)
        return False
    if len(patches) < MIN_PATCHES:
        print(f"ERROR: Built catalog patches ({len(patches)}) is below minimum required threshold of {MIN_PATCHES}!", file=sys.stderr)
        return False
    if len(fonts) < MIN_FONTS:
        print(f"ERROR: Built catalog fonts ({len(fonts)}) is below minimum required threshold of {MIN_FONTS}!", file=sys.stderr)
        return False

    if baseline_stats and not allow_shrink:
        base_plugins = baseline_stats.get("total_plugins", 0)
        base_patches = baseline_stats.get("total_patches", 0)
        base_fonts = baseline_stats.get("total_fonts", 0)

        if base_plugins >= MIN_PLUGINS:
            allowed_floor = int(base_plugins * (1.0 - MAX_DROP_RATIO))
            if len(plugins) < allowed_floor:
                print(f"ERROR: Plugin count ({len(plugins)}) dropped by more than {int(MAX_DROP_RATIO*100)}% from healthy baseline ({base_plugins}, floor={allowed_floor})!", file=sys.stderr)
                return False

        if base_patches >= MIN_PATCHES:
            allowed_floor = int(base_patches * (1.0 - MAX_DROP_RATIO))
            if len(patches) < allowed_floor:
                print(f"ERROR: Patch count ({len(patches)}) dropped by more than {int(MAX_DROP_RATIO*100)}% from healthy baseline ({base_patches}, floor={allowed_floor})!", file=sys.stderr)
                return False

        if base_fonts >= MIN_FONTS:
            if len(fonts) < base_fonts:
                print(f"ERROR: Font count ({len(fonts)}) dropped below baseline ({base_fonts})!", file=sys.stderr)
                return False

    return True


def write_catalog_atomically(path, catalog_data):
    tmp_path = path + f".tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(catalog_data, f, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp_path, path)


def main():
    parser = argparse.ArgumentParser(description="Build KOReader Storefront catalog")
    parser.add_argument("--force", action="store_true", help="Force full rebuild ignoring cached pushed_at")
    parser.add_argument("--allow-shrink", action="store_true", help="Allow catalog item counts to shrink below baseline")
    args, _ = parser.parse_known_args()
    force_refresh = args.force or os.environ.get("FORCE_REFRESH") == "1"
    allow_shrink = args.allow_shrink or os.environ.get("ALLOW_CATALOG_SHRINK") == "1"

    print("=== KOReader Storefront Catalog Builder ===")
    if force_refresh:
        print("Notice: Full rebuild forced (--force / FORCE_REFRESH=1)")
    start_time = time.time()

    script_dir = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
    output_path = os.path.abspath(os.path.join(script_dir, "..", "catalog.json"))
    inner_output_path = os.path.abspath(os.path.join(script_dir, "..", "storefront.koplugin", "catalog.json"))

    existing_plugins_by_id = {}
    existing_patches_by_id = {}
    existing_fonts = []
    baseline_stats = {}

    # Load baseline from local files and live remote catalog to preserve healthy cache
    candidate_sources = [
        output_path,
        inner_output_path,
        "https://ultimatejimmy.github.io/storefront.koplugin/catalog.json",
    ]

    for src in candidate_sources:
        cat = load_catalog_data(src)
        if cat and isinstance(cat, dict):
            if not baseline_stats and cat.get("stats"):
                baseline_stats = cat["stats"]
            if not force_refresh:
                for p in cat.get("plugins", []):
                    p_id = p.get("id") or p.get("repo_id")
                    if p_id and (p_id not in existing_plugins_by_id or ("latest_release" in p or "latest_prerelease" in p)):
                        existing_plugins_by_id[p_id] = p
                for pt in cat.get("patches", []):
                    pt_id = pt.get("id") or pt.get("repo_id")
                    if pt_id and (pt_id not in existing_patches_by_id or pt.get("patch_files")):
                        existing_patches_by_id[pt_id] = pt
            if not existing_fonts and cat.get("fonts"):
                existing_fonts = cat["fonts"]

    print(f"Loaded existing catalog cache ({len(existing_plugins_by_id)} plugins, {len(existing_patches_by_id)} patches, {len(existing_fonts)} fonts)")
    if baseline_stats:
        print(f"Baseline catalog stats: {baseline_stats}")

    plugins = process_repos(PLUGIN_QUERIES, is_patch=False, existing_by_id=existing_plugins_by_id)
    patches = process_repos(PATCH_QUERIES, is_patch=True, existing_by_id=existing_patches_by_id)

    # Fetch latest fonts from storefront-fonts repo / local cache
    try:
        fonts_req = urllib.request.Request("https://ultimatejimmy.github.io/storefront-fonts/fonts.lite.json", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(fonts_req, timeout=5) as f_resp:
            remote_fonts_data = json.loads(f_resp.read().decode("utf-8"))
            if isinstance(remote_fonts_data, dict) and "fonts" in remote_fonts_data:
                existing_fonts = remote_fonts_data["fonts"]
                print(f"Synced {len(existing_fonts)} fonts from storefront-fonts remote feed")
    except Exception as e:
        local_sf_fonts = os.path.abspath(os.path.join(script_dir, "..", "..", "storefront-fonts", "fonts.lite.json"))
        if os.path.exists(local_sf_fonts):
            try:
                with open(local_sf_fonts, "r", encoding="utf-8") as lf:
                    lf_data = json.load(lf)
                    if isinstance(lf_data, dict) and "fonts" in lf_data:
                        existing_fonts = lf_data["fonts"]
                        print(f"Synced {len(existing_fonts)} fonts from local storefront-fonts")
            except Exception:
                pass
        if not existing_fonts:
            print(f"Notice: Using existing catalog fonts ({len(existing_fonts)}) ({e})")

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

        live_info = (
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
        return live_info

    for item in plugins + patches:
        r_info = get_rating_for_item(item)
        item["user_thumbs_up"] = int(r_info.get("up", 0))
        item["user_thumbs_down"] = int(r_info.get("down", 0))
        item["wilson_score"] = float(r_info.get("wilson", 0.0))
        item["downloads"] = int(r_info.get("downloads", 0))

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for font_item in existing_fonts:
        r_info = get_rating_for_item(font_item)
        font_item["user_thumbs_up"] = int(r_info.get("up", 0))
        font_item["user_thumbs_down"] = int(r_info.get("down", 0))
        font_item["wilson_score"] = float(r_info.get("wilson", 0.0))
        font_item["downloads"] = int(r_info.get("downloads", 0))

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

    # Integrity Gate: Verify catalog meets minimum thresholds and hasn't shrunk anomalously
    valid = validate_catalog(catalog, baseline_stats, search_failed=RATE_TRACKER.search_failed, allow_shrink=allow_shrink)
    if not valid:
        print("Integrity check FAILED. Aborting catalog update; existing catalog files preserved.", file=sys.stderr)
        sys.exit(1)

    # Write atomically
    write_catalog_atomically(output_path, catalog)
    print(f"Atomically updated outer catalog.json at {output_path}")

    if os.path.exists(os.path.dirname(inner_output_path)):
        try:
            write_catalog_atomically(inner_output_path, catalog)
            print(f"Atomically synced inner catalog.json at {inner_output_path}")
        except Exception as e:
            print(f"Warning: could not write inner catalog.json: {e}", file=sys.stderr)

    elapsed = time.time() - start_time
    print(f"Successfully generated catalog.json at {output_path} in {elapsed:.2f}s")
    print(f"Plugins: {len(plugins)}, Patches: {len(patches)}, Fonts: {len(existing_fonts)}")


if __name__ == "__main__":
    main()
