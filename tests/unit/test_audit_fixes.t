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

BEGIN {
  package PVE::Storage::Plugin;
  our @SHARED_STORAGE;
  sub get_next_vm_diskname { return 'vm-100-disk-0'; }
  sub private { return { propertyList => $main::fake_property_list }; }
  $INC{'PVE/Storage/Plugin.pm'} = 1;
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

### properties() guard: never redeclare a property that is already globally registered

{
  local $main::fake_property_list = {};
  my $props = $P->properties();
  ok( exists $props->{address},   'clean registry: address declared' );
  ok( exists $props->{check_ssl}, 'clean registry: check_ssl declared' );
  ok( !exists $props->{port},
    'port never declared in properties() (base class owns it globally; redeclaring kills SectionConfig init)' );
  ok( !exists $props->{username} && !exists $props->{password},
    'username/password never declared (owned by core plugins)' );
}

{
  # Simulate load order where another plugin (e.g. pve-purestorage-plugin) already registered the
  # names it shares with us: our properties() must silently drop them, not collide.
  local $main::fake_property_list =
    { address => {}, vnprefix => {}, check_ssl => {}, token_ttl => {}, debug => {}, port => {} };
  my $props = $P->properties();
  ok( !exists $props->{$_}, "guard drops already-registered '$_'" )
    for qw(address vnprefix check_ssl token_ttl debug);
  ok( exists $props->{initiator_group},   'guard keeps nimble-only initiator_group' );
  ok( exists $props->{pool_name},         'guard keeps nimble-only pool_name' );
  ok( exists $props->{volume_collection}, 'guard keeps nimble-only volume_collection' );
}

{
  my $opts = $P->options();
  ok( $opts->{port} && $opts->{port}{optional}, 'options() references global port property' );
  ok( $opts->{address} && $opts->{address}{fixed}, 'options() keeps address fixed' );
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
  is( $url->({ address => '10.0.0.5' }),               'https://10.0.0.5:5392',     'bare IPv4' );
  is( $url->({ address => '10.0.0.5:5392' }),          'https://10.0.0.5:5392',     'IPv4 with port stripped' );
  is( $url->({ address => 'https://array.example' }),  'https://array.example:5392', 'scheme stripped' );
  is( $url->({ address => 'array.example:9999' }),     'https://array.example:5392', 'hostname port replaced by default' );
  is( $url->({ address => 'array.example', port => 9999 }), 'https://array.example:9999', 'port property honored' );
  is( $url->({ address => 'fd00::5392' }),             'https://[fd00::5392]:5392', 'unbracketed IPv6 not mangled' );
  is( $url->({ address => '[fd00::1]:9440' }),         'https://[fd00::1]:5392',    'bracketed IPv6 with port' );
  is( $url->({ address => '[fd00::1]', port => 9999 }), 'https://[fd00::1]:9999',   'bracketed IPv6 + port property' );
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
  is( $vn->( { vnprefix => 'pveA-' }, 'vm-100-disk-0' ), 'pveA-vm-100-disk-0', 'prefix without snap' );
}

done_testing();
