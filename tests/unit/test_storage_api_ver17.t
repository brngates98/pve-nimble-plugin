#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

BEGIN {
  package PVE::JSONSchema;
  $INC{'PVE/JSONSchema.pm'} = 1;
}

BEGIN {
  package PVE::Network;
  $INC{'PVE/Network.pm'} = 1;
}

BEGIN {
  package PVE::INotify;
  sub nodename { return 'testnode'; }
  $INC{'PVE/INotify.pm'} = 1;
}

BEGIN {
  package PVE::Storage;
  sub APIVER { 17 }
  sub APIAGE { 8 }
  $INC{'PVE/Storage.pm'} = 1;
}

BEGIN {
  package PVE::Storage::Plugin;
  our @SHARED_STORAGE;
  sub get_next_vm_diskname { return 'vm-100-disk-0'; }
  $INC{'PVE/Storage/Plugin.pm'} = 1;
}

BEGIN {
  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents);
  sub file_read_firstline { return ''; }
  sub run_command         { die "run_command not stubbed for this test"; }
  sub file_get_contents   { return ''; }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';

my $class = 'PVE::Storage::Custom::NimbleStoragePlugin';

sub set_pve_storage_api {
  my ( $apiver, $apiage ) = @_;
  no warnings 'redefine';
  *PVE::Storage::APIVER = sub { $apiver };
  *PVE::Storage::APIAGE = sub { $apiage };
}

set_pve_storage_api( 17, 8 );
is( $class->api(), 17, 'api() reports 17 when host APIVER is 17 (libpve-storage-perl 9.1.17+)' );

set_pve_storage_api( 16, 7 );
is( $class->api(), 16, 'api() reports 16 when host APIVER is 16 (issue #12 host / 9.1.13)' );

set_pve_storage_api( 15, 6 );
is( $class->api(), 15, 'api() reports 15 when host APIVER is 15' );

set_pve_storage_api( 14, 5 );
is( $class->api(), 14, 'api() reports 14 when host APIVER is 14' );

set_pve_storage_api( 13, 4 );
is( $class->api(), 13, 'api() reports 13 when host APIVER is 13 (backward compatible)' );

set_pve_storage_api( 20, 5 );
is(
  $class->api(),
  17,
  'api() reports tested 17 when host APIVER is newer but within APIAGE window',
);

# --- APIVER 17: guest volume types + plugindata / isolate-properties -----------------------------
# Older hosts: the base class has no guest_volume_vtype() -> 'images'.
set_pve_storage_api( 15, 6 );
is( ( $class->parse_volname('vm-100-disk-0') )[0], 'images', 'parse_volname: images without base helper' );
my $pd15 = $class->plugindata();
ok( !$pd15->{content}[0]{'vm-vol'}, 'plugindata: no vm-vol content type before APIVER 17' );

# 9.3 hosts: mirror the base helper (it reports 'images' when the plugin's api() < 17).
{
  no warnings 'once';
  *PVE::Storage::Plugin::guest_volume_vtype = sub {
    my ( $c, $format, $name ) = @_;
    return 'images' if $c->can('api') && $c->api() < 17;
    return 'ct-vol' if $format eq 'subvol';
    return 'vm-state' if defined($name) && $name =~ m/^vm-\d+-state-/;
    return 'vm-vol';
  };
}
is( ( $class->parse_volname('vm-100-disk-0') )[0], 'images', 'parse_volname: images when host APIVER 15 even with helper' );
set_pve_storage_api( 17, 8 );
is( ( $class->parse_volname('vm-100-disk-0') )[0], 'vm-vol', 'parse_volname: vm-vol on APIVER 17' );
is( ( $class->parse_volname('vm-100-state-snap1') )[0], 'vm-state', 'parse_volname: vm-state on APIVER 17' );
my @pv = $class->parse_volname('base-101-disk-0');
is( $pv[5], 1, 'parse_volname: base flag kept' );
is( $pv[1], 'base-101-disk-0', 'parse_volname: name kept' );

