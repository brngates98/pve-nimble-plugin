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
  $INC{'PVE/Storage/Plugin.pm'} = 1;
}

BEGIN {
  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw(file_read_firstline run_command file_get_contents);
  sub file_read_firstline { return ''; }
  sub run_command         { die "run_command not stubbed"; }
  sub file_get_contents   { return ''; }
  $INC{'PVE/Tools.pm'} = 1;
}

require './NimbleStoragePlugin.pm';

is(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_volume_used_bytes( { vol_usage_compressed_bytes => 5_000_000 } ),
  5_000_000,
  'vol_usage_compressed_bytes is used as bytes (not scaled by MiB)',
);

is(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_volume_used_bytes( { vol_usage_compressed_bytes => 0, size => 1024 } ),
  0,
  'zero vol_usage_compressed_bytes is honored (does not fall back to size)',
);

is(
  PVE::Storage::Custom::NimbleStoragePlugin::nimble_volume_used_bytes( { size => 100 } ),
  100 * 1024 * 1024,
  'size fallback is converted from MB to bytes',
);

done_testing();
