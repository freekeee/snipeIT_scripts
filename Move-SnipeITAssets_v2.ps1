#requires -Version 5.1
<#
.SYNOPSIS
  Copies selected undeployed assets between Snipe-IT instances.

.DESCRIPTION
  Asset-centred, dry-run-first migration for Snipe-IT. It preserves asset tags,
  core fields, custom fields and reference relationships by matching names and
  model metadata. Assigned assets are rejected in this release so assignments
  cannot be silently lost.

  Add -Execute to create records. Add -SoftDeleteSource only after destination
  verification if the source records should be recoverably soft-deleted.

.EXAMPLE
  .\Move-SnipeITAssets.ps1 -SourceUrl https://source.example -DestinationUrl https://dest.example -AssetTags A-100

.EXAMPLE
  .\Move-SnipeITAssets.ps1 -SourceUrl https://source.example -DestinationUrl https://dest.example -AssetTags A-100,A-101 -Execute
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)] [uri] $SourceUrl,
    [Parameter(Mandatory)] [uri] $DestinationUrl,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]] $AssetTags,
    [switch] $Execute,
    [switch] $SoftDeleteSource,
    [switch] $OmitUnmatchedCompany,
    [switch] $SaveTokens,
    [switch] $ForgetSavedTokens,
    [string] $ReportPath=(Join-Path $PWD ('SnipeIT-Asset-Move-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Normalize-BaseUrl([uri]$Url) { $Url.AbsoluteUri.TrimEnd('/') }

function Get-InstanceHash([string]$BaseUrl) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($BaseUrl.ToLowerInvariant())
        ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,16)
    }
    finally { $sha.Dispose() }
}

function Get-TokenPaths([string]$BaseUrl) {
    $directory=Join-Path $env:LOCALAPPDATA 'SnipeITMigration'
    $hash=Get-InstanceHash $BaseUrl
    @(
        (Join-Path $directory "instance-$hash.credential.xml"),
        (Join-Path $directory "source-$hash.credential.xml"),
        (Join-Path $directory "destination-$hash.credential.xml")
    )
}

function Convert-SecureStringToText([Security.SecureString]$Secure) {
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-ApiToken([string]$Label,[string]$BaseUrl,[bool]$Persist) {
    $paths=Get-TokenPaths $BaseUrl
    $secure=$null
    $loadedPath=$null
    foreach ($path in @($paths | Where-Object { Test-Path -LiteralPath $_ })) {
        try {
            $candidate=Import-Clixml -LiteralPath $path
            if ($candidate -isnot [Security.SecureString]) {
                throw 'The file does not contain a SecureString.'
            }
            $secure=$candidate
            $loadedPath=$path
            Write-Host "Using saved $Label API token for $BaseUrl"
            break
        }
        catch {
            Write-Warning "Could not decrypt saved $Label API token '$path'. It may belong to another Windows user or computer. A replacement token will be requested if no other usable saved token exists."
        }
    }
    if ($null -eq $secure) {
        $secure=Read-Host "$Label API token for $BaseUrl" -AsSecureString
    }
    if ($Persist -and $loadedPath -ne $paths[0]) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $paths[0]) -Force | Out-Null
        $secure | Export-Clixml -LiteralPath $paths[0] -Force
        Write-Host "Saved encrypted token for $BaseUrl to this Windows user profile."
    }
    Convert-SecureStringToText $secure
}

$script:SourceBase=Normalize-BaseUrl $SourceUrl
$script:DestinationBase=Normalize-BaseUrl $DestinationUrl

if ($ForgetSavedTokens) {
    foreach ($base in @($script:SourceBase,$script:DestinationBase)) {
        foreach ($path in (Get-TokenPaths $base)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "Removed saved token file for $base" }
        }
    }
    return
}

$script:SourceToken=Get-ApiToken SOURCE $script:SourceBase ([bool]$SaveTokens)
$script:DestinationToken=Get-ApiToken DESTINATION $script:DestinationBase ([bool]$SaveTokens)

