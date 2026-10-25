# Released metadata compatibility

Released metadata remains in the managed build because Salesforce rejected its removal from released ancestor 0.6.0.2. Component deletion for this second-generation managed package requires enablement through a Salesforce Partner Community case.

The first rejection (`08cao000000Hj3xAAC`) identified four legacy objects unused by the native app:

- `Audit_Event__c`
- `Canvas_Contribution__c`
- `Orgloom_Canvas__c`
- `Org_Kek_Setting__c` (protected custom setting)

Their existing fields are retained to avoid field-deletion restrictions as well. A second build (`08cao000000Hj7BAAS`) also rejected deletion of `ExtlClntAppOauthSettings:loom_oauth`. The released `loom_oauth` settings and their `ExternalClientApplication:loom` dependency therefore remain here as well. The native app does not use this ECA, but it is still included in the managed artifact pending Salesforce removal enablement.

A third build (`08cao000000Hj8nAAC`) rejected removal of `Orgloom_Access` and the 15 former native feature custom permissions. The released legacy Apex services, REST endpoint, installer, trigger, permission sets, and former native feature permission sets are therefore retained here too. Salesforce's deletion feature covers these component types; global Apex classes additionally cannot be removed through the normal component-removal process.

Request `08cao000000HjAPAA0` also rejected deleting `OrgLoomNativeFeature__mdt.Permission__c`. That obsolete field is retained here and merged with the current feature metadata definition during the managed build. It is not used by the new feature-access implementation.

The native runtime uses its own objects, encryption service, installer, two base access sets, and private per-user feature settings. The old feature permission sets no longer enable native features. Compatibility sets are not automatically assigned by the native installer. They remain visible in the installed managed package until Salesforce permits their removal. The old REST endpoint also remains packaged; this source separation does not disable it.

This directory is composed only into the managed build; it is not part of the unpackaged UAT deployment. The old standalone project/configuration and the never-packaged `Orgloom_Audit_Smoke_Test` permission set have been removed from the published tree.

The released `OrgLoomNativePrototype` standalone canvas tab is also retained here for managed-package compatibility. It is removed from current permission-set navigation and hidden in the UAT administrator profile; the `OrgLoomNative` Visualforce page remains in native source because the Lightning canvas embeds it. Salesforce's standard Org Metrics tab is also hidden in that UAT profile; it is not part of this package.

Once Salesforce enables component deletion, remove the eligible components and validate a new package version against its released ancestor before distributing it. Handle the global `OrgloomKekRest` API separately with Salesforce guidance (for example, a deprecated API that rejects use while retaining its signature). Do not skip ancestor checks to work around the restriction.

## Salesforce support request

Subject: Enable metadata component removal for Orgloom managed 2GP

Please enable second-generation managed package component removal for our Dev Hub and the Orgloom package (`0Hoao0000003RYLCA2`, namespace `orgloom`). We are retiring hosted-service components as we transition to a Salesforce-native implementation. Our released ancestor is `04tao000005eJsHAAU` (0.6.0.2). Package creation requests `08cao000000Hj3xAAC` and `08cao000000Hj7BAAS` rejected removal of the four legacy objects and `ExtlClntAppOauthSettings:loom_oauth` and directed us to request this feature through Partner Community. Requests `08cao000000Hj8nAAC` and `08cao000000HjAPAA0` also rejected old custom permissions and the obsolete `OrgLoomNativeFeature__mdt.Permission__c` field. A build retaining compatibility metadata succeeded as beta 0.7.0.1 (`04tao000005eKA1AAM`). Please also confirm the supported retirement approach for the released global REST class `OrgloomKekRest`.

Reference: [Salesforce component removal documentation](https://developer.salesforce.com/docs/platform/pkg2-dev/guide/sfdx-dev-dev2gp-remove-md-components.html). This request has not been submitted.