my $pd = $class->plugindata();
ok( $pd->{content}[0]{$_}, "plugindata: $_ content type on APIVER 17" ) for qw(vm-vol vm-state ct-vol);
is_deeply( $pd->{content}[1], { images => 1, rootdir => 1 }, 'plugindata: default content unchanged' );
is( $pd->{meta}{'display-name'}, 'HPE Nimble / Alletra 5000/6000', 'plugindata: display name' );
ok( $pd->{'hidden-properties'}{nimble_storeid}, 'plugindata: nimble_storeid hidden' );
ok( $pd->{'hidden-properties'}{address}, 'plugindata: legacy alias hidden' );
ok( $pd->{'hidden-properties'}{format}, 'plugindata: format hidden (raw only; dialog would offer qcow2/vmdk)' );
ok( $pd->{'advanced-properties'}{nimble_limit_iops}, 'plugindata: QoS limit is advanced' );
ok( $pd->{'advanced-properties'}{'san-multipath'}, 'plugindata: san-multipath is advanced' );
ok( !$pd->{'advanced-properties'}{nimble_address}, 'plugindata: address is not advanced' );
ok( $pd->{'sensitive-properties'}{password}, 'plugindata: password still sensitive' );
is( $pd->{'isolate-properties'}, 1, 'plugindata: isolates properties on APIVER 17' );
{
  my $iso = $class->properties();
  ok( $iso->{$_}, "isolated properties: declares own $_" ) for qw(username password port);
  ok( $iso->{address} && $iso->{vnprefix}, 'isolated properties: legacy aliases always declared' );
  ok( $iso->{'san-multipath'}, 'isolated properties: san-multipath declared' );
  my @req = grep { !$iso->{$_}{optional} } keys %$iso;
  is_deeply( \@req, [], 'isolated properties: all optional in schema (options() decides)' );
  my @common = grep { $iso->{$_} } qw(nodes disable shared content content-dirs format
    preallocation prune-backups max-protected-backups path create-base-path create-subdirs
    bwlimit base snapshot-as-volume-chain mkdir delete digest);
  is_deeply( \@common, [], 'isolated properties: no common base property or API parameter declared' );
  my $o = $class->options();
  is( $o->{nimble_address}{fixed}, 1, 'isolated options: address fixed (required)' );
  is( $o->{username}{fixed}, 1, 'isolated options: username fixed (required)' );
  ok( $o->{password}{optional}, 'isolated options: sensitive password optional' );
  ok( $o->{address}{optional}, 'isolated options: legacy alias listed as optional' );
  ok( $o->{'san-multipath'}{optional}, 'isolated options: san-multipath optional' );
}
set_pve_storage_api( 16, 7 );
ok( !exists $class->plugindata()->{'isolate-properties'}, 'plugindata: no isolation before APIVER 17' );
ok( !$class->properties()->{username}, 'properties: username not declared when not isolated' );
set_pve_storage_api( 17, 8 );

my $props = $class->properties();
is( $props->{nimble_address}{title}, 'Array Address', 'properties: title set for web UI' );
is( $props->{'san-multipath'}{title}, 'SAN Multipath (cluster)', 'properties: san-multipath title' );
my @untitled = grep { ( /^nimble_/ || $_ eq 'san-multipath' ) && !$props->{$_}{title} } keys %$props;
is_deeply( \@untitled, [], 'properties: every nimble_/san-multipath property has a title' );
my $opts = $class->options();
my @bad_adv = grep { !$opts->{$_} } keys %{ $pd->{'advanced-properties'} };
is_deeply( \@bad_adv, [], 'plugindata: advanced properties are all options' );

