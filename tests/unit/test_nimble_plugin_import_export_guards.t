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
  sub APIVER { return 13; }
  sub APIAGE { return 0; }
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
  sub run_command { die "run_command not stubbed for this test"; }
  sub file_get_contents { return ''; }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';

ok(
  PVE::Storage::Custom::NimbleStoragePlugin->can('volume_import'),
  'Loaded Nimble plugin module',
);

{
  no warnings 'redefine';
  *PVE::Storage::Custom::NimbleStoragePlugin::nimble_get_volume_id = sub {
    return ( 'vid-1', {} );
  };
}

{
  no warnings 'redefine';
  *PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call = sub {
    my ( $scfg, $method, $endpoint ) = @_;
    if ( $endpoint =~ m{^snapshots\?name=} ) {
      return { data => [ { name => 'vm-100-disk-0.snap-goodsnap', id => 'snap-1' } ] };
    }
    die "unexpected endpoint: $endpoint";
  };
}
is(
  PVE::Storage::Custom::NimbleStoragePlugin->volume_rollback_is_possible(
    {}, 'nimble1', 'vm-100-disk-0', 'goodsnap', []
  ),
  1,
  'rollback preflight succeeds when named snapshot exists',
);

my @blockers;
{
  no warnings 'redefine';
  *PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call = sub {
    return { data => [] };
  };
}
is(
  PVE::Storage::Custom::NimbleStoragePlugin->volume_rollback_is_possible(
    {}, 'nimble1', 'vm-100-disk-0', 'missingsnap', \@blockers
  ),
  0,
  'rollback preflight fails when named snapshot is missing',
);
is_deeply( \@blockers, ['missingsnap'], 'missing snapshot is reported as blocker' );

{
  no warnings 'redefine';
  *PVE::Storage::Custom::NimbleStoragePlugin::nimble_api_call = sub {
    my ( $scfg, $method, $endpoint ) = @_;
    if ( $endpoint =~ m{^snapshots\?vol_id=} ) {
      die "bad filter";
    }
    if ( $endpoint eq 'snapshots' ) {
      return { data => [ { id => 'snap-ts', vol_id => 'vid-1', creation_time => 1234 } ] };
    }
    die "unexpected endpoint: $endpoint";
  };
}
is(
  PVE::Storage::Custom::NimbleStoragePlugin->volume_rollback_is_possible(
    {}, 'nimble1', 'vm-100-disk-0', 'nimble1234', []
  ),
  1,
  'rollback preflight uses unfiltered snapshots fallback for nimble<epoch> names',
);

done_testing();