function Invoke-SnipeApi {
    param(
        [ValidateSet('Source','Destination')] [string]$Instance,
        [ValidateSet('GET','POST','DELETE')] [string]$Method,
        [string]$Path,
        [hashtable]$Query=@{},
        [object]$Body=$null
    )
    $base=if($Instance -eq 'Source'){$script:SourceBase}else{$script:DestinationBase}
    $token=if($Instance -eq 'Source'){$script:SourceToken}else{$script:DestinationToken}
    $uri="$base/api/v1/$($Path.TrimStart('/'))"
    $pairs=foreach($key in $Query.Keys){if($null -ne $Query[$key]){'{0}={1}' -f [uri]::EscapeDataString([string]$key),[uri]::EscapeDataString([string]$Query[$key])}}
    if($pairs){$uri+='?'+($pairs -join '&')}
    $params=@{Uri=$uri;Method=$Method;Headers=@{Authorization="Bearer $token";Accept='application/json'};ContentType='application/json'}
    if($null -ne $Body){$params.Body=$Body|ConvertTo-Json -Depth 20 -Compress}
    try{$result=Invoke-RestMethod @params}catch{throw "$Instance HTTP failure for $Method /api/v1/$($Path.TrimStart('/')): $($_.Exception.Message)"}
    if($null -ne $result -and $result.PSObject.Properties.Name -contains 'status' -and $result.status -eq 'error'){
        throw "$Instance API error at $Path`: $($result.messages|ConvertTo-Json -Depth 10 -Compress)"
    }
    $result
}

function Get-Rows([string]$Instance,[string]$Path,[hashtable]$Query=@{}) {
    $all=[Collections.Generic.List[object]]::new();$offset=0
    do{
        $q=@{}+$Query;$q.limit=500;$q.offset=$offset
        $response=Invoke-SnipeApi $Instance GET $Path $q
        $rows=@($response.rows);foreach($row in $rows){$all.Add($row)};$offset+=$rows.Count
    }while($rows.Count -eq 500)
    $all.ToArray()
}

function PropertyValue($Object,[string]$Name,$Default=$null){if($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name};$Default}
function TextValue($Value){
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value -is [ValueType]){return [string]$Value}
    foreach($name in @('name','value','display_value','datetime','date')){
        if($Value.PSObject.Properties.Name -contains $name){return [string]$Value.$name}
    }
    [string]$Value
}
function ScalarId($Value){if($null -eq $Value){return $null};if($Value -is [ValueType]){return $Value};PropertyValue $Value 'id'}
function Exact-One([object[]]$Items,[scriptblock]$Predicate,[string]$Description,[switch]$AllowNone){
    $matches=@($Items|Where-Object $Predicate)
    if($matches.Count-gt 1){throw "Ambiguous match for $Description ($($matches.Count) records)."}
    if($matches.Count-eq 0){if($AllowNone){return $null};throw "No match for $Description."}
    $matches[0]
}
function Convert-Warranty($Value,[string]$Tag){
    $text=TextValue $Value;if([string]::IsNullOrWhiteSpace($text)){return $null}
    if($text.Trim()-notmatch '^(\d+)\s*(?:months?)?$'){throw "$Tag has unrecognised warranty_months '$text'."}
    $months=[int]$Matches[1];if($months-lt 0-or $months-gt 240){throw "$Tag warranty_months is outside 0-240."};$months
}
function Convert-Cost($Value,[string]$Tag){
    $text=TextValue $Value;if([string]::IsNullOrWhiteSpace($text)){return $null}
    $normal=(($text.Trim()-replace'[^0-9.,-]','')-replace',','');[decimal]$cost=0
    $style=[Globalization.NumberStyles]::AllowDecimalPoint -bor [Globalization.NumberStyles]::AllowLeadingSign
    if(-not [decimal]::TryParse($normal,$style,[Globalization.CultureInfo]::InvariantCulture,[ref]$cost) -or $cost -lt 0){throw "$Tag has invalid purchase_cost '$text'."};$cost
}

Write-Host 'Reading selected source assets and destination reference data...'
$sourceAssets=@(foreach($tag in $AssetTags){
    $found=Get-Rows Source hardware @{filter=(@{asset_tag=$tag}|ConvertTo-Json -Compress)}
    Exact-One @($found) {$_.asset_tag-ieq$tag} "source asset tag '$tag'"
})
foreach($asset in $sourceAssets){if(PropertyValue $asset 'assigned_to'){throw "Asset $($asset.asset_tag) is assigned. This release migrates undeployed assets only."}}

