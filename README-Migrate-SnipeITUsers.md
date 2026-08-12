# Migrate-SnipeITUsers

`Migrate-SnipeITUsers.ps1` copies selected Snipe-IT users, their directly assigned hardware assets, and one level of assets checked out to those assets. A common example is a laptop and phone assigned to a user, with a SIM asset assigned to the phone.

The source instance is read-only. Removing successfully migrated source records is deliberately kept outside this tool so destination verification remains a separate decision.

## Safety model

- Dry run by default.
- Usernames must be supplied explicitly.
- Stops on missing or ambiguous users, models, status labels, locations, companies or departments.
- Matches models using name, model number, manufacturer and category where those values exist.
- Reuses destination users only by exact username and rejects a conflicting email address.
- Reuses destination assets only by exact asset tag and rejects a conflicting serial number.
- Rejects reused assets that are assigned to a different destination record.
- Preserves the source instance unchanged.
- Writes a JSON plan before making changes.
- Uses PowerShell confirmation before execution.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Snipe-IT API tokens with permission to read the source and create or check out records at the destination
- Matching destination reference data, including models, manufacturers, categories, status labels, locations, companies, departments and custom fields
- A current backup of both instances

Tested against Snipe-IT v8.4.0. Review Snipe-IT release notes and test against non-production data before using another version.

## Dry run

```powershell
.\Migrate-SnipeITUsers.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -Usernames "user1@example.org","user2@example.org"
```

The dry run reads both systems, validates relationships and reference data, displays the proposed actions, and creates a timestamped JSON report. It does not modify either instance.

## Execute

After reviewing the report and taking backups:

```powershell
.\Migrate-SnipeITUsers.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -Usernames "user1@example.org","user2@example.org" `
  -Execute
```

The script creates or safely reuses destination users and assets, checks primary assets out to their users, and checks child assets out to their parent assets.

## Secure API-token storage

Add `-SaveTokens` on the first run:

```powershell
.\Migrate-SnipeITUsers.ps1 `
  -SourceUrl "https://source.example" `
  -DestinationUrl "https://destination.example" `
  -Usernames "user@example.org" `
  -SaveTokens
```

Tokens are saved under `%LOCALAPPDATA%\SnipeITMigration` using Windows DPAPI encryption. They can normally be decrypted only by the same Windows account on the same computer. Storage is keyed to each instance URL, so the same token is reused when migration direction is reversed.

Remove saved tokens with `-ForgetSavedTokens`. The mandatory username parameter is still required because PowerShell validates parameters before the script runs.

## Data copied

Users:

- First name, last name, username and email
- Activated state, phone, job title, employee number and notes
- Remote and VIP flags
- Start and end dates
- Location, company and department relationships

Assets:

- Asset tag, name, serial, model and status
- Purchase date, purchase cost, warranty months and order number
- Notes, requestable, archived and BYOD flags
- Ready-to-deploy location and company
- Asset custom-field values returned by the API
- User-to-asset and one-level asset-to-asset checkout relationships

## Deliberate limitations

This tool does not migrate:

- Passwords or authentication secrets
- User groups, permissions or role assignments
- Licences, accessories, consumables or components
- Activity history or checkout history beyond recreating the current assignment
- Audit history
- Acceptance signatures
- Uploaded files, images or attachments
- Reference-data definitions
- Asset dependency levels deeper than one child level
- Source deletion

New destination users receive a generated random password solely to satisfy Snipe-IT user-creation validation. The password is not displayed or retained by the script. Administrators should use their normal password-reset or identity-provider process if interactive Snipe-IT access is required.

## Recommended workflow

1. Back up both Snipe-IT instances.
2. Confirm matching reference data exists at the destination.
3. Run the dry plan.
4. Review the console tables and JSON report.
5. Run with `-Execute`, without deleting source data.
6. Verify users, asset fields and every assignment in the destination UI.
7. Use a separately reviewed cleanup process only after verification.

## Community testing

This script was developed from a real Snipe-IT v8.4.0 migration. API response shapes and validation rules can vary between versions and installations. Contributions should include the Snipe-IT version tested, the relevant API response shape, and a dry-run example that reproduces the issue without secrets or personal data.
