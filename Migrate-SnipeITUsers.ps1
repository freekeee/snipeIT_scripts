#requires -Version 5.1
<#
.SYNOPSIS
  Copies selected users and their assigned assets between Snipe-IT instances.

.DESCRIPTION
  Community-oriented, dry-run-first migration tool. It discovers selected users,
  assets assigned to them, and assets assigned to those assets (for example, a SIM
  checked out to a phone), then validates destination reference data.

  Add -Execute to create missing users/assets and recreate assignments. The source is
  never modified. Existing destination records are reused only when an exact username
  or asset-tag match is found and is compatible with the migration plan. Passwords,
  history, files, signatures and audits are not migrated.

.EXAMPLE
  .\Migrate-SnipeITUsers.ps1 -SourceUrl https://old.example.org -DestinationUrl https://new.example.org -Usernames user@example.org

.EXAMPLE
  .\Migrate-SnipeITUsers.ps1 -SourceUrl https://old.example.org -DestinationUrl https://new.example.org -Usernames user1@example.org,user2@example.org -Execute

.EXAMPLE
  .\Migrate-SnipeITUsers.ps1 -SourceUrl https://old.example.org -DestinationUrl https://new.example.org -Usernames user@example.org -SaveTokens

.EXAMPLE
  .\Migrate-SnipeITUsers.ps1 -SourceUrl https://old.example.org -DestinationUrl https://new.example.org -Usernames user@example.org -ForgetSavedTokens
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [uri] $SourceUrl,
    [Parameter(Mandatory)] [uri] $DestinationUrl,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]] $Usernames,
    [switch] $Execute,
    [switch] $SaveTokens,
    [switch] $ForgetSavedTokens,
    [string] $ReportPath = (Join-Path $PWD ('SnipeIT-User-Migration-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InstanceHash([string] $BaseUrl) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($BaseUrl.ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
    $hash
}

function Get-TokenPaths([string] $Label, [string] $BaseUrl) {
    $directory = Join-Path $env:LOCALAPPDATA 'SnipeITMigration'
    $hash = Get-InstanceHash $BaseUrl
    @(
        (Join-Path $directory "instance-$hash.credential.xml"),
        (Join-Path $directory ("{0}-{1}.credential.xml" -f $Label.ToLowerInvariant(), $hash)),
        (Join-Path $directory "source-$hash.credential.xml"),
        (Join-Path $directory "destination-$hash.credential.xml")
    ) | Select-Object -Unique
}

function Read-Token([string] $Label, [string] $BaseUrl, [bool] $Persist) {
    $tokenPaths = @(Get-TokenPaths $Label $BaseUrl)
    $existing = @($tokenPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        try {
            $secure = Import-Clixml -LiteralPath $existing[0]
            if ($secure -isnot [Security.SecureString]) { throw 'Saved object is not a SecureString.' }
            Write-Host "Using saved $Label API token for $BaseUrl"
        }
        catch {
            throw "The saved $Label token could not be decrypted. Remove it with -ForgetSavedTokens and save it again. $($_.Exception.Message)"
        }
        if ($Persist -and -not (Test-Path -LiteralPath $tokenPaths[0])) {
            $directory = Split-Path -Parent $tokenPaths[0]
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $secure | Export-Clixml -LiteralPath $tokenPaths[0] -Force
            Write-Host "Saved encrypted token for $BaseUrl using the instance-based filename."
        }
    }
    else {
        $secure = Read-Host "$Label API token" -AsSecureString
        if ($Persist) {
            $tokenPath = $tokenPaths[0]
            $directory = Split-Path -Parent $tokenPath
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $secure | Export-Clixml -LiteralPath $tokenPath -Force
            Write-Host "Saved encrypted $Label API token for this Windows user and computer."
        }
    }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Normalize-BaseUrl([uri] $Url) { $Url.AbsoluteUri.TrimEnd('/') }

$script:SourceBase = Normalize-BaseUrl $SourceUrl
$script:DestinationBase = Normalize-BaseUrl $DestinationUrl
if ($script:SourceBase -ieq $script:DestinationBase) { throw 'SourceUrl and DestinationUrl must identify different Snipe-IT instances.' }
$Usernames = @($Usernames | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($Usernames.Count -eq 0) { throw 'At least one non-empty username is required.' }
if ($ForgetSavedTokens) {
    foreach ($item in @(@{Label='SOURCE';Base=$script:SourceBase}, @{Label='DESTINATION';Base=$script:DestinationBase})) {
        $removed = 0
        foreach ($tokenPath in @(Get-TokenPaths $item.Label $item.Base)) {
            if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force; $removed++ }
        }
        Write-Host "Removed $removed saved token file(s) for $($item.Base)"
    }
    return
}
$script:SourceToken = Read-Token 'SOURCE' $script:SourceBase ([bool]$SaveTokens)
$script:DestinationToken = Read-Token 'DESTINATION' $script:DestinationBase ([bool]$SaveTokens)

function Invoke-SnipeApi {
    param(
        [ValidateSet('Source','Destination')] [string] $Instance,
        [ValidateSet('GET','POST','PATCH')] [string] $Method,
        [string] $Path,
        [hashtable] $Query,
        [object] $Body
    )
    $base = if ($Instance -eq 'Source') { $script:SourceBase } else { $script:DestinationBase }
    $token = if ($Instance -eq 'Source') { $script:SourceToken } else { $script:DestinationToken }
    $uri = "$base/api/v1/$($Path.TrimStart('/'))"
    if ($Query -and $Query.Count) {
        $pairs = foreach ($key in $Query.Keys) {
            if ($null -ne $Query[$key]) {
                '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Query[$key])
            }
        }
        if ($pairs) { $uri += '?' + ($pairs -join '&') }
    }
    $params = @{
        Uri = $uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $params.Body = $Body | ConvertTo-Json -Depth 20 -Compress }
    try { $result = Invoke-RestMethod @params }
    catch { throw "$Instance HTTP failure for $Method /api/v1/$($Path.TrimStart('/')): $($_.Exception.Message)" }
    if ($result.PSObject.Properties.Name -contains 'status' -and $result.status -eq 'error') {
        throw "$Instance API error at $Path`: $($result.messages | ConvertTo-Json -Depth 10 -Compress)"
    }
    $result
}

function Get-Rows {
    param([string]$Instance, [string]$Path, [hashtable]$Query = @{})
    $all = [Collections.Generic.List[object]]::new()
    $offset = 0
    do {
        $q = @{} + $Query
        $q.limit = 500
        $q.offset = $offset
        $response = Invoke-SnipeApi -Instance $Instance -Method GET -Path $Path -Query $q
        $rows = @($response.rows)
        foreach ($row in $rows) { $all.Add($row) }
        $offset += $rows.Count
    } while ($rows.Count -eq 500)
    $all.ToArray()
}

function Exact-One {
    param([object[]]$Items, [scriptblock]$Predicate, [string]$Description, [switch]$AllowNone)
    $matches = @($Items | Where-Object $Predicate)
    if ($matches.Count -gt 1) { throw "Ambiguous match for $Description ($($matches.Count) records)." }
    if ($matches.Count -eq 0) {
        if ($AllowNone) { return $null }
        throw "No match for $Description."
    }
    $matches[0]
}

function Scalar($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value.PSObject.Properties.Name -contains 'id') { return $Value.id }
    $Value
}

function TextValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    foreach ($name in @('name','value','display_value','datetime','date')) {
        if ($Value.PSObject.Properties.Name -contains $name) { return [string]$Value.$name }
    }
    [string]$Value
}

function PropertyValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    $Default
}

function ApiPayload($Response) {
    if ($Response.PSObject.Properties.Name -contains 'payload' -and $null -ne $Response.payload) { return $Response.payload }
    $Response
}

function New-CompliantPassword {
    $lower = 'abcdefghijkmnopqrstuvwxyz'.ToCharArray()
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $digits = '23456789'.ToCharArray()
    $symbols = '!@#$%^&*()-_=+'.ToCharArray()
    $all = $lower + $upper + $digits + $symbols
    $characters = [Collections.Generic.List[char]]::new()
    $characters.Add(($lower | Get-Random))
    $characters.Add(($upper | Get-Random))
    $characters.Add(($digits | Get-Random))
    $characters.Add(($symbols | Get-Random))
    1..28 | ForEach-Object { $characters.Add(($all | Get-Random)) }
    -join ($characters.ToArray() | Sort-Object { Get-Random })
}

function Convert-WarrantyMonths($Value, [string]$AssetTag) {
    $text = TextValue $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    [int]$months = 0
    if ($text.Trim() -match '^(\d+)\s*(?:months?)?$') {
        $months = [int]$Matches[1]
    }
    else {
        throw "Asset $AssetTag has an unrecognised warranty_months value: '$text'."
    }
    if ($months -lt 0 -or $months -gt 240) {
        throw "Asset $AssetTag has warranty_months=$months, outside Snipe-IT's permitted range of 0 to 240."
    }
    $months
}

