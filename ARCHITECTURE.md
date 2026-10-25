# Native Team implementation decisions

This project is isolated from the hosted app and extension. A separate build
composition adds it to the existing `orgloom` managed package; the unpackaged UAT
source project remains available. See PACKAGING.md.
The pinned canvas sources are verified, not edited. Native adapters and explicitly
documented build transformations supply the differences.

## Accepted scope

- Team edition only. Salesforce users, Custom Permissions and Permission Sets
  replace hosted accounts, workspace member grants and plan selection.
- AI and MCP are excluded, including their runtime modules. No live collaboration.
- Per-canvas exclusive editing lease. Owners, Editors and Contributors may take
  over; their role does not change. Viewers cannot take over. Takeover opens the
  latest saved snapshot, never another browser's unsaved work.
- Lease ownership is checked atomically on saves, uploads and request changes.
  Expiring leases and short heartbeats replace presence/state synchronization.
- Saved canvases retain application-level encryption. Key isolation is only a
  protected managed-package boundary after namespaced packaging, not in this
  unpackaged development project. Decrypted snapshots require current data-access
  filtering, including draft field values, record labels and relationship references.
- Migration uses the normal JSON format with an export-for-migration marker.
  A different source org also requires reconciliation even without the marker.
  The destination is the current org. Stage import until the user applies the plan;
  cancellation must preserve the original canvas. Source IDs are not destination IDs.

## Native differences

| Area | Hosted behavior | Native behavior / status |
| --- | --- | --- |
| Authentication | OAuth through hosted service | Current Salesforce session / Apex remoting |
| Capability checks | Workspace policy + subscription + member grants | Base custom permission + private per-user feature settings + org policy + implementation availability |
| Feature definitions | JavaScript registry | Same capability IDs, generated custom metadata; exactly two app permission sets |
| Commercial entitlement | Hosted subscription | Managed build checks Salesforce's current-user package license; LMA/distribution configuration remains separate |
| Administrator | Workspace administrator | Explicit Org Loom Admin permission; cannot grant itself through the app |
| Grants | Database records | Private per-user feature records; admin-only changes; default deny |
| Org restrictions | Workspace settings | Org policy records override user feature settings |
| AI/MCP/presence | Hosted feature services | Modules excluded; bootstrap compatibility interfaces make no requests |
| Saves / sharing | Hosted orchestration around package storage | Encrypted revisions, role-restricted recipient requests, version checks and exclusive leases; no email or live collaboration |
| Writes | Salesforce API operations | Bulk user-mode Apex DML; up to 500 records in independent atomic batches of at most 200; durable plan and attempt receipts |
| Migration | Connect/switch org | Marked or foreign-org normal JSON imports stage matching and field/value reconciliation; explicit Apply replaces the local canvas |

## Build sequence and acceptance

1. Access/admin foundation: reject direct unauthorized calls, revoke grants, org
   disable, no grant of unknown/admin permissions through feature editor.
2. Metadata/reads: standard and custom objects, browse/filter/lookup, relationship
   metadata, record types and picklists; permission-filtered record hydration.
3. Durable upload planning/execution: replay protection, create/update/delete and
   reference order, canonical results, no silent retries, permission/error tests.
4. Encrypted save/open and exclusive sessions: permission filtering, takeover,
   stale session recovery, save versions, owner-only upload for shared canvases.
5. Requests/sharing, Recall/history, import/export and staged migration.
6. Production packaging and release hardening. Production is enabled in the
   validated managed release. Existing UAT records are not fixtures.

This is an implementation backlog, not a claim that the listed features are complete.

## Accepted upload transport: direct Apex

The native app uses direct Apex with explicit USER_MODE queries and DML. No
Salesforce REST self-call, Named Credential, External Credential or second OAuth
connection is required. This is an intentional native difference from hosted
Composite Graph uploads, not a reduction in permission enforcement.

Writes are grouped by object and dependency order. Existing records are locked and
checked against their LastModifiedDate baseline before writes begin. Related drafts
are created parent-first; nullable cycles use a second update where Salesforce's
own validation rules permit it. Selected children are deleted before parents.

