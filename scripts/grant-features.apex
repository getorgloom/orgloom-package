// Development only: run AFTER grant-access.apex, in a separate transaction.
// Enables implemented features for the CLI-authenticated UAT administrator only.
OrgLoomNativeAccess.requireAdmin();
for(String capability:OrgLoomNativeAccess.IMPLEMENTED)OrgLoomFeatureAccess.setGrant(UserInfo.getUserId(),capability,true);