$sourceModels=Get-Rows Source models
$destAssets=Get-Rows Destination hardware
$destModels=Get-Rows Destination models
$destStatuses=Get-Rows Destination statuslabels
$destLocations=Get-Rows Destination locations
$destCompanies=Get-Rows Destination companies

$plan=@(foreach($asset in $sourceAssets){
    $existing=Exact-One $destAssets {$_.asset_tag-ieq$asset.asset_tag} "destination asset tag '$($asset.asset_tag)'" -AllowNone
    $sourceModel=Exact-One $sourceModels {$_.id-eq(ScalarId $asset.model)} "source model ID $(ScalarId $asset.model)"
    $modelName=TextValue $sourceModel.name;$modelNumber=TextValue (PropertyValue $sourceModel 'model_number')
    $manufacturer=TextValue (PropertyValue $sourceModel 'manufacturer');$category=TextValue (PropertyValue $sourceModel 'category')
    $model=Exact-One $destModels {
        $_.name -ieq $modelName -and ((-not $modelNumber) -or ((TextValue (PropertyValue $_ 'model_number')) -ieq $modelNumber)) -and
        ((-not $manufacturer) -or ((TextValue (PropertyValue $_ 'manufacturer')) -ieq $manufacturer)) -and
        ((-not $category) -or ((TextValue (PropertyValue $_ 'category')) -ieq $category))
    } "destination model '$modelName' / '$modelNumber' / '$manufacturer' / '$category'"
    $statusName=TextValue $asset.status_label
    $status=Exact-One $destStatuses {$_.name-ieq$statusName} "destination status '$statusName'"
    $location=$null;$locationName=TextValue (PropertyValue $asset 'rtd_location')
    if(-not$locationName){$locationName=TextValue (PropertyValue $asset 'location')}
    if($locationName){$location=Exact-One $destLocations {$_.name-ieq$locationName} "destination location '$locationName'"}
    $company=$null;$companyOmitted=$false;$companyName=TextValue (PropertyValue $asset 'company')
    if($companyName){
        $companyMatches=@($destCompanies|Where-Object{$_.name-ieq$companyName})
        if($companyMatches.Count -gt 1){
            Write-Host "PRE-FLIGHT STOP: Asset '$($asset.asset_tag)' has company '$companyName', but the destination contains $($companyMatches.Count) companies with that name." -ForegroundColor Red
            Write-Host 'Make the destination company names unique, then rerun. Nothing was changed.' -ForegroundColor Yellow
            return
        }
        if($companyMatches.Count -eq 0){
            if($OmitUnmatchedCompany){
                $companyOmitted=$true
                Write-Warning "Asset '$($asset.asset_tag)' references company '$companyName', which does not exist at the destination. The destination asset will have no company allocation."
            }
            else{
                Write-Host "PRE-FLIGHT STOP: Asset '$($asset.asset_tag)' is allocated to company '$companyName', but that company does not exist at the destination." -ForegroundColor Red
                Write-Host 'Nothing was changed. Either create the company at the destination, or rerun with -OmitUnmatchedCompany.' -ForegroundColor Yellow
                return
            }
        }
        else{$company=$companyMatches[0]}
    }
    if($existing){
        if((TextValue (PropertyValue $existing 'serial')) -ne (TextValue (PropertyValue $asset 'serial'))){throw "Destination tag $($asset.asset_tag) exists with a different serial."}
    }
    [pscustomobject]@{Source=$asset;Existing=$existing;Model=$model;Status=$status;Location=$location;Company=$company;SourceCompany=$companyName;CompanyOmitted=$companyOmitted;Action=if($existing){'Reuse'}else{'Create'}}
})

