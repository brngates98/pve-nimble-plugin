#!/usr/bin/env perl

# Regression tests for the 2026-07 safety audit fixes:
#  - properties() must never redeclare a globally registered property (SectionConfig dies on
#    duplicates — redeclaring `port`, which the base class owns, killed every PVE daemon).
#  - baseline iSCSI login must only touch Nimble vendor targets.
#  - nimble_base_url must not mangle IPv6 literals.
#  - parse_volname must follow the core-plugin contract ('images' + isBase, full name).
#  - nimble_volname must always prefix snap- (PVE snaps "x" and "snap-x" must not collide).

use strict;
use warnings;
use Test::More;

BEGIN {
  package PVE::JSONSchema;
  $INC{'PVE/JSONSchema.pm'} = 1;
}

BEGIN {
  package PVE::INotify;
  sub nodename { return 'testnode'; }
  $INC{'PVE/INotify.pm'} = 1;
}

BEGIN {
  package PVE::Storage;
  sub APIVER { 14 }
  sub APIAGE { 5 }
  $INC{'PVE/Storage.pm'} = 1;
}

our $fake_property_list = {};
our $fake_plugins       = {};

BEGIN {
  package PVE::Storage::Plugin;
  our @SHARED_STORAGE;
  sub get_next_vm_diskname { return 'vm-100-disk-0'; }
  sub private { return { propertyList => $main::fake_property_list, plugins => $main::fake_plugins }; }
  # Passthrough stand-in for SectionConfig::check_config (schema validation is not under test here).
  sub check_config { my ( $class, $sid, $config ) = @_; return { %$config }; }
  $INC{'PVE/Storage/Plugin.pm'} = 1;
}

# Stand-in for a co-installed pve-purestorage-plugin: registered plugin claiming the generic names.
BEGIN {
  package Fake::PurePlugin;
  sub properties {
    return { address => {}, vnprefix => {}, check_ssl => {}, token_ttl => {}, debug => {}, token => {} };
  }
}

BEGIN {
  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents file_set_contents);
  sub file_read_firstline { return ''; }
  sub file_get_contents   { return ''; }
  sub file_set_contents   { return 1; }
  sub run_command         { return 1; }
  sub run_with_timeout    { my ( $t, $code ) = @_; return $code->(); }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';
my $P = 'PVE::Storage::Custom::NimbleStoragePlugin';

### properties(): canonical nimble_* names always declared; legacy spellings only when unclaimed

{
  # Nimble-only install: canonical AND legacy spellings declared (legacy keeps old configs parsing).
  local $main::fake_property_list = {};
  local $main::fake_plugins       = {};
  my $props = $P->properties();
  ok( exists $props->{nimble_address},   'clean registry: nimble_address declared' );
  ok( exists $props->{nimble_check_ssl}, 'clean registry: nimble_check_ssl declared' );
  ok( exists $props->{$_}, "clean registry: legacy alias '$_' declared (pre-v0.0.25 configs)" )
    for qw(address vnprefix check_ssl token_ttl debug initiator_group pool_name volume_collection);
  ok( !exists $props->{port},
    'port never declared in properties() (base class owns it globally; redeclaring kills SectionConfig init)' );
  ok( !exists $props->{username} && !exists $props->{password},
    'username/password never declared (owned by core plugins)' );
}

{
  # Co-install: another REGISTERED plugin claims the generic names. This must hold regardless of
  # which plugin's properties() SectionConfig::init() merges first (random hash order), so the
  # guard checks the registered plugin list — populated before init() — not just the propertyList.
  local $main::fake_property_list = {};
  local $main::fake_plugins       = { purestorage => 'Fake::PurePlugin' };
  my $props = $P->properties();
  ok( !exists $props->{$_}, "registered rival plugin: legacy '$_' not declared (Pure owns it; both merge orders safe)" )
    for qw(address vnprefix check_ssl token_ttl debug);
  ok( exists $props->{nimble_address}, 'registered rival plugin: canonical nimble_address still declared' );
  ok( exists $props->{initiator_group},   'rival plugin: unclaimed legacy initiator_group still declared' );
  ok( exists $props->{pool_name},         'rival plugin: unclaimed legacy pool_name still declared' );
  ok( exists $props->{volume_collection}, 'rival plugin: unclaimed legacy volume_collection still declared' );
}

{
  # Names already merged into the global propertyList (base class / core plugins / earlier merge).
  local $main::fake_property_list =
    { address => {}, vnprefix => {}, check_ssl => {}, token_ttl => {}, debug => {}, port => {} };
  local $main::fake_plugins = {};
  my $props = $P->properties();
  ok( !exists $props->{$_}, "guard drops already-registered '$_'" )
    for qw(address vnprefix check_ssl token_ttl debug);
  ok( exists $props->{nimble_address}, 'already-registered legacy names do not suppress canonical nimble_address' );
}

