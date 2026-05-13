param(
  [string]$EventPath,
  [string]$SourceRepo,
  [string]$InternalName,
  [string]$ReleaseTag,
  [string]$AssetName,
  [string]$AssetUrl,
  [string]$RunUrl
)

$ErrorActionPreference = 'Stop'

function Get-StringValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return ''
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return ''
  }

  return [string]$property.Value
}

function Get-AuthHeaders {
  param([string]$Accept = 'application/vnd.github+json')

  $headers = @{
    Accept = $Accept
    'User-Agent' = 'sync-dalamud-repo'
  }

  $token = if ($env:PLUGIN_SOURCE_TOKEN) { $env:PLUGIN_SOURCE_TOKEN } else { $env:GITHUB_TOKEN }
  if (-not [string]::IsNullOrWhiteSpace($token)) {
    $headers.Authorization = "Bearer $token"
  }

  return $headers
}

function Read-EventPayload {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $event = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json

  if ($null -ne $event.client_payload) {
    return $event.client_payload
  }

  if ($null -ne $event.inputs) {
    return $event.inputs
  }

  return $null
}

function Resolve-SourceConfig {
  param(
    [string]$Repo,
    [string]$SourcesPath
  )

  if (-not (Test-Path -LiteralPath $SourcesPath)) {
    throw "Missing sources file: $SourcesPath"
  }

  $sources = Get-Content -Raw -LiteralPath $SourcesPath | ConvertFrom-Json
  $source = @($sources | Where-Object { $_.repo -eq $Repo } | Select-Object -First 1)

  if ($source.Count -eq 0) {
    throw "Source repository '$Repo' is not listed in sources.json."
  }

  if ($source[0].enabled -eq $false) {
    throw "Source repository '$Repo' is disabled in sources.json."
  }

  return $source[0]
}

function Get-ReleaseAssetUrl {
  param(
    [string]$Repo,
    [string]$Tag,
    [string]$Name,
    [string]$Pattern,
    [string]$PluginInternalName
  )

  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    return "https://github.com/$Repo/releases/download/$Tag/$([uri]::EscapeDataString($Name))"
  }

  if ([string]::IsNullOrWhiteSpace($Tag)) {
    throw "release_tag is required when asset_url is not provided."
  }

  $encodedTag = [uri]::EscapeDataString($Tag)
  $release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/$Repo/releases/tags/$encodedTag" `
    -Headers (Get-AuthHeaders)

  $assetPattern = if ([string]::IsNullOrWhiteSpace($Pattern)) { '*.zip' } else { $Pattern }
  $assets = @($release.assets | Where-Object { $_.name -like $assetPattern })

  if (-not [string]::IsNullOrWhiteSpace($PluginInternalName)) {
    $matched = @($assets | Where-Object { $_.name -like "*$PluginInternalName*" })
    if ($matched.Count -eq 1) {
      return [string]$matched[0].browser_download_url
    }
  }

  if ($assets.Count -eq 1) {
    return [string]$assets[0].browser_download_url
  }

  if ($assets.Count -eq 0) {
    throw "No release assets matched '$assetPattern' in $Repo@$Tag."
  }

  $names = ($assets | ForEach-Object { $_.name }) -join ', '
  throw "Multiple release assets matched '$assetPattern' in $Repo@$Tag. Provide asset_name or asset_url. Matches: $names"
}

function Test-PluginManifest {
  param([object]$Manifest)

  foreach ($name in @('Author', 'Name', 'InternalName', 'AssemblyVersion', 'DalamudApiLevel')) {
    if ([string]::IsNullOrWhiteSpace((Get-StringValue -Object $Manifest -Name $name))) {
      return $false
    }
  }

  return $true
}

