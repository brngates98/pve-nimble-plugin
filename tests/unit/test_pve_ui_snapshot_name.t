#!/usr/bin/env perl
## Mirror tests for nimble_array_snapshot_is_pve_ui_snapshot / nimble_volname naming (no PVE::* load).
use strict;
use warnings;
use Test::More tests => 5;

sub nimble_name_prefix {
  my ($scfg) = @_;
  return $scfg->{ vnprefix } // '';
}

sub nimble_volname {
  my ( $scfg, $volname, $snapname ) = @_;
  $snapname //= '';
  my $name = nimble_name_prefix($scfg) . $volname;
  if ( length($snapname) ) {
    my $snap = $snapname;
    $snap =~ s/^(veeam_)/veeam-/;
    $snap = 'snap-' . $snap unless $snap =~ /^snap-/;
    $name .= '.' . $snap;
  }
  return $name;
}

sub is_pve_ui_snapshot {
  my ( $scfg, $pve_volname, $array_snap_name ) = @_;
  return 0 unless defined $array_snap_name && length $array_snap_name;
  my $base = nimble_volname( $scfg, $pve_volname );
  return 0 unless index( $array_snap_name, "$base." ) == 0;
  my $suffix = substr( $array_snap_name, length($base) + 1 );
  return ( $suffix =~ /^snap-/ ) ? 1 : 0;
}

my $scfg = { vnprefix => 'nimble-' };
my $vol  = 'vm-100-disk-0';

ok(
  is_pve_ui_snapshot( $scfg, $vol, nimble_volname( $scfg, $vol, 'daily' ) ),
  'PVE UI snap matches nimble_volname(scfg, vol, name)'
);
ok( !is_pve_ui_snapshot( $scfg, $vol, 'NSs-vm-100-disk-0-2024-01-01::12:00:00.000' ), 'Nimble NSs-* name is not PVE UI' );
ok( !is_pve_ui_snapshot( $scfg, $vol, 'veeam-backup-1' ), 'Unprefixed array name is not PVE UI' );

my $plain = { vnprefix => '' };
ok(
  is_pve_ui_snapshot( $plain, $vol, nimble_volname( $plain, $vol, 'x' ) ),
  'empty vnprefix: PVE UI snap still detected'
);

ok(
  !is_pve_ui_snapshot( $scfg, $vol, nimble_volname( $scfg, $vol ) . '.extra' ),
  'volume base + .extra without snap- is not PVE UI'
);

1;