function Convert-PurchaseCost($Value, [string]$AssetTag) {
    $text = TextValue $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $normalized = ($text.Trim() -replace '[^0-9.,-]', '') -replace ',', ''
    [decimal]$cost = 0
    $style = [Globalization.NumberStyles]::AllowDecimalPoint -bor [Globalization.NumberStyles]::AllowLeadingSign
    if (-not [decimal]::TryParse($normalized, $style, [Globalization.CultureInfo]::InvariantCulture, [ref]$cost)) {
        throw "Asset $AssetTag has an unrecognised purchase_cost value: '$text'."
    }
    if ($cost -lt 0) {
        throw "Asset $AssetTag has a negative purchase_cost value: '$text'."
    }
    $cost
}

Write-Host 'Reading users and assigned assets from the source...'
$sourceUsers = @(foreach ($username in $Usernames) {
    $response = Invoke-SnipeApi -Instance Source -Method GET -Path users -Query @{ username = $username; limit = 10 }
    Exact-One -Items @($response.rows) -Predicate { $_.username -ieq $username } -Description "source user $username"
})

$primaryAssets = [Collections.Generic.List[object]]::new()
$childAssets = [Collections.Generic.List[object]]::new()
$ownership = @{}
$parentage = @{}

foreach ($user in $sourceUsers) {
    $assets = Get-Rows -Instance Source -Path "users/$($user.id)/assets"
    foreach ($asset in $assets) {
        if (-not $ownership.ContainsKey([string]$asset.id)) {
            $primaryAssets.Add($asset)
            $ownership[[string]$asset.id] = $user.username
        }
        $children = Get-Rows -Instance Source -Path hardware -Query @{
            assigned_to = $asset.id
            assigned_type = 'App\Models\Asset'
        }
        foreach ($child in $children) {
            if (-not $parentage.ContainsKey([string]$child.id)) {
                $childAssets.Add($child)
                $parentage[[string]$child.id] = $asset.id
            }
        }
    }
}

$allSourceAssets = @($primaryAssets) + @($childAssets)

Write-Host 'Reading destination users, assets and reference data...'
$sourceModels = Get-Rows Source models
$destUsers = Get-Rows Destination users
$destAssets = Get-Rows Destination hardware
$destModels = Get-Rows Destination models
$destStatuses = Get-Rows Destination statuslabels
$destLocations = Get-Rows Destination locations
$destCompanies = Get-Rows Destination companies
$destDepartments = Get-Rows Destination departments

