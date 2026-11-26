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
my $serial = 'a' x 32;                 # Nimble API serial_number (32-hex NAA body)
my $wwid   = '2' . $serial;            # multipath WWID (leading type nibble + NAA)

PVE::Multipath::Config::reset_fixture();

subtest 'nimble_wwid_from_serial derives multipath WWID without a mapped LUN' => sub {
  is(
    PVE::Storage::Custom::NimbleStoragePlugin::nimble_wwid_from_serial($serial),
    $wwid,
    '32-hex serial becomes 2+serial',
  );
  is(
    PVE::Storage::Custom::NimbleStoragePlugin::nimble_wwid_from_serial($wwid),
    $wwid,
    'already-prefixed WWID is left alone',
  );
  is(
    PVE::Storage::Custom::NimbleStoragePlugin::nimble_wwid_from_serial('short'),
    '',
    'non-NAA serial is rejected',
  );
};

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

subtest 'alloc_image registers from API serial when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::nimble_create_volume"}  = sub { return 1; };
    *{"${pkg}::nimble_get_volume_info"} = sub { return { serial => $serial }; };
  }
  my $name = $plugin->alloc_image( 'nimble1', { 'san-multipath' => 1 }, 100, 'raw', 'vm-100-disk-0', 1024 );
  is( $name, 'vm-100-disk-0', 'alloc still returns the volume name' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid},
    'alloc registered WWID from serial without a mapped LUN' );
};

subtest 'activate_volume relies on map_volume for SAN registration' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $map_saw_flag = 0;
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::nimble_volume_connection"} = sub { return 1; };
    *{"${pkg}::map_volume"} = sub {
      my ( $c, $sid, $scfg, $vn ) = @_;
      $map_saw_flag = 1 if $scfg && $scfg->{'san-multipath'};
      $c->san_multipath_register_wwid( $wwid, $scfg );
      return ( '/dev/x', $wwid );
    };
  }
  ok( $plugin->activate_volume( 'nimble1', { 'san-multipath' => 1 }, 'vm-100-disk-0' ), 'activate succeeds' );
  ok( $map_saw_flag, 'activate passes san-multipath scfg into map_volume' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$wwid},
    'SAN registration happens in map_volume (no second multipath.cfg lock in activate)' );
};

subtest 'free_image unregisters after remove when san-multipath is on' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  $pkg->san_multipath_register_wwid( $wwid, $scfg );
  {
    no warnings 'redefine';
    no strict 'refs';
    *{"${pkg}::deactivate_volume"}      = sub { return 1; };
    *{"${pkg}::nimble_get_volume_info"} = sub { return { serial => $serial }; };
    *{"${pkg}::nimble_remove_volume"}   = sub { return 1; };
    *{"${pkg}::nimble_multipath_deregister"} = sub { return 1; };
  }
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
    *{"${pkg}::nimble_volume_connection"} = sub { return 1; };
    *{"${pkg}::map_volume"} = sub {
      my ( $c, $sid, $scfg ) = @_;
      # Simulate map's SAN register failing soft under lock pressure.
      local $PVE::Multipath::Config::FAIL = "lock unavailable\n";
      $c->san_multipath_register_wwid( $wwid, $scfg );
      return ( '/dev/x', $wwid );
    };
    *{"${pkg}::nimble_get_volume_info"}     = sub { die "array unreachable\n"; };
    *{"${pkg}::nimble_clone_from_snapshot"} = sub { return 1; };
    *{"${pkg}::find_free_diskname"}         = sub { return 'vm-200-disk-0'; };
  }
  ok( $plugin->activate_volume( 'nimble1', { 'san-multipath' => 1 }, 'vm-100-disk-0' ),
    'activate succeeds when multipath.cfg lock fails during map registration' );
  is_deeply( PVE::Multipath::Config::read_config()->{ids}, {}, 'no entry after failed registration' );

  my $clone = eval { $plugin->clone_image( { 'san-multipath' => 1 }, 'nimble1', 'vm-100-disk-0', 200, 'snap1' ) };
  is( $clone, 'vm-200-disk-0', 'clone succeeds when SAN registration cannot resolve the WWID' );
  is( $@, '', 'clone does not die from SAN registration failure' );
};