is(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_snapshot_virtual_size_bytes( { size => 10 } ),
  10 * 1024 * 1024,
  'nimble_snapshot_virtual_size_bytes converts Nimble MB to bytes',
);
is(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_snapshot_virtual_size_bytes( { size => 0 } ),
  undef,
  'nimble_snapshot_virtual_size_bytes omits zero size',
);

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_get_volume_id'} = sub { return ( 'vid-1', {} ); };
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call'} = sub {
    my ( $scfg, $method, $endpoint ) = @_;
    if ( $endpoint =~ m{^snapshots\?vol_id=} ) {
      return {
        data => [
          {
            id            => 'snap-uuid-1',
            name          => 'vm-100-disk-0.snap-testsnap',
            size          => 512,
            creation_time => 1_700_000_000,
            vol_id        => 'vid-1',
          },
        ],
      };
    }
    die "unexpected endpoint: $endpoint";
  };
}

my $info = $class->volume_snapshot_info( {}, 'nimble1', 'vm-100-disk-0' );
ok( $info->{testsnap}, 'volume_snapshot_info maps PVE snap name from array name' );
is( $info->{testsnap}->{id}, 'snap-uuid-1', 'volume_snapshot_info id' );
is(
  $info->{testsnap}->{'virtual-size'},
  512 * 1024 * 1024,
  'volume_snapshot_info includes virtual-size in bytes',
);

eval { $class->volume_resize( {}, 'nimble1', 'vm-100-disk-0', 1024 * 1024 * 1024, 0, 'testsnap' ); };
like(
  $@,
  qr/Resizing a snapshot is not supported/,
  'volume_resize dies when snapname is set (API 15)',
);

{
  no warnings 'redefine';
  no strict 'refs';
  my $resize_called = 0;
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_resize_volume'} = sub {
    $resize_called = 1;
    return 1024 * 1024 * 1024;
  };
  $class->volume_resize( {}, 'nimble1', 'vm-100-disk-0', 1024 * 1024 * 1024, 0 );
  ok( $resize_called, 'volume_resize without snapname delegates to nimble_resize_volume' );
}

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_get_volume_id'} = sub { return ( 'vid-2', {} ); };
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call'} = sub {
    my ( $scfg, $method, $endpoint ) = @_;
    if ( $endpoint =~ m{^snapshots\?vol_id=} ) {
      return {
        data => [
          {
            id            => 'snap-uuid-2',
            name          => 'vm-100-disk-0.snap-hydrate',
            creation_time => 1_700_000_100,
            vol_id        => 'vid-2',
          },
        ],
      };
    }
    if ( $endpoint eq 'snapshots/snap-uuid-2' ) {
      return { data => { id => 'snap-uuid-2', size => 256 } };
    }
    die "unexpected endpoint: $endpoint";
  };
  my $info2 = $class->volume_snapshot_info( {}, 'nimble1', 'vm-100-disk-0' );
  is(
    $info2->{hydrate}->{'virtual-size'},
    256 * 1024 * 1024,
    'volume_snapshot_info hydrates virtual-size when list row omits size',
  );
}

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call'} = sub {
    my ( $scfg, $method, $endpoint ) = @_;
    if ( $method eq 'GET' && $endpoint eq 'pools' ) {
      return { data => [ { id => 'pool-1', name => 'default' } ] };
    }
    if ( $method eq 'GET' && $endpoint eq 'arrays' ) {
      return {
        data => [
          { id => 'array-z', pool_name => 'other' },
          { id => 'array-a', pool_name => 'default' },
        ],
      };
    }
    die "unexpected endpoint: $method $endpoint";
  };
  is(
    $class->get_identity( { nimble_pool_name => q{default} }, 'nimble1' ),
    'nimble:array-a',
    'get_identity picks pool-scoped array sorted by id',
  );
}

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call'} = sub { return undef };
  is(
    $class->get_identity( { nimble_address => q{nimble.example.com} }, 'nimble1' ),
    'nimble:nimble.example.com',
    'get_identity falls back to address when arrays API fails',
  );
}

done_testing();