$userPlan = @(foreach ($source in $sourceUsers) {
    $existing = Exact-One -Items $destUsers -Predicate { $_.username -ieq $source.username } -Description "destination user $($source.username)" -AllowNone
    if ($existing -and (TextValue (PropertyValue $existing 'email')) -and (TextValue (PropertyValue $source 'email')) -and
        (TextValue (PropertyValue $existing 'email')) -ine (TextValue (PropertyValue $source 'email'))) {
        throw "Destination username $($source.username) exists with a different email address."
    }
    $userLocationName = TextValue (PropertyValue $source 'location')
    $userCompanyName = TextValue (PropertyValue $source 'company')
    $userDepartmentName = TextValue (PropertyValue $source 'department')
    $userLocation = if ($userLocationName) { Exact-One $destLocations { $_.name -ieq $userLocationName } "user location '$userLocationName'" } else { $null }
    $userCompany = if ($userCompanyName) { Exact-One $destCompanies { $_.name -ieq $userCompanyName } "user company '$userCompanyName'" } else { $null }
    $userDepartment = if ($userDepartmentName) { Exact-One $destDepartments { $_.name -ieq $userDepartmentName } "department '$userDepartmentName'" } else { $null }
    [pscustomobject]@{
        Source=$source; Destination=$existing; Location=$userLocation; Company=$userCompany; Department=$userDepartment
        Action=if ($existing) {'Reuse'} else {'Create'}
    }
})

$assetPlan = @(foreach ($source in $allSourceAssets) {
    $existing = Exact-One -Items $destAssets -Predicate { $_.asset_tag -ieq $source.asset_tag } -Description "destination asset tag $($source.asset_tag)" -AllowNone
    if ($existing -and (TextValue (PropertyValue $existing 'serial')) -ne (TextValue (PropertyValue $source 'serial'))) {
        throw "Destination asset tag $($source.asset_tag) exists with a different serial number."
    }
    $sourceModelId = Scalar $source.model
    $sourceModel = Exact-One -Items $sourceModels -Predicate { $_.id -eq $sourceModelId } -Description "source model ID $sourceModelId"
    $modelName = TextValue $sourceModel.name
    $modelNumber = TextValue (PropertyValue $sourceModel 'model_number')
    $manufacturerName = TextValue (PropertyValue $sourceModel 'manufacturer')
    $categoryName = TextValue (PropertyValue $sourceModel 'category')
    $model = Exact-One -Items $destModels -Predicate {
        $candidateManufacturer = TextValue (PropertyValue $_ 'manufacturer')
        $candidateCategory = TextValue (PropertyValue $_ 'category')
        $_.name -ieq $modelName -and
        ((-not $modelNumber) -or ((TextValue (PropertyValue $_ 'model_number')) -ieq $modelNumber)) -and
        ((-not $manufacturerName) -or ($candidateManufacturer -ieq $manufacturerName)) -and
        ((-not $categoryName) -or ($candidateCategory -ieq $categoryName))
    } -Description "model '$modelName' / number '$modelNumber' / manufacturer '$manufacturerName' / category '$categoryName'"
    $statusName = TextValue (PropertyValue $source 'status_label')
    $status = Exact-One -Items $destStatuses -Predicate { $_.name -ieq $statusName } -Description "status label '$statusName'"
    $location = $null
    $sourceLocationName = TextValue (PropertyValue $source 'rtd_location')
    if (-not $sourceLocationName) { $sourceLocationName = TextValue (PropertyValue $source 'location') }
    if ($sourceLocationName) {
        $location = Exact-One -Items $destLocations -Predicate { $_.name -ieq $sourceLocationName } -Description "location '$sourceLocationName'" -AllowNone
    }
    $company = $null
    $companyName = TextValue (PropertyValue $source 'company')
    if ($companyName) {
        $company = Exact-One -Items $destCompanies -Predicate { $_.name -ieq $companyName } -Description "company '$companyName'" -AllowNone
    }
    [pscustomobject]@{
        Source = $source; Destination = $existing; Model = $model; Status = $status
        Location = $location; Company = $company; Action = if ($existing) {'Reuse'} else {'Create'}
        Kind = if ($parentage.ContainsKey([string]$source.id)) {'Child'} else {'Primary'}
    }
})

