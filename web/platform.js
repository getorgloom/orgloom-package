(function () {
  'use strict';
  // Native choices are registered before the unmodified shared canvas boots.
  // This object is application code, never imported from saved canvas JSON.
  window.OrgLoom = window.OrgLoom || {};
  window.OrgLoom.platform = {
    onboarding: window.OrgLoomNativeOnboarding,
    recovery: window.OrgLoomNativeRecovery,
    toolbar: { showCanvasesMenu: true },
    canEdit: () => !document.querySelector('#native-session-ended'),
    requestSequenceFloor: payload => payload?._meta?.nativeNextSlotId,
    migration: {
      label: 'Export for migration…',
      description: 'Export a migration file, then import it in the destination org to review field mappings and record matches.',
      start: ({ exportForMigration }) => exportForMigration(),
    },
    share: {
      searchPlaceholder: 'Search by name…',
      teammatePlaceholder: 'Pick a teammate by name…',
      buildUrl: canvasId => window.__ORGLOOM_NATIVE_IDENTITY__.lightningOrigin
        + '/lightning/n/' + encodeURIComponent(window.__ORGLOOM_NATIVE_IDENTITY__.canvasTabName || 'OrgLoomNativeCanvas') + '?c__openCanvas=' + encodeURIComponent(canvasId),
      notificationMessage: data => data.notificationMode === 'saved-canvases'
        ? 'Access granted. Your teammate can open this from Saved canvases. No email was sent.' : undefined,
    },
    async afterRequestsSubmitted({ role, fills, response, canvasState, reload, render }) {
      if (role === 'contributor') {
        await reload();
        return;
      }
      for (const record of canvasState.bulkRecords) {
        if (record.slot && record.slot.kind !== 'fields'
          && fills.some(fill => String(fill.slotId) === String(record.slot.slotId))) delete record.slot;
      }
      if (canvasState.currentCanvas) canvasState.currentCanvas.versionId = response.versionId;
      render();
    },
    clipboard: {
      usesEvents: true,
      mount: context => window.OrgLoomNativePaste.mount({
        ...context,
        loading: () => !!document.querySelector('#native-session-ended'),
      }),
    },
  };
})();