{
  # Legacy names in options() only when the property exists globally: referencing an undeclared
  # property makes SectionConfig::init() die ("undefined property").
  local $main::fake_property_list = {};
  local $main::fake_plugins       = {};
  my $opts = $P->options();
  ok( $opts->{port} && $opts->{port}{optional}, 'options() references global port property' );
  ok( $opts->{nimble_address} && $opts->{nimble_address}{optional}, 'options() declares nimble_address optional' );
  ok( !exists $opts->{address}, 'legacy address not referenced while unregistered' );

  local $main::fake_property_list = { address => {}, vnprefix => {} };
  $opts = $P->options();
  ok( $opts->{address}  && $opts->{address}{optional},  'legacy address referenced once registered' );
  ok( $opts->{vnprefix} && $opts->{vnprefix}{optional}, 'legacy vnprefix referenced once registered' );
  ok( !exists $opts->{check_ssl}, 'unregistered legacy check_ssl still not referenced' );
}

### check_config: legacy keys canonicalized in-memory (upgrade path from <= v0.0.24)

{
  my $opts = $P->check_config( 'st1', {
    address     => 'array.example',
    vnprefix    => 'pve-',
    check_ssl   => 0,
    token_ttl   => 1800,
    debug       => 2,
    pool_name   => 'default',
    volume_collection => 'coll1',
    initiator_group   => 'ig1',
    auto_iscsi_discovery => 1,
    iscsi_discovery_ips  => '10.0.0.1',
    username    => 'admin',
  }, 1, 1 );
  is( $opts->{nimble_address},   'array.example', 'legacy address -> nimble_address' );
  is( $opts->{nimble_vnprefix},  'pve-',          'legacy vnprefix -> nimble_vnprefix' );
  is( $opts->{nimble_check_ssl}, 0,               'legacy check_ssl -> nimble_check_ssl (defined-false preserved)' );
  is( $opts->{nimble_token_ttl}, 1800,            'legacy token_ttl -> nimble_token_ttl' );
  is( $opts->{nimble_debug},     2,               'legacy debug -> nimble_debug' );
  is( $opts->{nimble_pool_name}, 'default',       'legacy pool_name -> nimble_pool_name' );
  is( $opts->{nimble_volume_collection}, 'coll1', 'legacy volume_collection -> nimble_volume_collection' );
  is( $opts->{nimble_initiator_group},   'ig1',   'legacy initiator_group -> nimble_initiator_group' );
  is( $opts->{nimble_auto_iscsi_discovery}, 1,    'legacy auto_iscsi_discovery -> canonical' );
  is( $opts->{nimble_iscsi_discovery_ips}, '10.0.0.1', 'legacy iscsi_discovery_ips -> canonical' );
  ok( !exists $opts->{$_}, "legacy key '$_' removed after canonicalization" )
    for qw(address vnprefix check_ssl token_ttl debug pool_name volume_collection initiator_group);
  is( $opts->{nimble_storeid}, 'st1', 'section id injected as nimble_storeid' );
}

{
  my $opts = $P->check_config( 'st1', { address => 'old.example', nimble_address => 'new.example' }, 1, 1 );
  is( $opts->{nimble_address}, 'new.example', 'canonical key wins when both spellings present' );
  ok( !exists $opts->{address}, 'losing legacy key still removed' );
}

### plugindata: password is a sensitive property (kept out of storage.cfg by PVE)

{
  my $pd = $P->plugindata();
  is_deeply( $pd->{'sensitive-properties'}, { password => 1 },
    'password declared sensitive (routed to /etc/pve/priv, not cluster-replicated cfg)' );
}

### baseline login scoping: only Nimble vendor IQNs may be logged in

{
  no strict 'refs';
  my $is_nimble = \&{"${P}::nimble_iscsi_iqn_is_nimble_target"};
  ok( $is_nimble->('iqn.2007-11.com.nimblestorage:group-vol1-v000001'), 'real Nimble IQN accepted' );
  ok( $is_nimble->('iqn.2010-06.com.nimble:vol-test'),                  'nimble substring accepted' );
  ok( !$is_nimble->('iqn.2010-06.com.purestorage:flasharray.x'),        'Pure target rejected' );
  ok( !$is_nimble->('iqn.2005-10.org.freenas.ctl:target0'),             'TrueNAS target rejected' );
  ok( !$is_nimble->('iqn.2003-01.org.linux-iscsi.host:disk1'),          'LIO target rejected' );
  ok( !$is_nimble->(''),                                                'empty IQN rejected' );
  ok( !$is_nimble->(undef),                                             'undef IQN rejected' );
}

