// HPE Nimble Storage Plugin — GUI Integration for Proxmox VE
// Adds "HPE Nimble" to the Storage Add dropdown and enables the Edit dialog.
//
// Deployed to: /usr/share/pve-manager/js/NimbleEdit.js
// Loaded via:  /usr/share/pve-manager/index.html.tpl  (injected by postinst)

// ---------------------------------------------------------------------------
// Main "General" storage configuration panel
// ---------------------------------------------------------------------------
Ext.define('PVE.storage.NimbleInputPanel', {
    extend: 'PVE.panel.StorageBase',

    type: 'nimble',

    onlineHelp: 'chapter_storage',

    onGetValues: function(values) {
	var me = this;

	// Only send password when the user typed a new one
	if (!values.password || values.password.length === 0 || values.password === '********') {
	    delete values.password;
	}

	// Remove empty optional string fields; on Edit, tell the API to delete the key
	var optionalStrings = [
	    'nimble_initiator_group',
	    'nimble_vnprefix',
	    'nimble_pool_name',
	    'nimble_folder',
	    'nimble_volume_collection',
	    'nimble_iscsi_discovery_ips',
	];
	optionalStrings.forEach(function(key) {
	    if (values[key] !== undefined && String(values[key]).length === 0) {
		delete values[key];
		if (!me.isCreate) {
		    values['delete'] = (values['delete'] ? values['delete'] + ',' : '') + key;
		}
	    }
	});

	return me.callParent([values]);
    },

    initComponent: function() {
	var me = this;

	// ---- Column 1: connection ----
	me.column1 = [
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'nimble_address',
		value: '',
		fieldLabel: 'Array IP / DNS',
		allowBlank: false,
	    },
	    {
		xtype: me.isCreate ? 'textfield' : 'displayfield',
		name: 'username',
		value: '',
		fieldLabel: gettext('Username'),
		allowBlank: false,
	    },
	    {
		xtype: 'textfield',
		inputType: 'password',
		name: 'password',
		value: me.isCreate ? '' : '********',
		emptyText: me.isCreate ? gettext('Required') : '',
		fieldLabel: gettext('Password'),
		allowBlank: !me.isCreate,
	    },
	    {
		xtype: 'pveContentTypeSelector',
		name: 'content',
		value: 'images',
		multiSelect: true,
		fieldLabel: gettext('Content'),
		allowBlank: false,
	    },
	];

	// ---- Column 2: volume placement ----
	me.column2 = [
	    {
		xtype: 'textfield',
		name: 'nimble_vnprefix',
		fieldLabel: 'Volume Name Prefix',
		emptyText: 'pve',
		allowBlank: true,
	    },
	    {
		xtype: 'textfield',
		name: 'nimble_pool_name',
		fieldLabel: 'Pool Name',
		emptyText: gettext('Default pool'),
		allowBlank: true,
	    },
	    {
		xtype: 'textfield',
		name: 'nimble_folder',
		fieldLabel: 'Folder',
		emptyText: gettext('None (root)'),
		allowBlank: true,
	    },
	    {
		xtype: 'textfield',
		name: 'nimble_initiator_group',
		fieldLabel: 'Initiator Group',
		emptyText: gettext('Auto (from IQN)'),
		allowBlank: true,
	    },
	];

	// ---- Advanced column 1: optional settings ----
	me.advancedColumn1 = [
	    {
		xtype: 'textfield',
		name: 'nimble_volume_collection',
		fieldLabel: 'Volume Collection',
		emptyText: gettext('None'),
		allowBlank: true,
	    },
	    {
		xtype: 'proxmoxintegerfield',
		name: 'nimble_token_ttl',
		fieldLabel: 'Session Token TTL (s)',
		value: 3600,
		minValue: 60,
		allowBlank: true,
		emptyText: '3600',
		deleteEmpty: !me.isCreate,
	    },
	    {
		xtype: 'proxmoxintegerfield',
		name: 'nimble_debug',
		fieldLabel: 'Debug Level (0-3)',
		value: 0,
		minValue: 0,
		maxValue: 3,
		allowBlank: true,
		emptyText: '0',
		deleteEmpty: !me.isCreate,
	    },
	    {
		// Comma-separated list of iSCSI discovery portals (host or host:port).
		// When set, ONLY these IPs are used for sendtargets — the Nimble subnets
		// API is not queried. Leave empty to auto-detect from the array.
		// Accepts any mix of formats: 10.0.0.1  or  10.0.0.1:3260
		// Multiple portals: 10.0.0.1,10.0.0.2  or  10.0.0.1:3260,10.0.0.2:3260
		// or  10.0.0.1,10.0.0.2:3260  or  10.0.0.1:3260,10.0.0.2
		xtype: 'textfield',
		name: 'nimble_iscsi_discovery_ips',
		fieldLabel: 'Discovery Portals',
		emptyText: 'e.g. 10.0.0.1,10.0.0.2:3260  (leave empty to auto-detect)',
		allowBlank: true,
	    },
	];

	// ---- Advanced column 2: iSCSI / TLS ----
	me.advancedColumn2 = [
	    {
		xtype: 'proxmoxcheckbox',
		name: 'nimble_check_ssl',
		fieldLabel: 'Verify TLS Certificate',
		uncheckedValue: 0,
		checked: false,
		deleteEmpty: !me.isCreate,
	    },
	    {
		xtype: 'proxmoxcheckbox',
		name: 'nimble_auto_iscsi_discovery',
		fieldLabel: 'Auto iSCSI Discovery',
		uncheckedValue: 0,
		checked: true,
		deleteEmpty: !me.isCreate,
	    },
	];

	me.callParent();
    },
});

// ---------------------------------------------------------------------------
// Register in PVE's storage schema — makes "HPE Nimble" appear in Add dropdown
// and enables the Edit dialog.
// ---------------------------------------------------------------------------
(function() {
    if (typeof PVE === 'undefined' || !PVE.Utils) { return; }
    if (!PVE.Utils.storageSchema) { PVE.Utils.storageSchema = {}; }
    PVE.Utils.storageSchema['nimble'] = {
	name: 'HPE Nimble',
	ipanel: 'NimbleInputPanel',
	faIcon: 'database',
	backups: false,
    };
}());
