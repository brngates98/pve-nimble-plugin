package PVE::Multipath::Config;

use strict;
use warnings;

# Stub for hosts without libpve-storage-perl multipath support. Real PVE modules win via @INC order.

our $CFG       = { ids => {} };
our $OVERRIDES = '';
our $FAIL      = undef;

sub reset_fixture {
  $CFG       = { ids => {} };
  $OVERRIDES = '';
  $FAIL      = undef;
}

sub lock_config {
  my ( $code, $errmsg ) = @_;
  if ($FAIL) {
    die defined($errmsg) ? "$errmsg - $FAIL" : $FAIL;
  }
  $code->();
}

sub read_config {
  return $CFG;
}

sub write_cluster_config {
  my ($cfg) = @_;
  $CFG = $cfg;
}

sub lock_overrides {
  my ( $code, $errmsg ) = @_;
  if ($FAIL) {
    die defined($errmsg) ? "$errmsg - $FAIL" : $FAIL;
  }
  $code->();
}

sub read_overrides {
  return $OVERRIDES;
}

sub write_overrides {
  my ($text) = @_;
  $OVERRIDES = $text // '';
}

sub check_overrides {
  my ($text) = @_;
  return 1;
}

sub format_overrides {
  my ($text) = @_;
  return $text // '';
}

1;
