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
  sub APIVER { 14 }
  sub APIAGE { 5 }
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

set_pve_storage_api( 14, 5 );
is( $class->api(), 14, 'api() reports 14 when host APIVER is 14' );

set_pve_storage_api( 13, 4 );
is( $class->api(), 13, 'api() reports 13 when host APIVER is 13 (backward compatible)' );

set_pve_storage_api( 18, 5 );
is(
  $class->api(),
  14,
  'api() reports tested 14 when host APIVER is newer but within APIAGE window',
);

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
  'volume_resize dies when snapname is set (API 14)',
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
    $class->get_identity( { pool_name => 'default' }, 'nimble1' ),
    'nimble:array-a',
    'get_identity picks pool-scoped array sorted by id',
  );
}

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call'} = sub { return undef };
  is(
    $class->get_identity( { address => 'nimble.example.com' }, 'nimble1' ),
    'nimble:nimble.example.com',
    'get_identity falls back to address when arrays API fails',
  );
}

done_testing();