The current implementation accepts up to 500 selected records across 20 object
types, in atomic batches of at most 200 records, with bounded relationship depth
and transaction-budget checks. This is an
application limit, not a Salesforce guarantee (remoting payloads also remain
bounded to 500,000 JSON characters): customer triggers, flows, validation,
CPU, heap and DML limits can still reject a smaller upload. All changes and the
attempt receipt roll back together on failure. A successful replay returns the
original result without executing the writes again.

A server-side plan groups records using explicit canvas relationships, submitted
lookup values and existing readable lookup values. Connected groups are never split.
Independent groups are packed into batches of at most 200. Each batch runs in a
separate remoting transaction; completed batches remain committed if another fails.
The confirmation explains this, and the existing results UI receives per-record
success/failure results. Salesforce automation can introduce dependencies outside
the selected graph; the planner cannot infer those.

The persisted manifest contains record identities and payload digests, not field
values. Every batch checks its manifest digest, current permissions and editing
lease. Successful and rejected batches have durable receipts. Replays use the
original manifest even after records are deleted. An unconfirmed transport outcome
stops later batches and blocks new uploads. Recovery locks and closes the old
plan before reporting any absent batches as safe to retry, preventing delayed
requests from executing afterward. A lock timeout remains unconfirmed. The normal
receipt read does not make that safe-to-retry claim for an open plan.

External-ID upserts resolve accessible matches during planning. The durable plan
stores matched identities and timestamps, never external-ID values. Replays restore
the original resolutions; execution rechecks current matches before user-mode DML.
Matched rows use baseline-checked updates. New rows use actual user-mode upsert and
roll back if a concurrent match unexpectedly turns an insert into an update.
Duplicate warning overrides use DMLOptions with USER_MODE insert/update and
runAsCurrentUser. Apex's upsert path has no equivalent DMLOptions argument, so a
new external-ID upsert combined with duplicate override fails explicitly. Use a
reviewed insert or resolve the duplicate instead. Salesforce blocking rules and
permissions still apply.

## Native file and SOQL adapters

Shared canvas serializers, JSON validation/application and CSV mapping remain pinned
and unchanged. A native wrapper validates source-org identity before the shared
code can replace or merge canvas state. Same-org imports are enabled; foreign-org and migration-marked normal JSON opens
an isolated migration plan before applying. Saved-snapshot formats from another
org are rejected; use the normal JSON export for migration. Missing source identity is rejected for nonempty canvas files.

Imports check bulk-edit permissions; export routes check their separate feature
grants on each request. CSV existing-record resolution uses a narrowly parsed
SELECT Id / Id IN query and never grants arbitrary SOQL access. External-ID upsert
uses the native upload planner. Files are read/written
in the browser, not sent to an Org Loom server.

SOQL executes the selected fields in USER_MODE, then hydrates supported readable
fields. Child-query records are flattened, deduplicated, and linked to other
imported records through readable lookups. The cap is 500 records across at most
20 objects. Child queries can still encounter Salesforce CPU/heap/query limits
before that cap is applied; the cap is not a guarantee that every query fits.
Include Id in root and child SELECTs. Aggregates, TYPEOF, locking, comments and
multiple statements are rejected explicitly.

## Sharing and layouts: native adapter boundaries

The native grant table is private application metadata. Its owner-only API accepts
active Salesforce users and three enumerated roles. Current record/field permissions
are checked again before returning any decrypted snapshot. Unreadable records,
fields, lookup targets, metadata defaults and relationships are withheld. An editor
saves the visible projection; the server regenerates that projection under current
permissions, validates edits and merges into the full encrypted revision under its
lease/version lock. Hidden data never comes back from the browser. Forged hidden
fields/identities are rejected. A removed card survives if its hidden data or
connections would otherwise be lost. The UI explains this conservative behavior.
The projection also supplies a request-ID counter floor, without hidden request
contents, so the shared client cannot accidentally reuse a hidden request ID.
Contributors are validated against visible requests before their changes are
applied to the full revision. Choosing an existing record for a whole-record request
with hidden content requires its owner because replacing the identity would discard
that content; entering visible fields for a new record is supported.

Contributions are merged into one encrypted revision under the exclusive lease
and expected-version check. Whole-record choices use server-validated identities;
browser-provided values accompanying an existing-record choice are discarded.
The build transforms the existing submission seam to reload contributors after
success and update completed requests/version state for editors without discarding
their unrelated edits. Share URLs target the Lightning wrapper and explain that
no notification email is sent.

