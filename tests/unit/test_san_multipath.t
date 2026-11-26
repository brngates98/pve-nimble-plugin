#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PVE::Multipath::Config;

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
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents file_set_contents);
  sub file_read_firstline { return ''; }
  sub run_command         { return 1; }
  sub file_get_contents   { return ''; }
  sub file_set_contents   { return 1; }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';

my $pkg    = 'PVE::Storage::Custom::NimbleStoragePlugin';
my $plugin = $pkg;
my $wwid   = '2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

PVE::Multipath::Config::reset_fixture();

subtest 'flag off or missing API does nothing' => sub {
  PVE::Multipath::Config::reset_fixture();
  ok( !$pkg->san_multipath_register_wwid( $wwid, {} ), 'no register without the flag' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'multipath.cfg stays empty' );

  ok( !$pkg->san_multipath_register_wwid( $wwid, { 'san-multipath' => 0 } ), 'flag off skips register' );
};

subtest 'register is idempotent when the flag is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  ok( $pkg->san_multipath_register_wwid( $wwid, $scfg ), 'first register succeeds' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'WWID is in multipath.cfg' );
  my $entry = PVE::Multipath::Config::read_config()->{ids}->{$wwid};
  ok( !exists $entry->{'paths-expected'}, 'no paths-expected on auto entries' );

  ok( $pkg->san_multipath_register_wwid( $wwid, $scfg ), 'second register is still ok' );
  is( scalar keys %{ PVE::Multipath::Config::read_config()->{ids} }, 1, 'still one entry' );
};

subtest 'unregister removes the entry when the flag is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  ok( $pkg->san_multipath_unregister_wwid( $wwid, $scfg ), 'unregister succeeds' );
  ok( !exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'WWID is gone' );
  ok( $pkg->san_multipath_unregister_wwid( $wwid, $scfg ), 'unregister of a missing entry is ok' );
};

subtest 'alloc_image registers when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::nimble_create_volume"} = sub { return 1; };
    *{"${pkg}::get_device_path_wwid"}  = sub { return ( '/dev/x', $wwid ); };
  }
  my $name = $plugin->alloc_image( 'nimble1', { 'san-multipath' => 1 }, 100, 'raw', 'vm-100-disk-0', 1024 );
  is( $name, 'vm-100-disk-0', 'alloc still returns the volume name' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'alloc registered the WWID' );
};

subtest 'activate_volume registers lazily when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::nimble_volume_connection"} = sub { return 1; };
    *{"${pkg}::map_volume"}               = sub { return ( '/dev/x', $wwid ); };
  }
  ok( $plugin->activate_volume( 'nimble1', { 'san-multipath' => 1 }, 'vm-100-disk-0' ), 'activate succeeds' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'activate registered the WWID from map_volume' );
};

subtest 'free_image unregisters after remove when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::deactivate_volume"}   = sub { return 1; };
    *{"${pkg}::get_device_path_wwid"} = sub { return ( '/dev/x', $wwid ); };
    *{"${pkg}::nimble_remove_volume"} = sub { return 1; };
    *{"${pkg}::nimble_multipath_deregister"} = sub { return 1; };
  }
  # free_image calls the package-level helper, not a method — stub via no-op already covered by
  # not touching multipath conf.d; SAN unregister is what we assert.
  $plugin->free_image( 'nimble1', $scfg, 'vm-100-disk-0' );
  ok( !exists PVE::Multipath::Config::read_config()->{ids}->{$wwid}, 'free_image removed the WWID entry' );
};

subtest 'empty WWID is ignored' => sub {
  PVE::Multipath::Config::reset_fixture();
  ok( !$pkg->san_multipath_register_wwid( '', { 'san-multipath' => 1 } ), 'empty WWID does not register' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'cfg unchanged' );
};

subtest 'registration errors do not fail activate or clone' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::nimble_volume_connection"}   = sub { return 1; };
    *{"${pkg}::map_volume"}                 = sub { return ( '/dev/x', $wwid ); };
    *{"${pkg}::get_device_path_wwid"}        = sub { die "array unreachable\n"; };
    *{"${pkg}::nimble_clone_from_snapshot"} = sub { return 1; };
    *{"${pkg}::find_free_diskname"}         = sub { return 'vm-200-disk-0'; };
  }
  local $PVE::Multipath::Config::FAIL = "lock unavailable\n";
  ok( $plugin->activate_volume( 'nimble1', { 'san-multipath' => 1 }, 'vm-100-disk-0' ),
    'activate succeeds when multipath.cfg lock fails during registration' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'no entry after failed registration' );
  $PVE::Multipath::Config::FAIL = undef;

  my $clone = eval { $plugin->clone_image( { 'san-multipath' => 1 }, 'nimble1', 'vm-100-disk-0', 200, 'snap1' ) };
  is( $clone, 'vm-200-disk-0', 'clone succeeds when SAN registration cannot resolve the WWID' );
  is( $@, '', 'clone does not die from SAN registration failure' );
};

subtest 'lock failure is soft' => sub {
  PVE::Multipath::Config::reset_fixture();
  local $PVE::Multipath::Config::FAIL = "lock unavailable\n";
  ok( !$pkg->san_multipath_register_wwid( $wwid, { 'san-multipath' => 1 } ), 'register returns false on lock failure' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'cfg unchanged after lock failure' );
};

subtest 'pve-managed WWIDs skip plugin aliases' => sub {
  PVE::Multipath::Config::reset_fixture();
  PVE::Multipath::Config::write_cluster_config( { ids => { $wwid => { type => 'wwid' } } } );
  my $managed = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_pve_managed_wwids();
  ok( $managed->{ lc($wwid) }, 'WWID from multipath.cfg is marked PVE-managed' );
  my %aliases = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_build_aliases(
    'nimble1', { 'vm-100-disk-0' => $wwid }
  );
  ok( !exists $aliases{$wwid}, 'build_aliases skips PVE-managed WWID' );
};

done_testing;