subtest 'register is case-insensitive against existing multipath.cfg keys' => sub {
  PVE::Multipath::Config::reset_fixture();
  my $upper = uc($wwid);
  PVE::Multipath::Config::write_cluster_config( { ids => { $upper => { type => 'wwid' } } } );
  ok( $pkg->san_multipath_register_wwid( $wwid, { 'san-multipath' => 1 } ), 'register succeeds' );
  is( scalar keys %{ PVE::Multipath::Config::read_config()->{ids} }, 1, 'no duplicate casing row' );
  ok( exists PVE::Multipath::Config::read_config()->{ids}->{$upper}, 'original casing kept' );
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

subtest 'Multipath Overrides: detect an existing Nimble device entry' => sub {
  my $has = \&PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_text_has_nimble_device;
  my $blk = do {
    no strict 'refs';
    ${"${pkg}::NIMBLE_MULTIPATH_DEVICE_BLOCK"};
  };
  ok( $has->($blk), 'overrides: shipped device block is recognized' );
  ok( !$has->(''), 'overrides: empty text has no Nimble device' );
  ok(
    !$has->(
      qq{blacklist_exceptions {\n    device {\n        vendor "Nimble"\n        product "Server"\n    }\n}\n}
    ),
    'overrides: Nimble only under blacklist_exceptions does not count',
  );
  ok(
    !$has->(qq{devices {\n    device {\n        vendor "OTHER"\n    }\n}\n}),
    'overrides: other vendor only',
  );
  ok(
    $has->(qq{devices {\n    device {\n        vendor Nimble\n        no_path_retry queue\n    }\n}\n}),
    'overrides: admin-tuned unquoted Nimble entry is kept (not duplicated)',
  );
  ok(
    !$has->(qq{devices {\n    device {\n        # vendor "Nimble"\n    }\n}\n}),
    'overrides: commented-out entry ignored',
  );
  like( $blk, qr/no_path_retry\s+30/, 'overrides: block uses README no_path_retry 30, not the built-in queue' );
  unlike( $blk, qr/^\s*(defaults|blacklist)\b/m, 'overrides: block carries no host-wide defaults/blacklist' );
};

subtest 'activate_storage must not reload multipathd every pvestatd cycle' => sub {
  use File::Temp qw(tempdir);
  my $dir   = tempdir( CLEANUP => 1 );
  my $conf  = "$dir/nimble-nimble1.conf";
  my $wwids = "$dir/wwids";
  no warnings 'redefine';
  no strict 'refs';
  my ( $reconf, @mpcmds ) = (0);
  local *{"${pkg}::nimble_multipath_conf_path"}         = sub { $conf };
  local *{"${pkg}::nimble_multipath_load_wwid_cache"}   = sub { { 'vm-100-disk-0' => '2abcdef0123456789abcdef0123456789' } };
  local *{"${pkg}::nimble_multipath_wwid_in_main_conf"} = sub { 0 };
  local *{"${pkg}::nimble_multipath_pve_managed_wwids"} = sub { {} };
  local *{"${pkg}::nimble_multipath_reconfigure"}       = sub { $reconf++ };
  local *{"${pkg}::get_command_path"}                   = sub { '/sbin/multipath' };
  local *{"${pkg}::exec_command"}                       = sub { push @mpcmds, join ' ', @{ $_[0] } };
  local *{"${pkg}::file_get_contents"} = sub {
    open( my $fh, '<', $_[0] ) or die "no $_[0]\n";
    local $/;
    <$fh>;
  };
  # Keep local for the whole subtest (not a nested block).
  no strict 'refs';
  local ${"${pkg}::NIMBLE_MULTIPATH_WWIDS_FILE"} = $wwids;
  use strict 'refs';
  my $restore = \&PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_restore_aliases;

  $restore->('nimble1');
  ok( -s $conf, 'activation 1: missing drop-in is written' );
  is( $reconf, 1, 'activation 1: one multipathd reconfigure' );
  is_deeply(
    \@mpcmds,
    [ '/sbin/multipath -a -- 2abcdef0123456789abcdef0123456789' ],
    'activation 1: WWID allow-listed while the wwids file lacks it',
  );
  $restore->('nimble1') for 1 .. 10;
  is( $reconf, 1, 'activations 2-11 (pvestatd cycles): no further reconfigure when the drop-in is current' );

  open( my $fh, '>', $wwids ) or die;
  print $fh "# header\n/2abcdef0123456789abcdef0123456789/\n/abcdef0123456789abcdef0123456789/\n";
  close $fh;
  @mpcmds = ();
  $restore->('nimble1') for 1 .. 5;
  is( scalar(@mpcmds), 0, 'allow-list: no multipath -a spawned once the wwids file has the WWID' );

  open( $fh, '>', $conf ) or die;
  print $fh "stale\n";
  close $fh;
  $restore->('nimble1');
  unlike( do { local ( @ARGV, $/ ) = ($conf); <> }, qr/^stale$/m, 'stale drop-in is rewritten' );
  is( $reconf, 2, 'stale drop-in: exactly one more reconfigure' );
};

subtest 'PVE-managed multipath guard (case-insensitive, no reconfigure)' => sub {
  no warnings 'redefine';
  no strict 'refs';
  local *{"${pkg}::nimble_multipath_wwid_in_main_conf"} = sub { 0 };
  my $cache = { 'vm-100-disk-0' => '3600aaaa', 'vm-100-disk-1' => '3600BBBB' };

  PVE::Multipath::Config::reset_fixture();
  my %a = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_build_aliases( 'nimble1', $cache );
  is( scalar( keys %a ), 2, 'managed multipath: both aliased when multipath.cfg empty' );

  PVE::Multipath::Config::write_cluster_config( { ids => { '3600bbbb' => { type => 'wwid' } } } );
  %a = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_build_aliases( 'nimble1', $cache );
  is_deeply(
    \%a,
    { '3600aaaa' => 'nimble1-vm-100-disk-0' },
    'managed multipath: PVE-managed WWID gets no plugin alias (case-insensitive)',
  );

  {
    require File::Temp;
    my $dir    = File::Temp::tempdir( CLEANUP => 1 );
    my %store  = %$cache;
    my $reconf = 0;
    local *{"${pkg}::nimble_multipath_conf_path"}       = sub { "$dir/nimble-nimble1.conf" };
    local *{"${pkg}::nimble_multipath_load_wwid_cache"} = sub { +{%store} };
    local *{"${pkg}::nimble_multipath_save_wwid_cache"} = sub { %store = %{ $_[1] } };
    local *{"${pkg}::nimble_multipath_reconfigure"}     = sub { $reconf++ };
    local *{"${pkg}::nimble_multipath_allowlist_wwid"}  = sub { };
    local *{"${pkg}::file_get_contents"} = sub {
      open( my $fh, '<', $_[0] ) or die "no $_[0]\n";
      local $/;
      <$fh>;
    };
    my %al = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_build_aliases( 'nimble1', \%store );
    PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_write_conf( 'nimble1', \%al );
    PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_register( 'nimble1', 'vm-100-disk-2', '3600BBBB' );
    is( $store{'vm-100-disk-2'}, '3600BBBB', 'managed multipath: PVE-managed WWID is still cached' );
    is( $reconf, 0, 'managed multipath: no multipathd reconfigure when only a PVE-managed WWID was added' );
  }
};

subtest 'map_volume registers SAN before plugin alias when san-multipath is on' => sub {
  # Full map_volume needs a real block device (-b); assert the source order and the
  # SAN-first → build_aliases skip contract that order implements.
  open my $fh, '<', 'NimbleStoragePlugin.pm' or die "NimbleStoragePlugin.pm: $!";
  local $/;
  my $src = <$fh>;
  close $fh;
  ok(
    $src =~ /sub map_volume \{(.+?)\nsub unmap_volume/s,
    'map_volume body locatable for ordering check',
  );
  my $body = $1 // '';
  my $san_pos   = index( $body, 'san_multipath_register_wwid' );
  my $alias_pos = index( $body, 'nimble_multipath_register(' );
  ok( $san_pos >= 0,   'map_volume calls san_multipath_register_wwid' );
  ok( $alias_pos >= 0, 'map_volume calls nimble_multipath_register' );
  ok(
    $san_pos < $alias_pos,
    'map_volume: SAN multipath register precedes plugin alias register',
  );

  PVE::Multipath::Config::reset_fixture();
  my $scfg = { 'san-multipath' => 1 };
  ok( $pkg->san_multipath_register_wwid( $wwid, $scfg ), 'SAN-first register succeeds' );
  my %aliases = PVE::Storage::Custom::NimbleStoragePlugin::nimble_multipath_build_aliases(
    'nimble1', { 'vm-100-disk-0' => $wwid }
  );
  ok( !exists $aliases{$wwid}, 'after SAN-first, build_aliases skips that WWID (no dual ownership)' );
};

done_testing;