Two additional build transformations adapt the existing editor's layout fallback
to retain dependent-picklist controller indexes and change share-link routing/text.
All transforms are applied during packaging; pinned sources remain unchanged.
The Lightning wrapper uses UI API for layouts, while Apex ConnectApi.RecordUi
obtains record-type picklists. Messages check exact source/origin and request ID.
Standalone Visualforce uses accessible-field layout fallback. The controller and
remote entry point are global because Visualforce restricts public remoting in
frames; authorization remains inside every operation.

## Native Upload Recall

Before/after field values and creation snapshots are encrypted in Salesforce Files,
bound to org and uploader-owned attempt. They commit with the original DML. The
plaintext attempt contains only identities, field names, status and request hashes.
History is uploader-only; each action rechecks its capability. Forget hides an
entry without deleting durable receipts or business records.

Preflight presents original, uploaded and current values through the shared history
UI. The user's explicit force selections may restore later-modified fields or
delete modified creations. The server locks records, compares the fresh review
fingerprint and expected field values, and rechecks USER_MODE writes. It will not
silently apply a stale review. Recall does not undelete original deletions.

A system-mode existence-only check rejects creation deletion when related records
outside the selected set would be affected, including hidden children. It returns
no child values. Unsupported relationship probes fail closed; selected creations
are deleted child-first. Recall is atomic per original upload batch; triggers,
validation and governor limits can reject it. Completed selections are recorded
for retries and partial Recall. The explicit override never bypasses Salesforce
permissions or the outside-child guard.

## Remaining release/parity limits

- Production access and commercial package entitlement remain disabled/pending.
- Namespaced packaging, security review and end-to-end permission-matrix testing
  remain release work, not implied by these UAT tests.
- AI, MCP and live collaboration are intentionally excluded.
- New external-ID upsert cannot combine with a duplicate override. Insert/update
  overrides are implemented, but an active-rule UAT walkthrough remains unverified.
- UI API object support, required lookup-filter suggestions and validation-rule
  metadata do not have complete hosted parity; Salesforce still validates writes.
- Native limits remain 500 upload records, 200 per atomic group, 100 saved records,
  250 KB canvas payload and 500 KB serialized Recall snapshot. Customer automation
  can impose lower effective limits.

## Local tools and saved-canvas lifecycle

Run script and auto-fill use the pinned browser interpreter and generators. Native
build transformations add capability/lease checks and guard asynchronous completion
against a changed canvas or ended editing session. No server-side arbitrary code or
network bridge is added. Each capability has its own permission set; contributors
and viewers cannot use these tools on shared canvases.

Owner-only deletion checks the active lease and deletes only the private canvas,
grants and encrypted File revisions. Business records and upload/Recall history
remain intact. Tools migration uses the normal export dialog with migration checked
by default, replacing the hosted org-switch workflow. Public documentation links
open orgloom.com in another tab; no canvas data is transmitted with those links.


## Native record-link paste

`web/record-paste.js` handles user-initiated clipboard paste events on the canvas. It accepts individual record URLs from the connected org; it does not request clipboard-read permission or read the clipboard in the background. The `loadRecordLink` Apex operation infers object type from the ID and reuses USER_MODE reads under the Browse capability. The existing SOQL import commit engine creates cards, preserves loaded-value baselines, enforces the canvas cap and reconciles relationships. Native build adaptations expose that commit seam and guard against a canvas/session change while metadata loads. New records use normal import layout and focus. Vendored source remains unchanged.

The native keyboard adaptation allows ordinary Ctrl/Cmd+V to produce a browser paste event. Copying selected canvas cards uses the shared copy function and writes only a random session marker to the clipboard; pasting that marker invokes the shared card duplication function. Actual record values remain in memory. Ctrl/Cmd+Shift+V retains the shared multiple-copy dialog. Text input, contenteditable and modal paste behavior is left alone. Unsaved edits in the Salesforce record page are not transferred.

The unsuccessful drag experiment has been removed: no drag/drop listeners, diagnostic attributes, drop outline, drop-position transformations or Workspace API tab resolver remain. The Lightning wrapper serves layouts only. No extra panel or changes to Salesforce-owned tab markup are used.
