<#
.SYNOPSIS
  Upload build artifacts to a GitHub Release without the gh CLI, surviving flaky networks.

.DESCRIPTION
  Steps: token -> probe upload backend IP -> create/repair release -> upload assets with
  retries -> verify via API -> cleanup.

  ASCII-ONLY BY DESIGN: Windows PowerShell 5.1 reads BOM-less scripts as the local ANSI
  codepage, so non-ASCII literals here would break parsing. Non-ASCII release notes must be
  supplied through -NotesJson (a UTF-8 JSON file, normally written by Node).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File upload-release.ps1 `
    -Owner <owner> -Repo <repo> -Tag v1.2.3 `
    -Files "$env:TEMP\rel\App-1.2.3-setup.exe","$env:TEMP\rel\App-1.2.3-portable.exe" `
    -NotesJson "$env:TEMP\release.json"

.EXAMPLE
  # Verify only: no release creation, no uploads, no probe (safe dry run)
  powershell -NoProfile -ExecutionPolicy Bypass -File upload-release.ps1 `
    -Owner <owner> -Repo <repo> -Tag v1.2.3 -Files .\App.exe -DryRun
#>
param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Tag,
  [Parameter(Mandatory=$true)][string[]]$Files,
  [string]$NotesJson,
  [string[]]$UploadIps = @('20.205.243.161','140.82.113.3','140.82.112.3','140.82.121.3','20.205.243.166'),
  [int]$MaxAttempts = 12,
  [string]$TokenFile = (Join-Path $env:TEMP 'dsh-gh-token.txt'),
  [switch]$SkipProbe,
  [switch]$DryRun,
  [switch]$KeepToken
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# `powershell -File script.ps1 -Files a,b` hands over ONE string "a,b" (no array binding).
# Accept comma-separated, space-separated and quoted forms alike.
$Files = @($Files |
  ForEach-Object { [string]$_ -split ',' } |
  ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
  Where-Object { $_ })

$script:UA = 'dsh-skill-release-upload'
$script:H  = $null
$script:Tok = ''
$script:RelId = $null
$script:WorkingIp = $null
$script:Failures = 0

function Say([string]$m, [string]$color = 'Gray'){ Write-Host $m -ForegroundColor $color }

# ---------------------------------------------------------------- token
function Get-Token {
  if(Test-Path $TokenFile){
    $t = (Get-Content $TokenFile -Raw).Trim()
    if($t){ Say "  token: reused from $TokenFile (len=$($t.Length))"; return $t }
  }
  # .NET process with explicit stdin: piping a PowerShell string into
  # `git credential fill` fails intermittently ("missing protocol field").
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'; $psi.Arguments = 'credential fill'
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Write("protocol=https`nhost=github.com`n`n")
  $p.StandardInput.Close()
  $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(25000) | Out-Null
  $line = @($out -split "`r?`n" | Where-Object { $_ -like 'password=*' })[0]
  if(-not $line){ throw 'no cached GitHub credential found (git credential fill returned no password)' }
  $t = ($line -split '=', 2)[1].Trim()
  $t | Out-File $TokenFile -Encoding ascii -NoNewline
  Say "  token: cached from git credential manager (len=$($t.Length))"
  return $t
}

function Test-Token([string]$tok){
  $h = @{ Authorization = "token $tok"; 'User-Agent' = $script:UA; 'Accept' = 'application/vnd.github+json' }
  for($i=1; $i -le 6; $i++){
    try{
      $u = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $h -TimeoutSec 30
      Say "  api ok, user=$($u.login)" 'Green'
      $script:H = $h
      return $true
    }catch{
      Say "  api check failed (attempt $i): $($_.Exception.Message)" 'DarkYellow'
      Start-Sleep -Seconds 5
    }
  }
  return $false
}

# ---------------------------------------------------------------- api helper
function Api {
  param([string]$Method = 'GET', [string]$Uri, [byte[]]$Body, [string]$ContentType = 'application/json', [int]$Attempts = 6)
  for($i=1; $i -le $Attempts; $i++){
    try{
      if($Body){ return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:H -Body $Body -ContentType $ContentType -TimeoutSec 60 }
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $script:H -TimeoutSec 60
    }catch{
      $code = 0
      try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
      if($code -eq 404){ return $null }
      Say "  api retry $i ($Method $Uri): $($_.Exception.Message)" 'DarkYellow'
      Start-Sleep -Seconds 5
    }
  }
  return $null
}