$summary = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Source = $script:SourceBase
    Destination = $script:DestinationBase
    Mode = if ($Execute) {'Execute'} else {'DryRun'}
    Users = @($userPlan | ForEach-Object { [pscustomobject]@{
        Username=$_.Source.username; Action=$_.Action; SourceId=$_.Source.id
        DestinationId=if ($_.Destination) {$_.Destination.id} else {$null}
    } })
    Assets = @($assetPlan | ForEach-Object {
        [pscustomobject]@{
            AssetTag=$_.Source.asset_tag; Name=$_.Source.name; Serial=$_.Source.serial; Model=$_.Model.name
            Kind=$_.Kind; Action=$_.Action; AssignedUser=$ownership[[string]$_.Source.id]
            ParentSourceId=$parentage[[string]$_.Source.id]; SourceId=$_.Source.id
            DestinationId=if ($_.Destination) {$_.Destination.id} else {$null}
        }
    })
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$summary.Users | Format-Table Username,Action,SourceId,DestinationId -AutoSize
$summary.Assets | Format-Table AssetTag,Kind,Action,AssignedUser,Name,Serial -AutoSize
Write-Host "Plan written to: $ReportPath"

if (-not $Execute) {
    Write-Host 'DRY RUN COMPLETE. No destination or source records were changed.' -ForegroundColor Green
    Write-Host 'Review the report, then rerun with -Execute when ready.'
    return
}

if (-not $PSCmdlet.ShouldProcess($script:DestinationBase, "Create/reuse $($userPlan.Count) users and $($assetPlan.Count) assets and recreate assignments")) { return }

$destUserBySourceId = @{}
foreach ($item in $userPlan) {
    if ($item.Destination) { $created = $item.Destination }
    else {
        $password = New-CompliantPassword
        $u = $item.Source
        $body = @{
            first_name = $u.first_name; last_name = $u.last_name; username = $u.username
            email = $u.email; password = $password; password_confirmation = $password
            activated = [bool](PropertyValue $u 'activated' $true)
            phone = PropertyValue $u 'phone'; jobtitle = PropertyValue $u 'jobtitle'
            employee_num = PropertyValue $u 'employee_num'; notes = PropertyValue $u 'notes'
            remote = [bool](PropertyValue $u 'remote' $false); vip = [bool](PropertyValue $u 'vip' $false)
            start_date = TextValue (PropertyValue $u 'start_date'); end_date = TextValue (PropertyValue $u 'end_date')
        }
        if ($item.Location) { $body.location_id = $item.Location.id }
        if ($item.Company) { $body.company_id = $item.Company.id }
        if ($item.Department) { $body.department_id = $item.Department.id }
        $response = Invoke-SnipeApi Destination POST users -Body $body
        $created = ApiPayload $response
        Write-Host "Created user $($u.username)"
    }
    $destUserBySourceId[[string]$item.Source.id] = $created
}

function New-AssetBody($Item) {
    $a = $Item.Source
    $warrantyMonths = Convert-WarrantyMonths (PropertyValue $a 'warranty_months') ([string]$a.asset_tag)
    $purchaseCost = Convert-PurchaseCost (PropertyValue $a 'purchase_cost') ([string]$a.asset_tag)
    $body = @{
        asset_tag = $a.asset_tag; status_id = $Item.Status.id; model_id = $Item.Model.id
        name = PropertyValue $a 'name'; serial = PropertyValue $a 'serial'
        purchase_date = TextValue (PropertyValue $a 'purchase_date')
        order_number = PropertyValue $a 'order_number'
        notes = PropertyValue $a 'notes'
        requestable = [bool](PropertyValue $a 'requestable' $false)
        archived = [bool](PropertyValue $a 'archived' $false); byod = [bool](PropertyValue $a 'byod' $false)
    }
    if ($null -ne $warrantyMonths) { $body.warranty_months = [int]$warrantyMonths }
    if ($null -ne $purchaseCost) { $body.purchase_cost = [decimal]$purchaseCost }
    if ($Item.Location) { $body.rtd_location_id = $Item.Location.id }
    if ($Item.Company) { $body.company_id = $Item.Company.id }
    if ($a.PSObject.Properties.Name -contains 'custom_fields' -and $a.custom_fields) {
        foreach ($field in $a.custom_fields.PSObject.Properties) {
            $definition = $field.Value
            if ($definition.PSObject.Properties.Name -contains 'field' -and $definition.field) {
                $body[[string]$definition.field] = $definition.value
            }
        }
    }
    $body
}

