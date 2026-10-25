# Source licensing

The proprietary Salesforce-native implementation is published for inspection with all rights reserved, subject to the exceptions in [LICENSE](LICENSE). It is not offered under an open-source license. Publishing the source does not grant permission to deploy or operate it. Customer use of the installed managed package requires separate authorization under an applicable license agreement; this repository does not itself supply that agreement.

The package-specific LICENSE accompanies this directory when published as the root of `orgloom-package`. In the canonical monorepo, do not interpret the repository-root license as a new grant covering this directory's proprietary native implementation.

Existing component licenses and earlier grants remain applicable:

- Shared canvas: [vendor/upstream/packages/canvas/LICENSE](vendor/upstream/packages/canvas/LICENSE).
- Cytoscape: [vendor/libraries/cytoscape/LICENSE](vendor/libraries/cytoscape/LICENSE).
- Cytoscape node HTML labels: [vendor/libraries/cytoscape-node-html-label/LICENSE](vendor/libraries/cytoscape-node-html-label/LICENSE).
- Reused encryption service source: `vendor/key-service/`, including portions reused in native Apex classes.
- Retained released metadata and code: `compatibility/force-app/`; their existing license grants remain applicable.

The all-rights-reserved notice does not retroactively restrict previously licensed versions or portions, or replace third-party license terms. New proprietary additions do not grant permission to operate the complete native application merely because some of its components have separate licenses.
