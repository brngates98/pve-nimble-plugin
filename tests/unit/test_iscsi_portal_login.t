#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

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

my $fake_iscsiadm = File::Spec->catfile( tempdir( CLEANUP => 1 ), 'iscsiadm' );
open my $fh, '>', $fake_iscsiadm or die $!;
print {$fh} "#!/bin/sh\nexit 0\n";
close $fh;
chmod 0755, $fake_iscsiadm;

my $session_output = '';
my @login_cmds;

BEGIN {
  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents exec_command);
  sub file_read_firstline { return ''; }
  sub file_get_contents   { return ''; }
  sub exec_command        { return 1; }
  sub run_command {
    my ( $cmd, %opts ) = @_;
    if ( ref($cmd) eq 'ARRAY' && ( $cmd->[-1] // '' ) eq '--login' ) {
      push @login_cmds, [@$cmd];
      die "iscsiadm: session already exists (exit code 15)\n";
    }
    if ( ref($cmd) eq 'ARRAY' && ( $cmd->[1] // '' ) eq '-m' && ( $cmd->[2] // '' ) eq 'session' ) {
      my $func = $opts{ outfunc };
      $func->( $session_output ) if $func && length $session_output;
    }
    return 1;
  }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';

{
  no warnings 'redefine';
  no strict 'refs';
  *{'PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsiadm_path'} = sub { return $fake_iscsiadm };
}

my $iqn = 'iqn.2010-06.com.nimble:vol-test';

sub reset_session {
  $session_output = '';
  @login_cmds     = ();
}

reset_session();
$session_output = "tcp: [1] 10.0.0.1:3260,1 $iqn (non-flash)\n";
ok(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_portal_in_sessions( $iqn, '10.0.0.1:3260', 0 ),
  'portal_in_sessions true when IQN and portal match one session line',
);
ok(
  !PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_portal_in_sessions( $iqn, '10.0.0.2:3260', 0 ),
  'portal_in_sessions false for second multipath portal when only first is logged in',
);

reset_session();
$session_output = "tcp: [1] 10.0.0.1:3260,1 $iqn (non-flash)\ntcp: [2] 10.0.0.2:3260,1 $iqn (non-flash)\n";
ok(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_all_portals_in_sessions(
    $iqn,
    [ '10.0.0.1:3260', '10.0.0.2:3260' ],
    0
  ),
  'all_portals_in_sessions true when every portal has a session',
);

reset_session();
PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_node_login_if_needed( $iqn, '10.0.0.1:3260' );
PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_node_login_if_needed( $iqn, '10.0.0.2:3260' );
is( scalar @login_cmds, 2, 'node_login_if_needed attempts login on each portal (multipath)' );

reset_session();
$session_output = "tcp: [1] 10.0.0.1:3260,1 $iqn (non-flash)\n";
PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_node_login_if_needed( $iqn, '10.0.0.1:3260' );
is( scalar @login_cmds, 0, 'node_login_if_needed skips login when portal already in session' );

# Discussion #11: VM start / live migrate waited ~20–24s per disk on ACL/sendtargets even when
# `iscsiadm -m session` already listed the volume IQN (empty node DB skipped the old fast path).
{
  my $P = 'PVE::Storage::Custom::NimbleStoragePlugin';
  my ( $discovery_calls, $slept, $sendtargets ) = ( 0, 0, 0 );
  no warnings 'redefine';
  no strict 'refs';
  local *{"${P}::nimble_get_volume_info"} = sub {
    return { target_name => $iqn, serial => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' };
  };
  local *{"${P}::nimble_iscsi_target_in_sessions"} = sub { return 1; };
  local *{"${P}::nimble_iscsi_node_portals_for_target"} = sub { return (); };    # empty node DB
  local *{"${P}::get_nimble_iscsi_discovery_ips"} = sub { $discovery_calls++; return ('10.0.0.1'); };
  local *{"${P}::sleep"} = sub { $slept += $_[0] // 1; };
  local *{"${P}::run_command"} = sub {
    my ($cmd) = @_;
    $sendtargets++ if ref($cmd) eq 'ARRAY' && grep { $_ eq 'sendtargets' } @$cmd;
    return 1;
  };
  ok(
    $P->nimble_iscsi_establish_volume_session( {}, 'vm-100-disk-0', 'nimble1' ),
    'establish: returns immediately when session already up (discussion #11)',
  );
  is( $discovery_calls, 0, 'establish: skips discovery IP lookup when session already up' );
  is( $sendtargets,     0, 'establish: skips sendtargets ACL wait when session already up' );
  is( $slept,           0, 'establish: does not sleep for ACL propagation when session already up' );
}

done_testing();
