# Native managed package

The native app is the next version of the existing **Orgloom** second-generation managed package (`0Hoao0000003RYLCA2`, namespace `orgloom`). Version 0.7 descends from released version 0.6.0.2 (`04tao000005eJsHAAU`), which descends from 0.5.0.12 (`04tao000005dalVAAQ`). We assume no customer installations and do not migrate hosted canvas ciphertext into the native format. Released-component compatibility rules still apply.

## Released version

**0.7.0.15**, released 2026-10-30: `04tao000005eOojAAE`.

[Install in production or a Developer Edition org](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tao000005eOojAAE) · [Install in a sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tao000005eOojAAE).

Choose **Install for Admins Only**, then assign app permissions and individual feature grants as described below. This version is production-installable; AppExchange security review and commercial licensing remain separate.

The release includes the current native canvas code, including sharing/access checks, request autosave, encrypted-field handling, recovery/takeover fixes, migration/upload fixes, and the latest UI changes. Two activity-test fixtures were corrected: shared recipients need Open saved canvases, and non-admin users must not inherit the installer profile's admin permission.

Validation receipts are under `test-results/install-release-final-*`: **95% Apex coverage**, **184/184 installed Apex tests**, and **216/216 local native tests**. Fresh installation and upgrade from 0.6.0.2 passed. An encrypted canvas saved by 0.6 remained readable after the upgrade. Installer permissions, the protected-key boundary, encrypted save/open, lease protection, uploads and separate-request Recall passed. The earlier 0.7.0.14 candidate also passed an upgrade path through 0.5.0.12 and 0.6.0.2; it remains an unreleased beta. Validation used disposable scratch orgs, not UAT business data. No new browser UI verification is claimed for this release.

The public website/email changes are local and await deployment. After deployment, `https://orgloom.com/install` and `https://orgloom.com/install/sandbox` redirect to this version. The next managed build targets **0.8.0.NEXT**, with this release as its ancestor. The installed package in orguat was not upgraded by this release process.

## Cleanup validation, 2026-10-23

Salesforce accepted beta **0.7.0.1** (`04tao000005eKA1AAM`), request `08cao000000HjC1AAK`, with normal validation, **94% Apex coverage**, and released ancestor `04tao000005eJsHAAU`. Validation was not skipped. This version has not been promoted and the public installation links above still point to the released version.

This successful build **retains** released metadata in `compatibility`; it does not establish that component deletion is permitted. Earlier validated build attempts rejected deleting the legacy objects, ECA settings, old feature custom permissions, and `OrgLoomNativeFeature__mdt.Permission__c`. A Salesforce Partner Support case must enable component removal before those can be omitted. Global Apex has additional restrictions. The source cleanup removes the obsolete standalone package project and unused smoke-test permission set, while separating required compatibility metadata from native development.

Local validation: 139 native tests and 2 publication tests passed. Fresh installation in the disposable `orgloom-legacy-cleanup-check` scratch org succeeded. The installer smoke check verified an active package license, only `OrgLoomNative_Admin` assigned to the installer, all native feature grants initially disabled, and working capabilities access. The recovery cleanup job is `WAITING` on daily cron `0 0 2 * * ?`. This pass did not run an upgrade installation or promote the beta. Receipts are under `output/legacy-cleanup-*`; the removal details and a support-case draft are in `compatibility/README.md`.

## Stable public installation links

The welcome email uses `https://orgloom.com/install`; sandboxes use `https://orgloom.com/install/sandbox`. These public routes return uncached 302 redirects to the released `subscriberPackageVersionId` in `config/released-package.json`. After validating and promoting a new Salesforce version, update that release manifest and deploy the website. Existing emails then resolve to the new version without rewriting the email template. Website deployment remains separate from package creation and promotion.

## Sources and composition

Develop in the main Org Loom repository at `orgloom-package/`. The earlier standalone `orgloom-salesforce-native` checkout is no longer the canonical source. GitHub source publication is separate from Salesforce package creation and promotion.


