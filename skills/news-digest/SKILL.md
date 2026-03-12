---
name: news-digest
description: Fetch top articles from Hacker News, crawl full article content via Cloudflare Browser Rendering, translate to Vietnamese, format as Obsidian-compatible Markdown, and push to GitHub as an atomic commit. Use when asked to create news digest, fetch tech news, or via scheduled cron job.
---

# News Digest

Automated tech news aggregator: fetch HN articles → crawl full content → translate to Vietnamese → publish to Obsidian GitHub repo.

## IMPORTANT: Tool Usage Rules

- Use the **`http_request` tool** for ALL network requests (HN API, Cloudflare API, GitHub API)
- Use the **`file_read` tool** to read local files (relative paths from workspace root)
- Use the **`file_write` tool** to write local files (relative paths from workspace root)
- Do NOT use the `shell` tool for any of these steps
- Do NOT write any bash scripts — use the tools directly

## IMPORTANT: GitHub API Headers

Every GitHub API request MUST include ALL THREE of these headers:
1. `Authorization: token {GITHUB_TOKEN}` — authentication
2. `Accept: application/vnd.github.v3+json` — API version
3. `User-Agent: ZeroClaw/1.0` — required by GitHub (403 without it)

---

## Step 1: Read Credentials

Use `file_read` to read these files (relative paths from workspace root). Trim whitespace/newlines from each.

| File | Variable |
|------|----------|
| `github_token.txt` | `GITHUB_TOKEN` |
| `cloudflare_account_id.txt` | `CF_ACCOUNT_ID` |
| `cloudflare_api_token.txt` | `CF_API_TOKEN` |

---

## Step 2: Fetch Hacker News Top 5 Stories

Use `http_request` to call:
- Method: GET
- URL: `https://hacker-news.firebaseio.com/v0/topstories.json`
- No auth headers needed

Parse the JSON array response. Take only the first **5** IDs.

For each of the 5 IDs, use `http_request` to call:
- Method: GET
- URL: `https://hacker-news.firebaseio.com/v0/item/{id}.json`
- No auth headers needed

Store each story's: `id`, `title`, `url`, `score`, `by`, `descendants`, `text` (if present), `time`

**Error handling:**
- If a single story fetch fails, skip it and continue with remaining stories
- If ALL story fetches fail, abort the skill and log the error

If a story has no `url` field (e.g., Ask HN), mark it as `no_external_url = true`.

---

## Step 3: Crawl Full Article Content via Cloudflare Browser Rendering

For each story that has an external `url`, use the Cloudflare Browser Rendering crawl endpoint to fetch full article content.

### 3a: Start the crawl job

Use `http_request`:
- Method: POST
- URL: `https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT_ID}/browser-rendering/crawl`
- Headers:
  - `Authorization: Bearer {CF_API_TOKEN}`
  - `Content-Type: application/json`
- Body (JSON):
```json
{
  "url": "{article_url}",
  "limit": 1,
  "formats": ["markdown"],
  "render": true,
  "rejectResourceTypes": ["image", "media", "font", "stylesheet"],
  "gotoOptions": {
    "waitUntil": "domcontentloaded",
    "timeout": 15000
  }
}
```

The response contains a job ID:
```json
{
  "success": true,
  "result": "job-id-here"
}
```

### 3b: Poll for crawl results

Use `http_request`:
- Method: GET
- URL: `https://api.cloudflare.com/client/v4/accounts/{CF_ACCOUNT_ID}/browser-rendering/crawl/{job_id}`
- Headers:
  - `Authorization: Bearer {CF_API_TOKEN}`

Poll every **3 seconds**, up to **10 attempts** (30 seconds max).

Check `result.status`:
- `"completed"` → extract `result.records[0].markdown` as article content
- `"running"` → wait and poll again
- `"errored"` / `"cancelled_*"` → treat as failed

### 3c: Process crawled content

On success:
- Extract `result.records[0].markdown`
- If content exceeds **3000 words**, truncate: keep first 3000 words, append `\n\n---\n*[Content truncated]*`

### 3d: Fallback handling

