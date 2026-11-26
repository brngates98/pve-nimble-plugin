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

my $host = \&PVE::Storage::Custom::NimbleStoragePlugin::nimble_iscsi_portal_host;

is( $host->('10.1.1.1:3260,2460'), '10.1.1.1', 'IPv4 portal strips port and TPGT' );
is( $host->('10.1.1.1:3260'),      '10.1.1.1', 'IPv4 portal strips port' );
is( $host->('[2001:db8::1]:3260'), '2001:db8::1', 'IPv6 portal keeps address inside brackets' );
is( $host->('[2001:db8::1]:3260,1'), '2001:db8::1', 'IPv6 portal strips TPGT' );
is( $host->(undef), '', 'undef portal yields empty host' );
is( $host->(''),    '', 'empty portal yields empty host' );

done_testing();