$report=[pscustomobject]@{GeneratedAt=(Get-Date).ToString('o');Source=$script:SourceBase;Destination=$script:DestinationBase;Mode=if($Execute){'Execute'}else{'DryRun'};Assets=@($plan|ForEach-Object{[pscustomobject]@{AssetTag=$_.Source.asset_tag;Name=$_.Source.name;Serial=$_.Source.serial;Model=$_.Model.name;Status=$_.Status.name;SourceCompany=$_.SourceCompany;DestinationCompany=if($_.Company){$_.Company.name}else{$null};CompanyOmitted=$_.CompanyOmitted;Action=$_.Action}})}
$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ReportPath -Encoding UTF8
$report.Assets|Format-Table -AutoSize;Write-Host "Plan written to: $ReportPath"
if(-not$Execute){Write-Host 'DRY RUN COMPLETE. Nothing was changed.' -ForegroundColor Green;return}
if(-not$PSCmdlet.ShouldProcess($script:DestinationBase,"Create or reuse $($plan.Count) selected assets")){return}

foreach($item in $plan){
    if($item.Existing){$created=$item.Existing;Write-Host "Reusing $($item.Source.asset_tag)"}
    else{
        $a=$item.Source;$body=@{asset_tag=$a.asset_tag;status_id=$item.Status.id;model_id=$item.Model.id;name=(PropertyValue $a 'name');serial=(PropertyValue $a 'serial');purchase_date=(TextValue (PropertyValue $a 'purchase_date'));order_number=(PropertyValue $a 'order_number');notes=(PropertyValue $a 'notes');requestable=[bool](PropertyValue $a 'requestable' $false);archived=[bool](PropertyValue $a 'archived' $false);byod=[bool](PropertyValue $a 'byod' $false)}
        $w=Convert-Warranty (PropertyValue $a 'warranty_months') ([string]$a.asset_tag);if($null-ne$w){$body.warranty_months=$w}
        $c=Convert-Cost (PropertyValue $a 'purchase_cost') ([string]$a.asset_tag);if($null-ne$c){$body.purchase_cost=$c}
        if($item.Location){$body.rtd_location_id=$item.Location.id};if($item.Company){$body.company_id=$item.Company.id}
        if(PropertyValue $a 'custom_fields'){
            foreach($field in $a.custom_fields.PSObject.Properties){$definition=$field.Value;if(PropertyValue $definition 'field'){$body[[string]$definition.field]=$definition.value}}
        }
        $response=Invoke-SnipeApi Destination POST hardware @{} $body
        $created=if($response.PSObject.Properties.Name-contains'payload'){$response.payload}else{$response}
        Write-Host "Created $($a.asset_tag)"
    }
    $verify=Get-Rows Destination hardware @{filter=(@{asset_tag=$item.Source.asset_tag}|ConvertTo-Json -Compress)}
    $match=@($verify|Where-Object{$_.asset_tag-ieq$item.Source.asset_tag})
    if($match.Count -ne 1 -or (TextValue $match[0].serial) -ne (TextValue $item.Source.serial)){throw "Destination verification failed for $($item.Source.asset_tag)."}
    Write-Host "Verified $($item.Source.asset_tag)"
}

if($SoftDeleteSource){
    if(-not$PSCmdlet.ShouldProcess($script:SourceBase,"Soft-delete $($sourceAssets.Count) verified source assets")){return}
    $phrase=Read-Host 'Type SOFT DELETE SOURCE ASSETS to continue'
    if($phrase-cne'SOFT DELETE SOURCE ASSETS'){throw 'Confirmation phrase did not match. Source was not changed.'}
    foreach($asset in $sourceAssets){
        try{Invoke-SnipeApi Source DELETE "hardware/$($asset.id)"|Out-Null;Write-Host "Soft-deleted source asset $($asset.asset_tag)"}
        catch{
            $errorRecord=$_;$remaining=Get-Rows Source hardware @{filter=(@{asset_tag=$asset.asset_tag}|ConvertTo-Json -Compress)}
            if(@($remaining|Where-Object{$_.asset_tag-ieq$asset.asset_tag}).Count){throw $errorRecord}
            Write-Warning "Delete returned an error after committing, but $($asset.asset_tag) is no longer active."
        }
    }
}
Write-Host 'ASSET MIGRATION COMPLETE.' -ForegroundColor Green
