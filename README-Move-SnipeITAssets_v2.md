# Move-SnipeITAssets

`Move-SnipeITAssets.ps1` copies one or more undeployed hardware assets between Snipe-IT instances using the REST API.

## Safety model

- Dry run by default.
- Exact asset-tag selection.
- Stops if an asset is assigned to a user, location or another asset.
- Stops on missing or ambiguous reference-data matches.
- Stops if a source company is missing at the destination, unless omission is explicitly authorised.
- Reuses an exact destination asset tag only when its serial matches.
- Never modifies the source unless `-SoftDeleteSource` is explicitly supplied with `-Execute`.
- Source deletion is soft deletion and requires a typed confirmation phrase.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Snipe-IT API tokens with suitable permissions
- Destination models, manufacturers, categories, status labels, locations, companies and custom fields already configured

Tested against Snipe-IT v8.4.0. Review release notes and test in a non-production environment before using other versions.

## Dry run

```powershell
.\Move-SnipeITAssets.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -AssetTags "ASSET-100","ASSET-101"
```

## Execute

```powershell
.\Move-SnipeITAssets.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -AssetTags "ASSET-100","ASSET-101" `
  -Execute
```

Add `-SaveTokens` to store tokens encrypted with Windows DPAPI. Add `-SoftDeleteSource` only after reviewing and verifying the destination.

## Unmatched company allocations

If an asset's source company does not exist at the destination, the default
pre-flight stops without changing anything. Either create the matching company
at the destination, or deliberately copy the asset without that allocation:

```powershell
.\Move-SnipeITAssets.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -AssetTags "ASSET-100" `
  -OmitUnmatchedCompany
```

The omission produces a warning and is recorded in the JSON plan. It does not
remove or change the company allocation on the source asset.

## Limitations

This release does not migrate:

- Assigned assets or checkout relationships
- Users
- Asset-to-asset dependency trees
- Activity history
- Audit history
- Acceptance signatures
- Uploaded files or images
- Reference-data definitions

The source instance remains the historical archive unless its records are explicitly soft-deleted.

## Community use

Run a dry plan, back up both instances, review the JSON report, execute without source deletion, verify destination records in the UI, and only then consider source soft deletion.