function Get-Release { return Api -Uri "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" }
function Get-AssetNames {
  $r = Api -Uri "https://api.github.com/repos/$Owner/$Repo/releases/$script:RelId" -Attempts 4
  if(-not $r){ return @() }
  return @($r.assets | ForEach-Object { $_.name })
}
function Get-Assets {
  $r = Api -Uri "https://api.github.com/repos/$Owner/$Repo/releases/$script:RelId" -Attempts 4
  if(-not $r){ return @() }
  return @($r.assets)
}

# ---------------------------------------------------------------- upload backend probe
function Find-UploadIp {
  $probe = Join-Path $env:TEMP ("dsh-probe-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".txt")
  'probe' | Out-File $probe -Encoding ascii -NoNewline
  $probeName = Split-Path $probe -Leaf
  $url = "https://uploads.github.com/repos/$Owner/$Repo/releases/$script:RelId/assets?name=$probeName"
  foreach($ip in $UploadIps){
    $code = (& curl.exe -sS -o NUL --http1.1 --ssl-no-revoke --resolve "uploads.github.com:443:$ip" `
              --max-time 60 -w "%{http_code}" -X POST `
              -H "Authorization: token $script:Tok" -H "User-Agent: $script:UA" `
              -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/octet-stream' `
              --data-binary "@$probe" $url 2>&1 | Out-String).Trim()
    Say ("  probe {0} -> {1}" -f $ip, $code)
    if($code -match '201'){
      Say "  upload backend OK via $ip" 'Green'
      # remove the probe asset right away
      $pa = @(Get-Assets | Where-Object { $_.name -eq $probeName })
      foreach($a in $pa){ Api -Method Delete -Uri "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($a.id)" | Out-Null }
      Remove-Item $probe -Force -ErrorAction SilentlyContinue
      return $ip
    }
  }
  Remove-Item $probe -Force -ErrorAction SilentlyContinue
  return $null
}

# ---------------------------------------------------------------- upload one file
function Send-Asset {
  param([string]$Path, [string]$Name, [string]$Ip)
  $url = "https://uploads.github.com/repos/$Owner/$Repo/releases/$script:RelId/assets?name=$([uri]::EscapeDataString($Name))"
  # Windows curl.exe has no --retry-all-errors: retry here and vary the strategy.
  $strategies = @(
    @{ n = 'plain';  a = @() },
    @{ n = 'rate4M'; a = @('--limit-rate','4M') },
    @{ n = 'rate2M'; a = @('--limit-rate','2M') },
    @{ n = 'rate1M'; a = @('--limit-rate','1M') }
  )
  for($i=1; $i -le $MaxAttempts; $i++){
    if((Get-AssetNames) -contains $Name){ Say "  $Name already uploaded"; return $true }
    $st = $strategies[($i - 1) % $strategies.Count]
    if($i -gt $strategies.Count -and ($i % 4) -eq 1){ $Ip = $null }   # re-probe occasionally
    if(-not $Ip){
      $Ip = Find-UploadIp
      if(-not $Ip){ $Ip = '20.205.243.161' }
    }
    Say ("  upload {0} attempt {1} strategy={2} ip={3}" -f $Name, $i, $st.n, $Ip) 'Cyan'
    $args = @('-sS','--http1.1','--ssl-no-revoke','--resolve',"uploads.github.com:443:$Ip",'--max-time','1500') +
            $st.a +
            @('-X','POST','-H',"Authorization: token $script:Tok",'-H',"User-Agent: $script:UA",
              '-H','Accept: application/vnd.github+json','-H','Content-Type: application/octet-stream',
              '--data-binary',"@$Path",$url)
    $out = (& curl.exe @args 2>&1 | Out-String)
    if($out -match '"state"\s*:\s*"uploaded"' -or $out -match 'browser_download_url'){
      Say "  $Name UPLOAD OK (attempt $i, $($st.n))" 'Green'
      return $true
    }
    $first = (($out.Trim() -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    Say "  $Name failed: $first" 'DarkYellow'
    Start-Sleep -Seconds 12
  }
  return $false
}

# ================================================================ main
Say "== GitHub release upload: $Owner/$Repo tag=$Tag ==" 'White'

foreach($f in $Files){
  if(-not (Test-Path $f)){ Say "missing local file: $f" 'Red'; $script:Failures++ }
}
if($script:Failures -gt 0 -and -not $DryRun){ throw 'aborting: local files missing' }

Say '[1/5] credential'
$script:Tok = Get-Token
if(-not (Test-Token $script:Tok)){ throw 'GitHub API unreachable or token invalid' }

Say '[2/5] release'
$rel = Get-Release
if($rel){
  $script:RelId = $rel.id
  Say "  release found: id=$($script:RelId) draft=$($rel.draft)"
  # A deleted+re-pushed tag silently flips a release to draft; publish it again.
  if($rel.draft){
    if($DryRun){ Say '  [dry-run] would publish the draft release' 'DarkYellow' }
    else{
      Api -Method Patch -Uri "https://api.github.com/repos/$Owner/$Repo/releases/$script:RelId" `
          -Body ([Text.Encoding]::UTF8.GetBytes('{"draft": false}')) | Out-Null
      Say '  draft -> published' 'Green'
    }
  }
}else{
  if($DryRun){ Say '  [dry-run] release does not exist yet' 'DarkYellow' }
  elseif($NotesJson -and (Test-Path $NotesJson)){
    $bytes = [IO.File]::ReadAllBytes($NotesJson)
    $rel = Api -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/releases" -Body $bytes
    if(-not $rel){ throw 'release creation failed' }
    $script:RelId = $rel.id
    Say "  release created: id=$($script:RelId)" 'Green'
  }else{
    $body = [Text.Encoding]::UTF8.GetBytes((@{ tag_name = $Tag; name = $Tag; draft = $false } | ConvertTo-Json))
    $rel = Api -Method Post -Uri "https://api.github.com/repos/$Owner/$Repo/releases" -Body $body
    if(-not $rel){ throw "release for tag $Tag not found and could not be created (is the tag pushed?)" }
    $script:RelId = $rel.id
    Say "  release created (minimal): id=$($script:RelId)" 'Green'
  }
}

if($DryRun){
  Say '[3/5] assets (dry run)'
  if($script:RelId){
    foreach($a in (Get-Assets)){ Say ("  present: {0} | {1} MB | {2}" -f $a.name, [math]::Round($a.size/1MB,1), $a.state) }
  }
  if(-not $KeepToken){ Remove-Item $TokenFile -Force -ErrorAction SilentlyContinue }
  Say '[done] dry run finished' 'White'
  exit 0
}

Say '[3/5] upload backend probe'
if(-not $SkipProbe){
  $script:WorkingIp = Find-UploadIp
  if(-not $script:WorkingIp){ Say '  no IP passed the probe; uploads will retry across candidates' 'DarkYellow' }
}else{
  Say '  skipped (-SkipProbe)'
}

Say '[4/5] upload'
foreach($f in $Files){
  $name = Split-Path $f -Leaf
  if((Get-AssetNames) -contains $name){ Say "  $name already on the release, skipping"; continue }
  if(-not (Send-Asset -Path $f -Name $name -Ip $script:WorkingIp)){ Say "  $name NOT UPLOADED" 'Red'; $script:Failures++ }
}

Say '[5/5] verify'
$assets = Get-Assets
$ok = $true
foreach($f in $Files){
  $name = Split-Path $f -Leaf
  $local = (Get-Item $f).Length
  $a = @($assets | Where-Object { $_.name -eq $name })[0]
  if(-not $a){ Say "  MISSING on release: $name" 'Red'; $ok = $false; continue }
  $same = ([math]::Abs($a.size - $local) -le 1)
  Say ("  {0} | {1} MB | {2} | size-match={3}" -f $a.name, [math]::Round($a.size/1MB,1), $a.state, $same) $(if($same){'Green'}else{'Red'})
  if(-not $same){ $ok = $false }
  Say ("    {0}" -f $a.browser_download_url)
}
Say ("  release page: https://github.com/{0}/{1}/releases/tag/{2}" -f $Owner, $Repo, $Tag)

if(-not $KeepToken){ Remove-Item $TokenFile -Force -ErrorAction SilentlyContinue }
Say $(if($ok -and $script:Failures -eq 0){ 'RESULT: OK' } else { 'RESULT: INCOMPLETE' }) $(if($ok -and $script:Failures -eq 0){'Green'}else{'Red'})
exit $(if($ok -and $script:Failures -eq 0){ 0 } else { 1 })
