---
name: github-release-upload
description: Upload build artifacts (exe/zip/msi/apk) to a GitHub Release when the `gh` CLI is unavailable and the network to GitHub is unreliable — create or repair the release over the REST API, find a working uploads.github.com IP, disable schannel revocation checks, retry large uploads that die with "Connection was reset", and verify every asset by re-querying the API. Use for any "上传 release / 上传 exe 到 GitHub / publish a new release / 发布新版本" request, or when a release asset upload fails with 301, 403, connection reset, timeout, or schannel 0x80092013.
whenToUse: 用户要求把构建产物（exe / zip / 安装包）上传到 GitHub Release、发布新版本、替换 Release 里的安装包；或大文件上传到 uploads.github.com 反复失败（Connection was reset / 超时 / schannel 报错 / Release 页面上看不到附件）时使用。
---

# Upload release assets to GitHub (no `gh`, flaky network)

Windows-first workflow for attaching build artifacts to a GitHub Release. The reusable
implementation is `scripts/upload-release.ps1` in this bundle — read it before
hand-rolling the flow, and copy it into a project when the project needs its own variant.

Companion skill: `github-publish` covers creating a repository and pushing source. This
skill covers everything after the tag exists: release creation, asset upload, repair,
and verification.

## Hard rules

1. **Never print, echo, or commit the token.** Print only its length or a 4-char prefix.
   Delete the token temp file when the run ends.
2. **Verify by re-querying the API, never by `curl` exit code.** An asset is only real when
   `GET /repos/{owner}/{repo}/releases/{id}` lists it with `"state": "uploaded"` and the
   expected size. `curl` exit 0 can still mean a 301 to the wrong backend.
3. **Keep every helper `.ps1` pure ASCII.** Windows PowerShell 5.1 reads BOM-less script
   files as the local ANSI codepage (GBK on zh-CN), so Chinese string literals mangle and
   the parser dies with `Unexpected token` / `Missing closing '}'`. Put non-ASCII release
   notes in a **UTF-8 JSON payload written by Node** and pass the file path to the script.
4. **Never move or delete a tag after its release exists.** Deleting and re-pushing a tag
   silently flips the release to `draft: true`, which hides it from `/releases/latest` and
   from visitors. Repair with `PATCH /releases/{id}` `{"draft": false}`.
5. **Delete probe/test assets** you created while diagnosing, before declaring success.
6. **Do not commit artifacts to git.** Files >100 MB are rejected by `git push`; release
   assets are the only supported channel.

## Step 0 — recon in one call

```powershell
git --version; curl.exe --version | Select-Object -First 1
gh --version                                  # usually absent on Windows; do not rely on it
git -C <repo> remote -v                       # owner/repo of the target
git -C <repo> tag -l                          # confirm the tag exists locally
git -C <repo> ls-remote origin refs/heads/main refs/tags/<tag>
```

Then probe the two GitHub hosts **separately** — they fail independently:

```powershell
foreach ($h in 'github.com','api.github.com','uploads.github.com') {
  try { "$h -> " + (curl.exe -s -o NUL -w "%{http_code}" --max-time 12 "https://$h") }
  catch { "$h -> fail" }
}
```

`uploads.github.com` frequently resolves to an IP that is **dead from mainland-China
networks while the rest of GitHub works**. Resolve candidates and TCP-test them:

```powershell
(Resolve-DnsName uploads.github.com -Type A | Where-Object IPAddress).IPAddress
foreach ($ip in '20.205.243.161','140.82.113.3','140.82.112.3','140.82.121.3','20.205.243.166') {
  $r = Test-NetConnection $ip -Port 443 -WarningAction SilentlyContinue
  "$ip -> " + $(if ($r.TcpTestSucceeded) { 'open' } else { 'timeout' })
}
```

## Step 1 — token from the cached Git Credential Manager credential

Use the .NET-stdin method from `github-publish` (piping a PowerShell string into
`git credential fill` fails intermittently), then validate it before use:

```powershell
Invoke-RestMethod -Uri 'https://api.github.com/user' -TimeoutSec 20 -Headers @{
  Authorization = "token $tok"; 'User-Agent' = 'dsh-skill'; Accept = 'application/vnd.github+json'
}
```