- `force-app` and `web`: current native implementation; the unpackaged UAT project keeps its empty namespace.
- `config/managed-project.json`: package identity, namespace, next version, install handler, and released ancestor. The native encryption service retains its independently pinned source under `vendor/key-service`.
- `compatibility/force-app`: released hosted metadata and former native feature permission sets/custom permissions. Salesforce rejected deletion of objects, ECA settings, and custom permissions without Partner Community enablement of 2GP component removal. The required metadata is isolated here rather than mixed into the current native source; it is not deployed to unpackaged UAT. See `compatibility/README.md` for the rejected requests and a draft support case.
- `vendor/upstream`: separately pinned shared canvas frontend. Update only through the canonical export workflow.
- `scripts/prepare-package.cjs`: copies the native and required compatibility metadata into ignored `output/managed-package`, checks component collisions/stale files, records SHA-256 hashes, and writes the namespaced project with the released ancestor.

The native runtime uses the current Salesforce session, UI API and direct Apex and requires no new OAuth connection. The managed artifact still contains the old `loom` External Client App and `loom_oauth` settings for released-package compatibility; the native app does not use them. The earlier source-only ECA removal was rejected during package creation. Removing them from the installable artifact requires Salesforce to enable component deletion. Released version 0.6.0.2 remains unchanged.

```powershell
npm ci
npm test
npm run package:prepare
Set-Location output/managed-package
sf package version create --package Orgloom --target-dev-hub devhub --code-coverage --installation-key-bypass --definition-file ../../config/package-scratch-def.json --wait 0 --json
```

Keep the request ID and poll its report. Do not use `--skip-validation`, skip the released ancestor check, or promote a version before validating its actual namespaced installation. Build output and CLI receipts live in `output` and are not source control inputs.

## Permissions and installer setup

The current native source uses two app permission sets:

1. **Org Loom Canvas** (`OrgLoomNativePrototype`, stable API name): canvas tab, pages, controller and base access.
2. **Org Loom Admin** (`OrgLoomNative_Admin`): the same canvas access plus administration tabs and authority to change feature settings.

The installer receives Org Loom Admin only. Neither role implicitly enables features. In **Org Loom Team Administration**, enable the features each user needs. Feature definitions live in custom metadata; grants are private `OrgLoomFeatureAccess__c` records. Neither permission set grants direct CRUD on that object, and the canvas excludes it. The configuration service permits self reads and requires administrator access for other-user reads and writes. Org-wide switches override individual grants; Salesforce data permissions still apply.

Choose **Install for Admins Only**. Salesforce installation profile grants can include the administration custom permission; do not broaden this to ordinary users. Internal API names remain stable, while displayed labels use Org Loom.

Released 0.6.0.2 still uses the earlier feature permission sets. For unpackaged UAT, run `scripts/migrate-uat-feature-grants.apex` before removing obsolete sets. This deliberately supports the current single-user development org only and fails if another user has legacy direct assignments; it preserves existing saved toggles. The managed build must retain the old sets and custom permissions in `compatibility` until Salesforce enables component removal. They remain visible in Setup but do not enable native features and are not assigned by the native installer. Hosted services and the audit trigger remain packaged for the same reason. The released global `OrgloomKekRest` API has additional removal restrictions and needs a separate retirement decision.

Namespaced builds enforce `UserInfo.isCurrentUserLicensed` in addition to app permissions. Configure commercial licensing/distribution separately; a successful package build does not imply AppExchange security approval.

## Release validation

Use disposable orgs and records. Check both a clean installation and an upgrade from 0.5.0.12 even though there are no expected customer installations. Also test upgrade from the current released ancestor, 0.6.0.2. Validate installer grants, denial of non-admin toggle calls, encrypted save/reopen, user-mode reads/uploads and Recall, and the Lightning-to-namespaced-Visualforce layout bridge. Verify namespaced share links. Run packaged Apex tests and check the package's actual code coverage report before promotion.

Production enablement is authorized after these checks pass. Promotion makes a version releasable and is irreversible; record the version ID and validation results before distribution. Installation links use the resulting subscriber package version ID (`04t…`), not the Package2 ID (`0Ho…`).