| Situation | Action |
|-----------|--------|
| Crawl completes but markdown is empty or < 50 words | Use the HN `text` field if available (strip HTML). Otherwise mark as `crawl_failed` |
| Crawl job errors or times out (all 10 poll attempts) | **Retry once** with `render: false` in the POST body (plain HTTP, faster). If still fails, use HN `text` field or mark as `crawl_failed` |
| URL points to PDF, video, or non-HTML content | Mark as `crawl_failed` |
| Story has `no_external_url` (Ask HN etc.) | Use the HN `text` field directly (strip HTML tags) |
| POST returns 401/403 | Log auth error, mark article as `crawl_failed` |
| POST returns 429 (rate limit) | Wait 5 seconds, retry once. If still 429, mark as `crawl_failed` |

**HTML stripping** (for HN `text` fields): replace `<p>` with newline, strip all other tags, decode `&gt;`→`>`, `&lt;`→`<`, `&amp;`→`&`, `&#x27;`→`'`, `&quot;`→`"`

For `crawl_failed` articles: still include them in the summary and create their individual file, but with a fallback note instead of content.

---

## Step 4: Translate Everything to Vietnamese

For each article:
- Translate the **title** to natural Vietnamese
- Translate the **full article content** (crawled markdown or HN text) to natural Vietnamese
  - Preserve markdown formatting (headings, lists, code blocks, links)
  - Keep code snippets, URLs, and technical terms (API names, library names, CLI commands) untranslated
  - Technical terms with well-known Vietnamese equivalents should use them (e.g., "machine learning" → "học máy")
  - Terms without good equivalents stay in English
- Keep original `by` (username), `score`, `url`, `time` unchanged
- Vietnamese should sound natural, not literal word-for-word

---

## Step 5: Build Markdown Files

Build all markdown files as strings in memory. Determine today's date in UTC (YYYY-MM-DD format).

**Directory structure:**
```
news/YYYY-MM-DD/
  summary.md
  {article-1-slug}.md
  {article-2-slug}.md
  ...
```

**Slug generation** from ORIGINAL English title:
- Lowercase
- Replace spaces and special characters with hyphens
- Remove non-alphanumeric characters (except hyphens)
- Collapse consecutive hyphens into one
- Trim leading/trailing hyphens
- Limit to 60 characters
- Example: `3D Knitting: The Ultimate Guide` → `3d-knitting-the-ultimate-guide`

### summary.md Template

```markdown
---
date: YYYY-MM-DD
tags: [news, technology, hacker-news]
---

# Tech News Digest - YYYY-MM-DD

Hacker News top {N} articles, translated to Vietnamese.

## 1. Original English Title

**Source**: [Original English Title](https://original-url.com)
**Score**: 1234 | **Comments**: 456 | **Author**: username | **Date**: DD/MM/YYYY
**Full article**: [[{article-slug}]]

**Vietnamese title**: Tiêu đề đã dịch sang tiếng Việt
[2-3 câu tóm tắt nội dung bài viết bằng tiếng Việt]

---

## 2. Next Article English Title...
...
```

The `[[{article-slug}]]` is an Obsidian wiki-link to the full article file in the same directory.

### Individual Article Template ({article-slug}.md)

**IMPORTANT — UTF-8 safety**: ZeroClaw truncates tool arguments at byte 300 for logging
and panics on multi-byte boundaries. The first ~350 bytes of every file MUST be pure ASCII.
That means: English tags, English H1 title, ASCII metadata lines BEFORE any Vietnamese text.

```markdown
---
date: YYYY-MM-DD
source: hacker-news
original_title: "Original English Title"
original_url: "https://original-url.com"
hn_id: 12345678
score: 1234
comments: 456
author: username
tags: [news, technology, hacker-news]
---

# Original English Title

> Source: [Original English Title](https://original-url.com)
> Score: 1234 | Comments: 456 | Author: username | Date: DD/MM/YYYY

## Vietnamese Translation

**Tieu de**: Tiêu đề đã dịch sang tiếng Việt

---

[Toàn bộ nội dung bài viết đã được dịch sang tiếng Việt, giữ nguyên định dạng markdown]

---

*Bài viết được dịch tự động bởi ZeroClaw News Digest*
*Nguồn gốc: [Original Title](https://original-url.com)*
```