Retry this 3–4 times with a few seconds' sleep: on flaky networks `api.github.com` returns
`Unable to connect to the remote server` / `The operation has timed out` intermittently
even with a perfectly valid token.

## Step 2 — make sure code and tag are pushed first

Push `main` and the tag **before** creating the release, and push with a retry loop —
`Recv failure: Connection was reset` and `Could not connect to server` are normal here:

```powershell
for ($i=1; $i -le 20; $i++) {
  $o1 = git -C $repo push origin main   2>&1 | Out-String
  $o2 = git -C $repo push origin $tag   2>&1 | Out-String
  if (($o1 -match 'main -> main|Everything up-to-date') -and ($o2 -match '->|Everything up-to-date')) { break }
  Start-Sleep 15
}
```

## Step 3 — create (or repair) the release

Release notes contain CJK characters, so build the request body with Node and keep the
PowerShell side ASCII-only:

```js
// make-release-payload.mjs  (run with node, then delete)
const payload = { tag_name: 'v1.2.3', name: '产品 v1.2.3 · 标题', draft: false, body: `## 更新内容\n...` };
fs.writeFileSync(path.join(os.tmpdir(), 'release.json'), JSON.stringify(payload), 'utf8');
```

```powershell
curl.exe -sS --http1.1 --max-time 90 -X POST `
  -H "Authorization: token $tok" -H 'User-Agent: dsh-skill' `
  -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' `
  --data-binary "@$env:TEMP\release.json" `
  https://api.github.com/repos/$Owner/$Repo/releases
```

`GET /releases/tags/<tag>` first; treat 404 as "create it" and 422 as "already exists".
If the release already exists but is a draft:

```powershell
# body must be UTF-8 bytes; a plain string mojibakes non-ASCII bodies
curl.exe -sS -X PATCH -H "Authorization: token $tok" -H 'Content-Type: application/json' `
  --data-binary '{\"draft\": false}' https://api.github.com/repos/$Owner/$Repo/releases/$id
```

## Step 4 — upload the assets

Endpoint (URL-encode the name; `+` must be `%2B`):

```
POST https://uploads.github.com/repos/{owner}/{repo}/releases/{id}/assets?name=<urlencoded>
Content-Type: application/octet-stream   Authorization: token <tok>
```

The working invocation — every flag earns its place:

```powershell
curl.exe -sS --http1.1 --ssl-no-revoke `
  --resolve uploads.github.com:443:$ip `
  --max-time 1500 -X POST `
  -H "Authorization: token $tok" -H 'User-Agent: dsh-skill' `
  -H 'Accept: application/vnd.github+json' `
  -H 'Content-Type: application/octet-stream' `
  --data-binary "@$file" `
  "https://uploads.github.com/repos/$Owner/$Repo/releases/$id/assets?name=$name"
```

| Flag | Why |
|---|---|
| `--ssl-no-revoke` | schannel fails the TLS handshake with `0x80092013` when it cannot reach the CRL server; disabling the revocation check makes the handshake succeed |
| `--resolve uploads.github.com:443:$ip` | DNS may hand you a dead IP; pinning a live one fixes `curl: (7) ... Timed out` |
| `--http1.1` | HTTP/2 uploads through flaky middleboxes reset more often |
| `--max-time 1500` | 150 MB at ~1 MB/s needs headroom |

**Probe the channel with a ~20-byte file first.** Read the status code — it tells you
exactly what is wrong:

```powershell
curl.exe -sS -o NUL --http1.1 --ssl-no-revoke --resolve uploads.github.com:443:$ip `
  --max-time 60 -w "$ip CODE:%{http_code}" -X POST -H "Authorization: token $tok" `
  -H 'Content-Type: application/octet-stream' --data-binary "@$probe" "$url"
```

| Code | Meaning | Action |
|---|---|---|
| `201` | correct upload backend | proceed with the real files |
| `301` (Location `https://github.com/repos/...`) | you pinned a **website** edge IP, not the upload backend | use the IP from `Resolve-DnsName uploads.github.com`, not `github.com` |
| `403` | wrong host / bad credentials | re-check token and URL |
| `000` + `Timed out` / `schannel` error | dead IP or revocation check | try the next candidate IP, keep `--ssl-no-revoke` |

