# Network notes — what actually goes wrong when uploading release assets from CN

Raw observations behind the rules in `SKILL.md`. All of it was reproduced on a Windows 10
host in mainland China with `gh` absent, using the cached Git Credential Manager token
(`gho_…`), `curl.exe` 8.x from System32, Windows PowerShell 5.1.

## 1. The upload backend is a different service from github.com

`uploads.github.com` resolves to a **different IP than `github.com`**, and pinning a
`github.com` IP does *not* reach the upload service — the edge answers as a website:

```
HTTP/1.1 301 Moved Permanently
Content-Length: 0
Location: https://github.com/repos/IKTNF/YanWords/releases/398311264/assets?name=probe4.txt
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

That `301` is the tell-tale that the wrong backend was hit. The real backend answers `201`
with the asset JSON.

## 2. DNS can hand you a dead IP while the API is fine

Repeated TCP-443 probes on the same /24, minutes apart:

| IP | role | result |
|---|---|---|
| `20.205.243.161` | what `uploads.github.com` resolved to | **timeout** at first, `201` (working) later |
| `20.205.243.166` | `github.com` / `api.github.com` | reachable (301 on the upload path) |
| `140.82.112.3`, `140.82.113.3`, `140.82.121.3` | github.com US | reachable (301 on the upload path, or schannel errors) |
| `20.205.243.160`, `.162`, `.163`, `.164` | neighbours | timeout / `SEC_E_WRONG_PRINCIPAL` / no answer |
| `20.205.243.165` | neighbour | `403` |
| `20.27.177.113` | other range | timeout |

Conclusions:

- The **working upload IP is the one `Resolve-DnsName uploads.github.com` returns** — pin it
  explicitly because the resolver may pick a dead sibling on a later run.
- Reachability changes over minutes. A failed run does not mean the endpoint is wrong;
  re-probe before assuming anything.
- Only `201` proves you reached the upload service.

## 3. TLS: schannel refuses the handshake before anything is uploaded

```
curl: (35) schannel: next InitializeSecurityContext failed: Unknown error (0x80092013)
curl: (35) schannel: SNI or certificate check failed: SEC_E_WRONG_PRINCIPAL (0x80090322)
curl: (35) schannel: failed to receive handshake, SSL/TLS connection failed
```

`0x80092013` is `CRYPT_E_REVOCATION_OFFLINE` — the CRL/OCSP responder is unreachable, so
schannel aborts. Adding `--ssl-no-revoke` prints `schannel: disabled server certificate
revocation checks` and the handshake proceeds to step 2/3 and completes.

`SEC_E_WRONG_PRINCIPAL` means the certificate presented does not cover the hostname — that
IP serves something else; skip it.

## 4. Small uploads succeed; large uploads are reset

The same IP and flags:

| payload | result |
|---|---|
| ~20 bytes | `CODE:201` — asset created |
| 142 MB | `curl: (56) Send failure: Connection was reset` (many times in a row) |
| 142 MB + `--limit-rate 2M` / `4M` | eventually `UPLOAD OK`, 2–4 minutes per file |

So the failure mode is **bulk-transfer instability**, not authentication or endpoint
choice. Mitigations that worked, in order of value:

1. Retry the same file many times (10–16 attempts) — a later attempt often completes.
2. Throttle with `--limit-rate` (4M → 2M → 1M). Slower is more likely to finish.
3. `--http1.1` instead of HTTP/2.
4. Re-check the asset list between attempts: an upload whose *response* was lost still
   created the asset, and re-uploading would waste another 2–4 minutes.

`curl.exe` on this host has no `--retry-all-errors`:

```
curl: option --retry-all-errors: is unknown
```

so the retry loop must live in the calling script.

## 5. Failure of one host does not imply failure of another

Within a single session, independently observed:

- `git push` → `Recv failure: Connection was reset`, then `Could not connect to server`
  (`github.com:443`), recovered after ~6 minutes of retries.
- `Invoke-RestMethod https://api.github.com/...` → `The operation has timed out`, then
  `无法连接到远程服务器`, then success on the next attempt seconds later.
- `https://uploads.github.com` → connection reset on large bodies while small bodies to the
  same host succeeded.

Therefore: wrap **every** GitHub call (API and upload) in a retry loop, and never conclude
"the token is bad" from a connection error.

## 6. Release state traps

- **Deleting and re-pushing a tag flips its release to `draft: true`.** The release stays
  published-looking in the API list (`draft` field is the only clue) but disappears from
  `/releases/latest` and from the public Releases page. Repair:
  `PATCH /repos/{owner}/{repo}/releases/{id}` with `{"draft": false}`.
- A draft release also makes `/releases/tags/{tag}` return 404 in some flows, so a "create
  release" call can appear to have failed while a draft release already exists.
- Always read back `draft` and the asset `state` before reporting success.

## 7. PowerShell 5.1 encoding traps (cost two failed runs)

A helper `.ps1` saved as UTF-8 **without BOM** containing Chinese literals is read as GBK:

```
At ...\upload-release.ps1:46 char:97
+ ... st '  (绌?' } else { $names | ForEach-Object { Write-Host "  - $_" } }
The string is missing the terminator: ".
Missing closing '}' in statement block or type definition.
```

Rules that avoid it:

- Keep every `.ps1` **ASCII-only** — no Chinese in strings or comments.
- Put CJK content (release notes, titles) in a **UTF-8 JSON payload written by Node**, and
  have the script `[IO.File]::ReadAllBytes()` it and pass the bytes to `curl --data-binary`.
- Save as UTF-8 **with BOM** if a script truly must contain non-ASCII.
- Run with `powershell -NoProfile -ExecutionPolicy Bypass -File script.ps1` — the execution
  policy blocks `.ps1` by default on this host.

## 8. Diagnosis cheat sheet

```powershell
# which upload IP works right now (201 = good, 301 = wrong backend, 000 = dead)
foreach ($ip in (Resolve-DnsName uploads.github.com -Type A | Where-Object IPAddress).IPAddress) {
  curl.exe -sS -o NUL --http1.1 --ssl-no-revoke --resolve "uploads.github.com:443:$ip" `
    --max-time 20 -w "$ip CODE:%{http_code}`n" -X POST `
    -H "Authorization: token $tok" -H 'Content-Type: application/octet-stream' `
    --data-binary "@$probe" "https://uploads.github.com/repos/$o/$r/releases/$id/assets?name=probe.txt"
}
```

Then delete the probe asset:

```powershell
Invoke-WebRequest -Method Delete -Headers $h `
  -Uri "https://api.github.com/repos/$o/$r/releases/assets/$assetId" -UseBasicParsing
```