For `crawl_failed` articles, replace the Vietnamese Translation content section with:
```markdown
> Warning: Could not fetch the original article content.

**Read original**: [Original Title](https://original-url.com)
```

---

## Step 6: Push to GitHub via Git Data API (Atomic Commit)

Use the `http_request` tool with the GitHub Git Data API to create ALL files in a **single atomic commit**. This is more efficient than multiple PUT calls to the Contents API.

### 6a: Get the latest commit SHA

Use `http_request`:
- Method: GET
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/ref/heads/main`
- Headers: Authorization, Accept, User-Agent (as specified above)

Extract `object.sha` → store as `LATEST_COMMIT_SHA`.

### 6b: Get the base tree SHA

Use `http_request`:
- Method: GET
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/commits/{LATEST_COMMIT_SHA}`
- Headers: Authorization, Accept, User-Agent

Extract `tree.sha` → store as `BASE_TREE_SHA`.

### 6c: Create a blob for each file

For each markdown file (summary.md + each article .md), use `http_request`:
- Method: POST
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/blobs`
- Headers: Authorization, Accept, User-Agent, Content-Type: application/json
- Body (JSON):
```json
{
  "content": "{MARKDOWN_CONTENT_AS_STRING}",
  "encoding": "utf-8"
}
```

Save each response's `sha` → `BLOB_SHA` for that file.

### 6d: Create a new tree with all files

Use `http_request`:
- Method: POST
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/trees`
- Headers: Authorization, Accept, User-Agent, Content-Type: application/json
- Body (JSON):
```json
{
  "base_tree": "{BASE_TREE_SHA}",
  "tree": [
    {
      "path": "news/YYYY-MM-DD/summary.md",
      "mode": "100644",
      "type": "blob",
      "sha": "{BLOB_SHA_SUMMARY}"
    },
    {
      "path": "news/YYYY-MM-DD/{article-1-slug}.md",
      "mode": "100644",
      "type": "blob",
      "sha": "{BLOB_SHA_1}"
    }
  ]
}
```

Include one entry per file. Extract response `sha` → `NEW_TREE_SHA`.

### 6e: Create the commit

Use `http_request`:
- Method: POST
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/commits`
- Headers: Authorization, Accept, User-Agent, Content-Type: application/json
- Body (JSON):
```json
{
  "message": "feat: news digest YYYY-MM-DD",
  "tree": "{NEW_TREE_SHA}",
  "parents": ["{LATEST_COMMIT_SHA}"]
}
```

Extract `sha` → `NEW_COMMIT_SHA`.

### 6f: Update the branch reference

Use `http_request`:
- Method: PATCH
- URL: `https://api.github.com/repos/trankhacvy/my-notes/git/refs/heads/main`
- Headers: Authorization, Accept, User-Agent, Content-Type: application/json
- Body (JSON):
```json
{
  "sha": "{NEW_COMMIT_SHA}"
}
```

If successful, log the commit SHA. If any step fails, log the error and stop.

---

## Error Handling Summary

| Step | Error | Action |
|------|-------|--------|
| HN story fetch | Single story fails | Skip it, continue with remaining |
| HN story fetch | All stories fail | Abort skill, log error |
| Cloudflare crawl POST | 401/403 auth error | Log error, mark article as `crawl_failed` |
| Cloudflare crawl POST | 429 rate limit | Wait 5s, retry once. If still 429, mark as `crawl_failed` |
| Cloudflare crawl poll | Timeout (10 attempts) | Retry once with `render: false`. If still fails, mark as `crawl_failed` |
| Cloudflare crawl result | Empty content (< 50 words) | Use HN `text` fallback or mark as `crawl_failed` |
| GitHub push | Any step fails | Log error and stop (next run retries with fresh data) |

---

## Additional Sources (Extensible)

Currently active:
- [x] **Hacker News** — `hacker-news.firebaseio.com`
- [ ] Reddit r/programming (planned)
- [ ] Dev.to (planned)

---

## Notes

- Use UTC date for all timestamps and filenames
- The `news/` directory in GitHub is auto-created on first push
- All translated Vietnamese should sound natural, not literal
- Keep code snippets, URLs, and well-known technical terms untranslated
- Article content is capped at 3000 words to manage token costs and file size
- If the GitHub push fails, log the error and stop (next run retries with fresh data)