### nimble_base_url: hostnames, IPv4, and IPv6 literals

{
  no strict 'refs';
  my $url = \&{"${P}::nimble_base_url"};
  is( $url->({ nimble_address => '10.0.0.5' }),               'https://10.0.0.5:5392',     'bare IPv4' );
  is( $url->({ nimble_address => '10.0.0.5:5392' }),          'https://10.0.0.5:5392',     'IPv4 with port stripped' );
  is( $url->({ nimble_address => 'https://array.example' }),  'https://array.example:5392', 'scheme stripped' );
  is( $url->({ nimble_address => 'array.example:9999' }),     'https://array.example:5392', 'hostname port replaced by default' );
  is( $url->({ nimble_address => 'array.example', port => 9999 }), 'https://array.example:9999', 'port property honored' );
  is( $url->({ nimble_address => 'fd00::5392' }),             'https://[fd00::5392]:5392', 'unbracketed IPv6 not mangled' );
  is( $url->({ nimble_address => '[fd00::1]:9440' }),         'https://[fd00::1]:5392',    'bracketed IPv6 with port' );
  is( $url->({ nimble_address => '[fd00::1]', port => 9999 }), 'https://[fd00::1]:9999',   'bracketed IPv6 + port property' );
}

### parse_volname: core plugin contract

{
  my @r = $P->parse_volname('vm-100-disk-0');
  is( $r[0], 'images',        'vm volume vtype is images' );
  is( $r[1], 'vm-100-disk-0', 'name is the full volname (core block plugin semantics)' );
  is( $r[2], '100',           'vmid extracted' );
  ok( !$r[5],                 'vm volume is not a base image' );
  is( $r[6], 'raw',           'format raw' );

  @r = $P->parse_volname('base-200-disk-1');
  is( $r[0], 'images', 'base volume vtype is images (not the invalid "base")' );
  ok( $r[5],           'base volume has isBase set' );

  eval { $P->parse_volname('not-a-volume'); };
  like( $@, qr/Invalid volume name/, 'invalid name dies' );
}

### nimble_volname: unconditional snap- prefix

{
  no strict 'refs';
  my $vn = \&{"${P}::nimble_volname"};
  my $scfg = {};
  is( $vn->( $scfg, 'vm-100-disk-0', 'daily' ),  'vm-100-disk-0.snap-daily',      'normal snap name' );
  is( $vn->( $scfg, 'vm-100-disk-0', 'snap-x' ), 'vm-100-disk-0.snap-snap-x',     'snap-* PVE name gets its own prefix (no collision with "x")' );
  isnt( $vn->( $scfg, 'vm-100-disk-0', 'snap-x' ), $vn->( $scfg, 'vm-100-disk-0', 'x' ),
    'PVE snapshots "snap-x" and "x" map to different array names' );
  is( $vn->( $scfg, 'vm-100-disk-0', 'veeam_job1' ), 'vm-100-disk-0.snap-veeam-job1', 'veeam_ normalized' );
  is( $vn->( { nimble_vnprefix => 'pveA-' }, 'vm-100-disk-0' ), 'pveA-vm-100-disk-0', 'prefix without snap' );
}

### New properties: nimble_limit_iops, nimble_limit_mbps, nimble_folder declared

{
  local $main::fake_property_list = {};
  local $main::fake_plugins       = {};
  my $props = $P->properties();
  ok( exists $props->{nimble_limit_iops},
    'nimble_limit_iops declared in properties()' );
  ok( exists $props->{nimble_limit_mbps},
    'nimble_limit_mbps declared in properties()' );
  ok( exists $props->{nimble_folder},
    'nimble_folder declared in properties()' );
  is( $props->{nimble_limit_iops}{type}, 'integer',
    'nimble_limit_iops type is integer' );
  is( $props->{nimble_limit_mbps}{type}, 'integer',
    'nimble_limit_mbps type is integer' );
  is( $props->{nimble_limit_iops}{default}, -1,
    'nimble_limit_iops default is -1 (unlimited)' );
  is( $props->{nimble_limit_mbps}{default}, -1,
    'nimble_limit_mbps default is -1 (unlimited)' );
}

{
  local $main::fake_property_list = {};
  local $main::fake_plugins       = {};
  my $opts = $P->options();
  ok( $opts->{nimble_limit_iops} && $opts->{nimble_limit_iops}{optional},
    'options() declares nimble_limit_iops optional' );
  ok( $opts->{nimble_limit_mbps} && $opts->{nimble_limit_mbps}{optional},
    'options() declares nimble_limit_mbps optional' );
  ok( $opts->{nimble_folder} && $opts->{nimble_folder}{optional},
    'options() declares nimble_folder optional' );
}

done_testing();