**Large files die mid-send with `curl: (56) Send failure: Connection was reset`.** Windows
`curl.exe` is too old for `--retry-all-errors` (`curl: option --retry-all-errors: is
unknown`), so implement the retry loop yourself and vary the strategy per attempt:

```
attempt 1  plain
attempt 2  --limit-rate 4M
attempt 3  --limit-rate 2M
attempt 4  --limit-rate 1M
... repeat, 12–16 attempts, 10–15 s apart, cycling IPs
```

Slower throughput is the price of not being reset — a rate limit often converts a
guaranteed failure into a 2–4 minute success. Skip a file whose asset name already exists
(re-query the release between attempts; that also detects an upload that succeeded but
whose response was lost).

## Step 5 — verify (never skip)

```powershell
$r = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/$id" -Headers $h
$r.assets | ForEach-Object { "$($_.name) | $([math]::Round($_.size/1MB,1))MB | $($_.state)" }
```

Expect exactly the files you intended, `state = uploaded`, sizes matching the local files,
and `browser_download_url` of the form
`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>`. Also confirm
`/releases/latest` returns this tag with `draft = false` — that is what visitors see.

## Step 6 — cleanup

- Delete probe assets you created: `DELETE /repos/{owner}/{repo}/releases/assets/{id}`.
- Delete the token temp file, the staging copy of the artifacts, and any `*.ps1`/`*.json`
  helper you generated in `%TEMP%`.
- Confirm the repo working tree is clean (`git status --porcelain` empty) and that no
  `*.log` from the run got committed.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `curl: option --retry-all-errors: is unknown` | old bundled `curl.exe` | retry loop in PowerShell |
| `schannel: next InitializeSecurityContext failed: Unknown error (0x80092013)` | CRL/OCSP unreachable | add `--ssl-no-revoke` |
| `curl: (56) Send failure: Connection was reset` on a 100 MB+ file | unstable path for bulk transfer | retry with `--limit-rate`; small files still succeed |
| `curl: (7) Failed to connect ... Timed out` | pinned/dead IP | re-resolve, TCP-test candidates, pin an open one |
| `HTTP/1.1 301` with `Location: https://github.com/repos/...` | pinned a website edge IP | pin the IP `uploads.github.com` resolves to |
| Asset missing although the UI "looked fine" | release is a **draft**, or the response was lost | `PATCH {"draft": false}`; re-GET assets before re-uploading |
| Release silently became `draft: true` | tag was deleted and re-pushed | publish it again with `PATCH` |
| `Unexpected token` / `Missing closing '}'` parsing a helper script | non-ASCII literals read as GBK by PS 5.1 | ASCII-only scripts; non-ASCII only in a UTF-8 JSON payload |
| `cannot be loaded because running scripts is disabled` | execution policy | `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1` |
| `Invoke-RestMethod: Unable to connect / timed out` for `api.github.com` | transient network loss (independent of the upload host) | retry 3–10×, or drive the call through `curl.exe` |
| `curl` prints nothing and exits 0 | no `-w` status probe, and the request 301'd | always add `-w "%{http_code}"` while diagnosing |
| `git push` rejected: file is 130 MB | artifacts committed to git | keep binaries out of git; use release assets |
| Push loop reports success but remote unchanged | PowerShell turned git stderr into `NativeCommandError` | set `$ErrorActionPreference='Continue'`, match on stdout text, re-check with `git ls-remote` |

## Reference

- `scripts/upload-release.ps1` — parameterized, ASCII-only implementation of steps 1–6
  (token, probe, create/repair release, retrying upload, verification, cleanup). Takes
  `-Owner -Repo -Tag -Files -NotesJson`, plus `-DryRun` (read-only state check),
  `-SkipProbe`, `-MaxAttempts`, `-UploadIps`, `-KeepToken`. `-Files` accepts comma- or
  space-separated paths because `powershell -File` does not bind arrays; the token cache
  file is deleted at exit unless `-KeepToken` is passed.
- `references/network-notes.md` — the raw diagnostic transcripts these rules come from:
  the IP scan table, the exact error strings, and the decision tree for choosing a backend.