function Find-PluginManifest {
  param(
    [string]$ExtractPath,
    [string]$PluginInternalName
  )

  $jsonFiles = Get-ChildItem -LiteralPath $ExtractPath -Recurse -File -Filter *.json |
    Where-Object {
      $_.Name -notlike '*.deps.json' -and
      $_.Name -notlike '*.runtimeconfig.json' -and
      $_.Name -ne 'package.json'
    }

  $candidates = @()

  foreach ($file in $jsonFiles) {
    try {
      $json = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    } catch {
      continue
    }

    if (Test-PluginManifest -Manifest $json) {
      $candidates += [pscustomobject]@{
        Path = $file.FullName
        Manifest = $json
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($PluginInternalName)) {
    $matched = @($candidates | Where-Object { (Get-StringValue -Object $_.Manifest -Name 'InternalName') -eq $PluginInternalName })
    if ($matched.Count -eq 1) {
      return $matched[0]
    }
  }

  if ($candidates.Count -eq 1) {
    return $candidates[0]
  }

  if ($candidates.Count -eq 0) {
    throw "No Dalamud plugin manifest was found in the downloaded zip."
  }

  $names = ($candidates | ForEach-Object { Get-StringValue -Object $_.Manifest -Name 'InternalName' }) -join ', '
  throw "Multiple plugin manifests found. Provide internal_name. Matches: $names"
}

function Copy-JsonProperty {
  param(
    [System.Collections.Specialized.OrderedDictionary]$Target,
    [object]$Source,
    [string]$Name
  )

  $property = $Source.PSObject.Properties[$Name]
  if ($null -ne $property) {
    $Target[$Name] = $property.Value
  }
}

function New-StoreEntry {
  param(
    [object]$Manifest,
    [string]$Repo,
    [string]$DownloadUrl
  )

  $entry = [ordered]@{}
  foreach ($name in @(
    'Author',
    'Name',
    'Punchline',
    'Description',
    'InternalName',
    'AssemblyVersion',
    'ApplicableVersion',
    'DalamudApiLevel',
    'Tags',
    'CategoryTags',
    'RepoUrl',
    'IconUrl',
    'ImageUrls',
    'Changelog',
    'AcceptsFeedback',
    'FeedbackMessage',
    'LoadRequiredState',
    'LoadSync',
    'CanUnloadAsync',
    'LoadPriority'
  )) {
    Copy-JsonProperty -Target $entry -Source $Manifest -Name $name
  }

  if (-not $entry.Contains('RepoUrl') -or [string]::IsNullOrWhiteSpace([string]$entry.RepoUrl)) {
    $entry['RepoUrl'] = "https://github.com/$Repo"
  }

  if (-not $entry.Contains('ApplicableVersion') -or [string]::IsNullOrWhiteSpace([string]$entry.ApplicableVersion)) {
    $entry['ApplicableVersion'] = 'any'
  }

  $entry['IsHide'] = $false
  $entry['IsTestingExclusive'] = $false
  $entry['DownloadLinkInstall'] = $DownloadUrl
  $entry['DownloadLinkUpdate'] = $DownloadUrl
  $entry['LastUpdate'] = [string][int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

  return [pscustomobject]$entry
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = ConvertTo-Json -InputObject $Value -Depth 32
  Set-Content -LiteralPath $Path -Value ($json + [Environment]::NewLine) -Encoding utf8
}

function Save-PluginAsset {
  param(
    [string]$UrlOrPath,
    [string]$Destination
  )

  if (Test-Path -LiteralPath $UrlOrPath) {
    Copy-Item -LiteralPath $UrlOrPath -Destination $Destination -Force
    return
  }

  Invoke-WebRequest -Uri $UrlOrPath -OutFile $Destination -Headers (Get-AuthHeaders)
}

$payload = Read-EventPayload -Path $EventPath

if ($payload) {
  if ([string]::IsNullOrWhiteSpace($SourceRepo)) { $SourceRepo = Get-StringValue -Object $payload -Name 'source_repo' }
  if ([string]::IsNullOrWhiteSpace($InternalName)) { $InternalName = Get-StringValue -Object $payload -Name 'internal_name' }
  if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = Get-StringValue -Object $payload -Name 'release_tag' }
  if ([string]::IsNullOrWhiteSpace($AssetName)) { $AssetName = Get-StringValue -Object $payload -Name 'asset_name' }
  if ([string]::IsNullOrWhiteSpace($AssetUrl)) { $AssetUrl = Get-StringValue -Object $payload -Name 'asset_url' }
  if ([string]::IsNullOrWhiteSpace($RunUrl)) { $RunUrl = Get-StringValue -Object $payload -Name 'run_url' }
}

if ([string]::IsNullOrWhiteSpace($SourceRepo)) {
  throw "source_repo is required."
}

$source = Resolve-SourceConfig -Repo $SourceRepo -SourcesPath (Join-Path $PSScriptRoot '..\sources.json')

if ([string]::IsNullOrWhiteSpace($AssetUrl)) {
  $AssetUrl = Get-ReleaseAssetUrl `
    -Repo $SourceRepo `
    -Tag $ReleaseTag `
    -Name $AssetName `
    -Pattern (Get-StringValue -Object $source -Name 'assetPattern') `
    -PluginInternalName $InternalName
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sync-dalamud-$([guid]::NewGuid().ToString('n'))"
$zipPath = Join-Path $tempRoot 'plugin.zip'
$extractPath = Join-Path $tempRoot 'extract'

New-Item -ItemType Directory -Force -Path $tempRoot, $extractPath | Out-Null

try {
  Write-Host "Downloading plugin asset from $AssetUrl"
  Save-PluginAsset -UrlOrPath $AssetUrl -Destination $zipPath

  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
  $found = Find-PluginManifest -ExtractPath $extractPath -PluginInternalName $InternalName
  $manifest = $found.Manifest

  $pluginInternalName = Get-StringValue -Object $manifest -Name 'InternalName'
  $pluginVersion = Get-StringValue -Object $manifest -Name 'AssemblyVersion'
  $entry = New-StoreEntry -Manifest $manifest -Repo $SourceRepo -DownloadUrl $AssetUrl

  $pluginsDir = Join-Path $PSScriptRoot '..\plugins'
  New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null

  $pluginPath = Join-Path $pluginsDir "$pluginInternalName.json"
  Write-JsonFile -Path $pluginPath -Value $entry

  $entries = @()
  foreach ($file in Get-ChildItem -LiteralPath $pluginsDir -File -Filter *.json) {
    $entries += Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
  }

  $repoFile = Join-Path $PSScriptRoot '..\dalamud-plugins.json'
  Write-JsonFile -Path $repoFile -Value @($entries | Sort-Object InternalName)

  if ($env:GITHUB_ENV) {
    "UPDATED_PLUGIN=$pluginInternalName" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "UPDATED_VERSION=$pluginVersion" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  }

  Write-Host "Updated $pluginInternalName $pluginVersion from $($found.Path)"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