$destAssetBySourceId = @{}
foreach ($item in @($assetPlan | Where-Object Kind -eq 'Primary')) {
    if ($item.Destination) { $created = $item.Destination }
    else {
        $body = New-AssetBody $item
        $response = Invoke-SnipeApi Destination POST hardware -Body $body
        $created = ApiPayload $response
        Write-Host "Created primary asset $($item.Source.asset_tag)"
    }
    $destAssetBySourceId[[string]$item.Source.id] = $created
    $username = $ownership[[string]$item.Source.id]
    $sourceUser = $sourceUsers | Where-Object username -ieq $username | Select-Object -First 1
    $destUser = $destUserBySourceId[[string]$sourceUser.id]
    $assignedTo = PropertyValue $created 'assigned_to'
    if ($assignedTo) {
        if ((Scalar $assignedTo) -ne $destUser.id) { throw "Destination asset $($item.Source.asset_tag) is already assigned to a different record." }
        Write-Host "Assignment already correct for $($item.Source.asset_tag)"
    }
    else {
        Invoke-SnipeApi Destination POST "hardware/$($created.id)/checkout" -Body @{
            checkout_to_type='user'; assigned_user=$destUser.id; status_id=$item.Status.id
            checkout_at=(TextValue (PropertyValue $item.Source 'last_checkout')); note='Migrated from previous Snipe-IT instance'
        } | Out-Null
        Write-Host "Assigned $($item.Source.asset_tag) to $username"
    }
}

foreach ($item in @($assetPlan | Where-Object Kind -eq 'Child')) {
    if ($item.Destination) { $created = $item.Destination }
    else {
        $body = New-AssetBody $item
        $response = Invoke-SnipeApi Destination POST hardware -Body $body
        $created = ApiPayload $response
        Write-Host "Created child asset $($item.Source.asset_tag)"
    }
    $destAssetBySourceId[[string]$item.Source.id] = $created
    $parent = $destAssetBySourceId[[string]$parentage[[string]$item.Source.id]]
    $assignedTo = PropertyValue $created 'assigned_to'
    if ($assignedTo) {
        if ((Scalar $assignedTo) -ne $parent.id) { throw "Destination child asset $($item.Source.asset_tag) is already assigned to a different record." }
        Write-Host "Parent assignment already correct for $($item.Source.asset_tag)"
    }
    else {
        Invoke-SnipeApi Destination POST "hardware/$($created.id)/checkout" -Body @{
            checkout_to_type='asset'; assigned_asset=$parent.id; status_id=$item.Status.id
            checkout_at=(TextValue (PropertyValue $item.Source 'last_checkout')); note='Migrated from previous Snipe-IT instance'
        } | Out-Null
        $parentTag = PropertyValue $parent 'asset_tag' "destination asset ID $($parent.id)"
        Write-Host "Assigned $($item.Source.asset_tag) to parent asset $parentTag"
    }
}

$verification = @(foreach ($source in $allSourceAssets) {
    $found = Invoke-SnipeApi Destination GET hardware -Query @{ filter = (@{asset_tag=$source.asset_tag} | ConvertTo-Json -Compress); limit=10 }
    $row = @($found.rows | Where-Object asset_tag -ieq $source.asset_tag) | Select-Object -First 1
    [pscustomobject]@{
        AssetTag=$source.asset_tag; Found=[bool]$row
        SerialMatches=((PropertyValue $row 'serial') -eq (PropertyValue $source 'serial'))
        DestinationAssignment=(TextValue (PropertyValue $row 'assigned_to'))
    }
})
$verification | Format-Table -AutoSize
if (@($verification | Where-Object { -not $_.Found -or -not $_.SerialMatches }).Count -gt 0) {
    throw 'One or more destination assets failed post-migration verification. Review the table and JSON report.'
}
$summary | Add-Member -NotePropertyName Verification -NotePropertyValue @($verification) -Force
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host 'MIGRATION COMPLETE. The source was not changed. Review the verification table and destination UI.' -ForegroundColor Green
