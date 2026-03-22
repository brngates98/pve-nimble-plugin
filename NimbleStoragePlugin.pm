package PVE::Storage::Custom::NimbleStoragePlugin;

use strict;
use warnings;

use Data::Dumper qw( Dumper );

use IO::File   ();
use File::Path ();

use PVE::JSONSchema ();
use PVE::Tools qw( file_get_contents file_read_firstline run_command );
use PVE::INotify         ();
use PVE::Storage         ();
use PVE::Storage::Plugin ();

use JSON::XS qw( decode_json encode_json );
use LWP::UserAgent ();
use HTTP::Headers  ();
use HTTP::Request  ();
use URI::Escape qw( uri_escape );
use File::Basename qw( basename dirname );
use Time::HiRes qw( gettimeofday sleep );
use Cwd qw( abs_path );

use base qw(PVE::Storage::Plugin);

push @PVE::Storage::Plugin::SHARED_STORAGE, 'nimble';
$Data::Dumper::Terse  = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Useqq  = 1;

use constant {
  ERROR_TOKEN_UPDATED => -1,
  ERROR_SUCCESS       => 0,
  ERROR_API_ERROR     => 1,
  ERROR_NETWORK_ERROR => 2,
  ERROR_AUTH_FAILED   => 3,
};

use constant {
  TOKEN_STATE_LOGIN  => 0,
  TOKEN_STATE_NEEDED => 1,
  TOKEN_STATE_CACHED => 2,
};

my $NIMBLE_API_VERSION = 'v1';
my $default_port       = 5392;
my $DEBUG              = $ENV{ NIMBLE_DEBUG } // 0;

sub get_debug_level {
  my ( $scfg ) = @_;
  return $scfg->{ debug } if defined $scfg && defined $scfg->{ debug };
  return $DEBUG;
}

sub set_debug_from_config {
  my ( $scfg ) = @_;
  if ( defined $scfg && defined $scfg->{ debug } ) {
    $DEBUG = $scfg->{ debug };
  }
}

### Configuration
sub api {
  # PVE::Storage::APIVER / APIAGE are `use constant` (subs), not package scalars — do not use $PVE::Storage::APIVER.
  # Call with (); bareword form trips strict subs under perl 5.36+ (e.g. CI Docker bookworm).
  my $tested_apiver = 13;
  my $apiver        = eval { PVE::Storage::APIVER() };
  my $apiage        = eval { PVE::Storage::APIAGE() };
  $apiver = $tested_apiver if !defined($apiver) || $apiver !~ /^\d+$/;
  $apiage = 0              if !defined($apiage) || $apiage !~ /^\d+$/;
  if ( $apiver >= 2 and $apiver <= $tested_apiver ) {
    return $apiver;
  }
  if ( $apiver - $apiage < $tested_apiver ) {
    return $tested_apiver;
  }
  return 10;
}

sub type {
  return "nimble";
}

sub plugindata {
  return {
    content => [ { images => 1, none => 1 }, { images => 1 } ],
    format  => [ { raw    => 1 },            "raw" ],
    # Like ESXi/PBS: `password` is not in $config during check_config; pvesm passes it via on_add_hook %sensitive.
    'sensitive-properties' => { password => 1 },
  };
}

sub properties {
  return {
    address => {
      description => "HPE Nimble array management IP or DNS name.",
      type        => 'string'
    },
    # Do not redeclare username/password here (RBD/CIFS own those names globally). List them in options()
    # only — same pattern as ESXi. Password is sensitive: stored under /etc/pve/priv/nimble/<storeid>.pw via on_add_hook.
    initiator_group => {
      description => "Initiator group name (optional). If unset, a group is created automatically using this host's iSCSI IQN.",
      type        => 'string'
    },
    vnprefix => {
      description => "Prefix for volume names on the Nimble array.",
      type        => 'string'
    },
    pool_name => {
      description => "Pool name for new volumes (optional).",
      type        => 'string'
    },
    volume_collection => {
      description => "Nimble volume collection name (optional). New volumes will be added to this collection so array-side protection/snapshot schedules apply.",
      type        => 'string'
    },
    check_ssl => {
      description => "Verify the server's TLS certificate.",
      type        => 'boolean',
      default     => 'no'
    },
    token_ttl => {
      description => "Session token time-to-live in seconds.",
      type        => 'integer',
      default     => 3600
    },
    debug => {
      description => "Enable debug logging (0=off, 1=basic, 2=verbose, 3=trace).",
      type        => 'integer',
      minimum     => 0,
      maximum     => 3,
      default     => 0
    },
    auto_iscsi_discovery => {
      description => "When storage is activated, run iSCSI discovery and login using the array's discovery IPs (from Nimble subnets API). Opt-in only; default off.",
      type        => 'boolean',
      default     => 'no'
    },
    iscsi_discovery_ips => {
      description => "Comma-separated iSCSI discovery addresses (IP or hostname, optional :port). Merged with GET subnets; use when subnets returns no discovery_ip or list is wrapped differently on your firmware.",
      type        => 'string',
    },
  };
}

sub options {
  return {
    address   => { fixed => 1 },
    username  => { fixed => 1 },
    password  => { optional => 1 },
    initiator_group => { optional => 1 },

    vnprefix  => { optional => 1 },
    pool_name => { optional => 1 },
    volume_collection => { optional => 1 },
    check_ssl => { optional => 1 },
    token_ttl => { optional => 1 },
    debug     => { optional => 1 },
    auto_iscsi_discovery => { optional => 1 },
    iscsi_discovery_ips  => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
}

sub check_config {
  my ( $class, $sectionId, $config, $create, $skipSchemaCheck ) = @_;

  # Brief interim configs may have used nimble_user without username.
  if ( defined $config->{ nimble_user } && length( $config->{ nimble_user } ) ) {
    $config->{ username } //= $config->{ nimble_user };
  }

  return $class->SUPER::check_config( $sectionId, $config, $create, $skipSchemaCheck );
}

sub nimble_password_file {
  my ($storeid) = @_;
  return "/etc/pve/priv/nimble/${storeid}.pw";
}

sub nimble_set_password {
  my ( $storeid, $password ) = @_;
  my $dir = '/etc/pve/priv/nimble';
  if ( !-d $dir ) {
    eval { File::Path::make_path( $dir, { mode => 0700 } ); };
    die "Error :: cannot create $dir: $@\n" if $@ || !-d $dir;
  }
  PVE::Tools::file_set_contents( nimble_password_file($storeid), "$password\n", 0600, 1 );
}

sub nimble_read_password_file {
  my ($storeid) = @_;
  my $f = nimble_password_file($storeid);
  return undef unless -f $f;
  my $c = PVE::Tools::file_get_contents($f);
  return undef unless defined $c;
  chomp $c;
  return length($c) ? $c : undef;
}

sub nimble_delete_password_file {
  my ($storeid) = @_;
  my $f = nimble_password_file($storeid);
  unlink $f if -e $f;
}

sub on_add_hook {
  my ( $class, $storeid, $scfg, %sensitive ) = @_;
  my $pw = $sensitive{ password };
  die "missing password\n" if !defined($pw) || $pw eq '';
  nimble_set_password( $storeid, $pw );
  return;
}

sub on_update_hook {
  my ( $class, $storeid, $scfg, %sensitive ) = @_;
  return if !exists( $sensitive{ password } );
  if ( defined( $sensitive{ password } ) && $sensitive{ password } ne '' ) {
    nimble_set_password( $storeid, $sensitive{ password } );
  }
  else {
    nimble_delete_password_file($storeid);
  }
  return;
}

sub on_delete_hook {
  my ( $class, $storeid, $scfg ) = @_;
  nimble_delete_password_file($storeid);
  if ( my $p = get_token_cache_path($storeid) ) {
    unlink $p if -e $p;
  }
  return;
}

sub nimble_api_credentials {
  my ( $scfg, $storeid ) = @_;
  my $user = $scfg->{ username } // $scfg->{ nimble_user };
  die "Error :: username not set\n" if !defined($user) || $user eq '';
  my $pass = $scfg->{ password } // $scfg->{ nimble_password };
  if ( !defined($pass) || $pass eq '' ) {
    $pass = nimble_read_password_file($storeid) if defined $storeid && $storeid ne '';
  }
  # Some PVE workers pass a redacted $scfg (no password) but include the storage id under another key.
  if ( (!defined($pass) || $pass eq '') && ref($scfg) eq 'HASH' ) {
    for my $k (qw( storage storagename )) {
      my $sid = $scfg->{ $k };
      next unless defined $sid && $sid ne '';
      $pass = nimble_read_password_file($sid);
      last if defined $pass && $pass ne '';
    }
  }
  die "Error :: password not set (use pvesm --password or password file)\n" if !defined($pass) || $pass eq '';
  return ( $user, $pass );
}

### Commands and helpers
my $cmd = {
  multipath  => '/sbin/multipath',
  multipathd => '/sbin/multipathd',
  blockdev   => '/usr/sbin/blockdev',
  dmsetup    => '/sbin/dmsetup',
  kpartx     => '/sbin/kpartx',
  udevadm    => '/usr/bin/udevadm',
  sync       => '/usr/bin/sync'
};

my $commands_checked = 0;

sub get_command_path {
  my ( $name ) = @_;
  if ( !$commands_checked ) {
    foreach my $n ( keys %$cmd ) {
      my $p = $cmd->{ $n };
      die "Error :: Command '$n' not found or not executable at '$p'\n" if !-x $p;
    }
    $commands_checked = 1;
  }
  return $cmd->{ $name };
}

# ($command, $dm, %param) — always pass numeric $dm before run_command options (e.g. timeout => 60).
sub exec_command {
  my ( $command, $dm, %param ) = @_;
  $dm //= 1;
  my $cmd_name = $command->[0];
  if ( exists $cmd->{ $cmd_name } ) {
    eval { $command->[0] = get_command_path( $cmd_name ); };
    warn "Warning :: $@" if $@ && $dm >= 0;
  }
  print "Debug :: execute '" . join( ' ', @$command ) . "'\n" if $DEBUG >= 2;
  $param{ 'quiet' } = 1 if $DEBUG < 3 && !exists $param{ 'quiet' };
  eval { run_command( $command, %param ) };
  if ( $@ ) {
    my $err = " :: Cannot execute '" . join( ' ', @$command ) . "'\n  ==> $@\n";
    die 'Error' . $err if $dm > 0;
    warn 'Warning' . $err unless $dm < 0;
    return $dm < 0;
  }
  return $dm >= 0;
}

sub nimble_name_prefix {
  my ( $scfg ) = @_;
  my $prefix = $scfg->{ vnprefix } // '';
  return $prefix;
}

sub nimble_volname {
  my ( $scfg, $volname, $snapname ) = @_;
  my $name = nimble_name_prefix( $scfg ) . $volname;
  if ( length( $snapname ) ) {
    my $snap = $snapname;
    $snap =~ s/^(veeam_)/veeam-/;
    $snap = 'snap-' . $snap unless $snap =~ /^snap-/;
    $name .= '.' . $snap;
  }
  return $name;
}

# Trim / de-space / casefold for comparing API serial_number to sysfs VPD serial.
sub nimble_serial_normalize {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/^\s+|\s+$//g;
  $s =~ s/\s+//g;
  return lc $s;
}

# True if Nimble API serial matches kernel-reported SCSI unit serial (spacing/case quirks).
sub nimble_serial_matches {
  my ( $api, $kernel ) = @_;
  return 0 if !length( $api ) || !length( $kernel );
  my $a = nimble_serial_normalize($api);
  my $b = nimble_serial_normalize($kernel);
  return 0 if !length($a) || !length($b);
  return 1 if $a eq $b;
  return 1 if $kernel =~ /\Q$api\E/i;
  my $min = length($a) < length($b) ? length($a) : length($b);
  return 0 if $min < 8;
  return 1 if index( $b, $a ) >= 0 || index( $a, $b ) >= 0;
  return 0;
}

# PVE loads custom storage plugins with perl -T (taint). Paths from readdir/readlink/abs_path are tainted;
# pass only /^...$/ captures into exec/run_command or blockdev dies with "Insecure dependency in exec".
sub nimble_untaint_dev_path {
  my ($p) = @_;
  return '' unless defined $p && length $p;
  return $1 if $p =~ m{^(/dev/dm-\d+)$};
  return $1 if $p =~ m{^(/dev/sd[a-z]+)$};
  return $1 if $p =~ m{^(/dev/nvme\d+n\d+(?:p\d+)?)$};
  return $1 if $p =~ m{^(/dev/disk/by-id/[a-zA-Z0-9_.:@+=-]+)$};
  return '';
}

sub nimble_untaint_multipath_wwid {
  my ($w) = @_;
  return '' unless defined $w && length $w;
  return $1 if $w =~ /^([0-9a-f]+)$/i;
  return '';
}

# multipath -l / multipathd WWID often matches dm-uuid-mpath-* / scsi-* with a leading type nibble (e.g. 2)
# before the 32-hex NAA; wwn-0x<32 hex> may omit that leading digit — see nimble_multipath_wwid_from_by_id_basename.
sub nimble_multipath_wwid_from_by_id_basename {
  my ($entry_name) = @_;
  return '' unless defined $entry_name && length $entry_name;
  if ( $entry_name =~ /^dm-uuid-mpath-([0-9a-f]+)$/i ) {
    return lc($1);
  }
  if ( $entry_name =~ /^scsi-(2[0-9a-f]{32})$/i ) {
    return lc($1);
  }
  if ( $entry_name =~ /^wwn-0x([0-9a-f]{32})$/i ) {
    return '2' . lc($1);
  }
  if ( $entry_name =~ /^wwn-0x([0-9a-f]+)/i ) {
    my $h = lc($1);
    return length($h) == 32 ? "2$h" : $h;
  }
  if ( $entry_name =~ /^wwn-([0-9a-f]+)/i ) {
    return lc($1);
  }
  if ( $entry_name =~ /^scsi-3([0-9a-f]+)/i ) {
    return lc($1);
  }
  return '';
}

# Resolve a by-id symlink (or block node) to absolute block path; extract multipath WWID from link name.
sub nimble_resolve_by_id_entry {
  my ( $full, $entry_name ) = @_;
  return ( '', '' ) unless defined $full && -e $full;
  my $abs;
  if ( -l $full ) {
    my $t = readlink($full);
    return ( '', '' ) unless defined $t;
    $abs = abs_path( dirname($full) . '/' . $t );
  }
  elsif ( -b $full ) {
    $abs = $full;
  }
  else {
    return ( '', '' );
  }
  return ( '', '' ) unless $abs && -b $abs;
  my $safe = nimble_untaint_dev_path($abs);
  return ( '', '' ) unless length $safe;
  my $wwid = nimble_multipath_wwid_from_by_id_basename($entry_name);
  $wwid = nimble_untaint_multipath_wwid($wwid) if length $wwid;
  return ( $safe, $wwid );
}

# Find block device path by Nimble API serial_number.
#
# Pure Storage plugin does not read sysfs serial: it builds /dev/disk/by-id/wwn-0x... from API data and
# waits for -e. Nimble exposes the volume serial as the NAA/WWN body; by-id names contain that hex string,
# but multipath dm devices often have no /sys/block/dm-*/device/serial — so scanning sysfs only fails.
#
# Order: (1) deterministic by-id paths like Pure; (2) any by-id name containing the serial; (3) sysfs scan.
sub get_device_path_by_serial {
  my ( $serial ) = @_;
  die 'Error :: Volume serial is missing' unless length( $serial );
  my $sn = nimble_serial_normalize($serial);
  return ( '', '' ) unless length($sn);

  my $by_id = '/dev/disk/by-id';
  if ( -d $by_id && $sn =~ /^[0-9a-f]{8,}$/ ) {
    for my $name ( "wwn-0x$sn", "wwn-$sn", "scsi-3$sn" ) {
      my $full = "$by_id/$name";
      next unless -e $full;
      my ( $dev, $ww ) = nimble_resolve_by_id_entry( $full, $name );
      return ( $dev, $ww ) if length($dev) && -b $dev;
    }
  }

  if ( -d $by_id && length($sn) >= 8 ) {
    opendir( my $dh, $by_id ) or goto SYSFS_SCAN;
    my @hit = grep {
      $_ !~ /^\.\.?$/ && $_ !~ /-part\d+\z/ && index( lc($_), $sn ) >= 0;
    } readdir($dh);
    closedir($dh);
    @hit = sort {
      my $ma = ( lc($a) =~ /^dm-uuid-mpath-/ );
      my $mb = ( lc($b) =~ /^dm-uuid-mpath-/ );
      ( $mb <=> $ma )
        || ( ( lc($b) =~ /^wwn-0x/ ) <=> ( lc($a) =~ /^wwn-0x/ ) )
        || ( length($a) <=> length($b) );
    } @hit;
    for my $e (@hit) {
      my $full = "$by_id/$e";
      my ( $dev, $ww ) = nimble_resolve_by_id_entry( $full, $e );
      return ( $dev, $ww ) if length($dev) && -b $dev;
    }
  }

SYSFS_SCAN:
  opendir( my $dh2, $by_id ) or return ( '', '' );
  my $best_path = '';
  my $wwid      = '';
  while ( my $e = readdir( $dh2 ) ) {
    next if $e =~ /^\.\.?$/;
    my $full = "$by_id/$e";
    next unless -l $full;
    my $target = readlink($full);
    next unless defined $target;
    my $abs = abs_path( dirname($full) . '/' . $target );
    next unless $abs && -b $abs;
    my $blk      = basename($abs);
    my $ser_path = "/sys/block/$blk/device/serial";

    if ( -f $ser_path ) {
      my $dev_serial = file_read_firstline( $ser_path );
      if ( defined $dev_serial && $dev_serial =~ /^\s*(.+?)\s*$/ ) {
        $dev_serial = $1;
        if ( nimble_serial_matches( $serial, $dev_serial ) ) {
          my $safe_abs = nimble_untaint_dev_path($abs);
          $best_path = $safe_abs if length($safe_abs) && !length($best_path);
          my $ww_try = nimble_multipath_wwid_from_by_id_basename($e);
          $wwid = nimble_untaint_multipath_wwid($ww_try) if length($ww_try) && !length($wwid);
        }
      }
    }
  }
  closedir( $dh2 );
  return ( $best_path, $wwid );
}

sub get_device_size {
  my ( $device ) = @_;
  return 0 unless length( $device );
  my $path = '/sys/block/' . basename( $device ) . '/size';
  my $size = file_read_firstline( $path );
  return 0 unless defined $size && $size =~ /^\d+$/;
  return $size << 9;
}

sub device_op {
  my ( $device_path, $op, $value ) = @_;
  open( my $fh, '>', $device_path . '/' . $op ) or die "Error :: Could not open $device_path/$op: $!\n";
  print $fh $value;
  close( $fh );
}

sub scsi_scan_new {
  my ( $protocol ) = @_;
  my $path = '/sys/class/' . $protocol . '_host';
  opendir( my $dh, $path ) or die "Cannot open directory: $!";
  my @hosts = grep { !/^\.\.?$/ } readdir( $dh );
  closedir( $dh );
  my $count = 0;
  foreach my $host ( @hosts ) {
    next unless $host =~ /^(\w+)$/;
    my $hp = '/sys/class/scsi_host/' . $1;
    if ( -d $hp ) {
      device_op( $hp, 'scan', '- - -' );
      ++$count;
    }
  }
  die "Error :: No hosts to scan.\n" unless $count > 0;
}

# multipath may register Nimble LUNs as 2<32-hex> while wwn-0x uses the 32-hex NAA body only.
sub nimble_multipath_wwid_try_list {
  my ($w) = @_;
  $w = nimble_untaint_multipath_wwid($w);
  return () unless length $w;
  my @try = ($w);
  unshift @try, '2' . $w if $w =~ /^[0-9a-f]{32}$/i;
  return @try;
}

sub multipath_check {
  my ( $wwid ) = @_;
  return 0 unless length( $wwid );
  my $mp = get_command_path('multipath');
  for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
    my $out = `$mp -l $w 2>/dev/null`;
    return 1 if $out ne '';
  }
  return 0;
}

sub nimble_multipath_active_wwid {
  my ($wwid) = @_;
  my $mp = get_command_path('multipath');
  for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
    my $out = `$mp -l $w 2>/dev/null`;
    return $w if $out ne '';
  }
  return '';
}

# Same as PureStoragePlugin: remove LVM/partition DM stacks above a multipath map before array-side delete.
sub cleanup_lvm_on_device {
  my ($wwid) = @_;
  return 0 if !length($wwid);
  my $qww = quotemeta($wwid);
  my @dm_devices;
  eval {
    run_command(
      [ get_command_path('dmsetup'), 'ls' ],
      outfunc => sub {
        my $line = shift;
        if ( $line =~ /^(\S+)\s+\(/ ) {
          push @dm_devices, $1;
        }
      }
    );
  };
  return 0 if $@;
  my @lvm_to_remove;
  for my $dm (@dm_devices) {
    next if $dm =~ /^${qww}(-part\d+)?$/;
    my $deps = '';
    eval {
      run_command(
        [ get_command_path('dmsetup'), 'deps', '-o', 'devname', $dm ],
        outfunc => sub { $deps .= shift; },
        errfunc => sub { }
      );
    };
    push @lvm_to_remove, $dm if $deps =~ /$qww/;
  }
  my $cleaned = 0;
  for my $lvm ( reverse sort @lvm_to_remove ) {
    my $removed = 0;
    eval { run_command( [ get_command_path('dmsetup'), 'remove', $lvm ], errfunc => sub { } ); $removed = 1; };
    if ( !$removed ) {
      eval { run_command( [ get_command_path('dmsetup'), 'remove', '--force', $lvm ], errfunc => sub { } ); $removed = 1; };
    }
    $cleaned++ if $removed;
    warn "Warning :: Failed to remove LVM device $lvm\n" unless $removed;
  }
  return $cleaned;
}

sub cleanup_partitions_on_device {
  my ($wwid) = @_;
  return 0 if !length($wwid);
  my $qww = quotemeta($wwid);
  my $cleaned = 0;
  my $dm_path = '/dev/mapper/' . $wwid;
  eval { run_command( [ get_command_path('kpartx'), '-d', $dm_path ], errfunc => sub { } ); $cleaned++; };
  opendir( my $dh, '/dev/mapper' ) or return $cleaned;
  my @partitions = grep { /^${qww}-part\d+$/ } readdir($dh);
  closedir($dh);
  for my $part ( reverse sort @partitions ) {
    eval { run_command( [ get_command_path('dmsetup'), 'remove', '--force', $part ], errfunc => sub { } ); $cleaned++; };
    warn "Warning :: Failed to remove partition $part\n" if $@;
  }
  return $cleaned;
}

sub wait_for {
  my ( $success, $message, $timeout, $delay ) = @_;
  $timeout //= 5;
  $delay   //= 0.1;
  my $time = 0;
  while ( $time < $timeout ) {
    return 1 if &$success();
    select( undef, undef, undef, $delay );
    $time += $delay;
  }
  die "Error :: Timeout while waiting for $message\n";
}

### Token cache (similar to Pure)
sub get_token_cache_path {
  my ( $storeid ) = @_;
  my $cache_dir = '/etc/pve/priv/nimble';
  if ( !-d $cache_dir ) {
    eval { File::Path::make_path( $cache_dir, { mode => 0700 } ); };
    warn "Warning :: Failed to create $cache_dir: $@\n" if $@;
    return undef unless -d $cache_dir;
  }
  return "$cache_dir/${storeid}.json";
}

sub read_token_cache {
  my ( $cache_path ) = @_;
  return undef unless defined $cache_path && -f $cache_path;
  my $token_data;
  eval {
    my $json = PVE::Tools::file_get_contents( $cache_path );
    $token_data = decode_json( $json );
  };
  if ( $@ ) { unlink $cache_path; return undef; }
  return $token_data;
}

sub write_token_cache {
  my ( $cache_path, $token_data ) = @_;
  return unless defined $cache_path;
  my $json = encode_json( $token_data );
  my $tmp  = "$cache_path.tmp.$$";
  my $fh   = IO::File->new( $tmp, 'w', 0600 ) or die "Cannot write $tmp: $!\n";
  print $fh $json . "\n";
  $fh->close();
  rename( $tmp, $cache_path ) or die "Cannot rename $tmp -> $cache_path: $!\n";
}

sub is_token_valid {
  my ( $token_data, $ttl ) = @_;
  return 0 unless defined $token_data && defined $token_data->{ session_token };
  return 0 unless defined $token_data->{ created_at };
  my $now     = time();
  my $age     = $now - $token_data->{ created_at };
  my $refresh = $ttl * ( 0.8 + 0.05 * ( rand() - 0.5 ) );
  return $age < $refresh ? 1 : 0;
}

### Nimble API
sub nimble_base_url {
  my ( $scfg ) = @_;
  my $addr = $scfg->{ address } or die "Error :: address not set\n";
  $addr =~ s/^https?:\/\///;
  $addr =~ s/:\d+$//;
  my $port = $scfg->{ port } // $default_port;
  return "https://${addr}:${port}";
}

sub nimble_api_call {
  my ( $scfg, $method, $path, $body, $storeid, $is_retry ) = @_;
  $is_retry //= 0;
  my $base       = nimble_base_url( $scfg );
  my $url        = $base . '/' . $NIMBLE_API_VERSION . '/' . $path;
  my $cache_path = defined $storeid ? get_token_cache_path( $storeid ) : undef;
  my $ttl        = $scfg->{ token_ttl } // 3600;

  my $auth = $scfg->{ _auth_token };
  if ( !$auth && $cache_path ) {
    my $cached = read_token_cache( $cache_path );
    if ( $cached && is_token_valid( $cached, $ttl ) ) {
      $auth = $cached->{ session_token };
      $scfg->{ _auth_token } = $auth;
    }
  }
  if ( !$auth ) {
    my $login_url = $base . '/' . $NIMBLE_API_VERSION . '/tokens';
    my $ua        = LWP::UserAgent->new( timeout => 15 );
    $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 ) unless $scfg->{ check_ssl };
    my $req = HTTP::Request->new( 'POST', $login_url );
    $req->header( 'Content-Type' => 'application/json' );
    # HPE Perl sample: request body is { "data": { "username", "password" } }; response has session_token under "data"
    my ( $api_user, $api_pass ) = nimble_api_credentials( $scfg, $storeid );
    $req->content( encode_json( { data => { username => $api_user, password => $api_pass } } ) );
    my $res = $ua->request( $req );
    die "Error :: Nimble login failed: " . $res->status_line . "\n" . ( $res->decoded_content // '' ) . "\n" unless $res->is_success;
    my $data = decode_json( $res->decoded_content );
    $auth = ( $data->{ data } && $data->{ data }->{ session_token } ) ? $data->{ data }->{ session_token } : $data->{ session_token };
    $auth or die "Error :: No session_token in response\n";
    $scfg->{ _auth_token } = $auth;
    my $token_data = { session_token => $auth, created_at => time(), ttl => $ttl };
    write_token_cache( $cache_path, $token_data ) if $cache_path;
  }

  my $ua = LWP::UserAgent->new( timeout => 30 );
  $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 ) unless $scfg->{ check_ssl };
  my $req = HTTP::Request->new( $method, $url );
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'X-Auth-Token' => $auth );
  # HPE API uses "data" wrapper for request body (see Perl code sample)
  $req->content( encode_json( { data => $body } ) ) if defined $body && ref $body eq 'HASH' && %$body;
  my $res     = $ua->request( $req );
  my $content = $res->decoded_content;

  if ( !$res->is_success ) {
    if ( !$is_retry && $res->code == 401 && $cache_path ) {
      unlink $cache_path;
      delete $scfg->{ _auth_token };
      return nimble_api_call( $scfg, $method, $path, $body, $storeid, 1 );
    }
    die "Error :: Nimble API $method $path: " . $res->status_line . "\n" . ( $content // '' ) . "\n";
  }
  return length( $content ) ? decode_json( $content ) : {};
}

# Normalize API list response: array, { items => [] }, or Nimble paged { data => [ ... ], total_count => ... }.
sub nimble_data_as_list {
  my ( $raw ) = @_;
  return [] unless defined $raw;
  return $raw if ref($raw) eq 'ARRAY';
  if ( ref($raw) eq 'HASH' ) {
    if ( defined $raw->{ items } && ref( $raw->{ items } ) eq 'ARRAY' ) {
      return $raw->{ items };
    }
    if ( defined $raw->{ data } && ref( $raw->{ data } ) eq 'ARRAY' ) {
      return $raw->{ data };
    }
    return [ $raw ] if defined $raw->{ id };
  }
  return [];
}

# GET subnets often returns summary rows ({ id, name } only). Full discovery_ip / type need GET subnets/:id.
sub nimble_fetch_subnet_by_id {
  my ( $scfg, $storeid, $subnet_id ) = @_;
  return undef if !defined $subnet_id || $subnet_id eq '';
  my $r = nimble_api_call( $scfg, 'GET', "subnets/$subnet_id", undef, $storeid );
  my $d = $r->{ data };
  return ref( $d ) eq 'HASH' ? $d : undef;
}

sub nimble_hydrate_subnet_summaries {
  my ( $scfg, $storeid, $list ) = @_;
  return unless ref( $list ) eq 'ARRAY';
  for my $sub ( @$list ) {
    next unless ref( $sub ) eq 'HASH';
    my $id = $sub->{ id };
    next if !$id;
    my $dip = $sub->{ discovery_ip };
    next if defined $dip && $dip ne '';
    my $full = nimble_fetch_subnet_by_id( $scfg, $storeid, $id );
    next unless $full && ref( $full ) eq 'HASH';
    %$sub = ( %$sub, %$full );
  }
}

# List GET network_interfaces is often summary-only; ip_list / nic_type need GET network_interfaces/:id.
sub nimble_fetch_network_interface_by_id {
  my ( $scfg, $storeid, $if_id ) = @_;
  return undef if !defined $if_id || $if_id eq '';
  my $r = nimble_api_call( $scfg, 'GET', "network_interfaces/$if_id", undef, $storeid );
  my $d = $r->{ data };
  return ref( $d ) eq 'HASH' ? $d : undef;
}

sub nimble_hydrate_network_interface_summaries {
  my ( $scfg, $storeid, $list ) = @_;
  return unless ref( $list ) eq 'ARRAY';
  for my $ni ( @$list ) {
    next unless ref( $ni ) eq 'HASH';
    my $id = $ni->{ id };
    next if !$id;
    my $ipl = $ni->{ ip_list };
    next if ref( $ipl ) eq 'ARRAY' && @$ipl;
    my $full = nimble_fetch_network_interface_by_id( $scfg, $storeid, $id );
    next unless $full && ref( $full ) eq 'HASH';
    %$ni = ( %$ni, %$full );
  }
}

sub nimble_parse_manual_discovery_ips {
  my ($scfg) = @_;
  my $s = $scfg->{ iscsi_discovery_ips };
  return () if !defined $s || $s eq '';
  my @out;
  my %seen;
  for my $chunk ( split /,/, $s ) {
    $chunk =~ s/^\s+|\s+$//g;
    next if $chunk eq '';
    next if length($chunk) > 253;
    push @out, $chunk if !$seen{$chunk}++;
  }
  return @out;
}

# When subnets API yields nothing, reuse host IPs from active iSCSI sessions (same portals you already use for Nimble).
# Mirrors the Pure plugin model: the host is expected to already have array connectivity; Pure achieves LUN visibility via API "connections" instead.
sub get_iscsi_discovery_ips_from_running_sessions {
  my @ips;
  my %seen;
  my $iscsiadm = '/usr/sbin/iscsiadm';
  $iscsiadm = '/sbin/iscsiadm' if !-x $iscsiadm;
  return () unless -x $iscsiadm;
  my $out = `"$iscsiadm" -m session 2>/dev/null` // '';
  while ( $out =~ /^\s*tcp:\s*\[\d+\]\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d+)/gm ) {
    my $host = $1;
    push @ips, $host if !$seen{$host}++;
  }
  return @ips;
}

### Discovery IPs: GET subnets (unwrap items), then optional iscsi_discovery_ips from storage config.
sub get_nimble_iscsi_discovery_ips {
  my ( $scfg, $storeid ) = @_;
  my @session_first = get_iscsi_discovery_ips_from_running_sessions();
  my @ips;
  eval {
    my $res  = nimble_api_call( $scfg, 'GET', 'subnets', undef, $storeid );
    my $list = nimble_data_as_list( $res->{ data } );
    if (@$list) {
      nimble_hydrate_subnet_summaries( $scfg, $storeid, $list );
      my %seen;
      my $collect = sub {
        my ( $strict ) = @_;
        my @out;
        for my $sub ( @$list ) {
          next unless ref($sub) eq 'HASH';
          if ($strict) {
            my $type = $sub->{ type } // '';
            next unless $type =~ /data/i;
          }
          my $ip = $sub->{ discovery_ip };
          next unless defined $ip && $ip =~ m/^\S+$/ && length($ip) <= 253 && !$seen{$ip}++;
          push @out, $ip;
        }
        return @out;
      };
      @ips = $collect->(1);
      @ips = $collect->(0) if !@ips;
    }
    else {
      @ips = ();
    }
  };
  if ( $@ ) {
    chomp( my $api_err = $@ );
    warn "Warning :: Could not get iSCSI discovery IPs from Nimble subnets API: $api_err\n";
    @ips = ();
  }
  my %seen_ip = map { $_ => 1 } @ips;
  if ( !@ips ) {
    eval {
      my $r2   = nimble_api_call( $scfg, 'GET', 'network_interfaces', undef, $storeid );
      my $nifs = nimble_data_as_list( $r2->{ data } );
      nimble_hydrate_network_interface_summaries( $scfg, $storeid, $nifs );
      my $gather_nif_ips = sub {
        my ( $strict_nic_type ) = @_;
        my @found;
        my %seen_local;
        for my $ni ( @$nifs ) {
          next unless ref($ni) eq 'HASH';
          my $nt = $ni->{ nic_type } // '';
          if ($strict_nic_type) {
            next unless $nt =~ /data|iscsi|discovery/i;
          }
          my $ipl = $ni->{ ip_list };
          next unless ref($ipl) eq 'ARRAY';
          for my $e ( @$ipl ) {
            my $s = ref($e) eq 'HASH' ? ( $e->{ ip } // $e->{ label } // '' ) : "$e";
            $s =~ s/\/\d+\z//;
            next unless $s =~ /^(\d{1,3}(?:\.\d{1,3}){3})$/;
            push @found, $1 if !$seen_local{$1}++;
          }
        }
        return @found;
      };
      my @nif_ips = $gather_nif_ips->(1);
      @nif_ips = $gather_nif_ips->(0) if !@nif_ips;
      for my $x (@nif_ips) {
        push @ips, $x if !$seen_ip{$x}++;
      }
    };
    if ( $@ && $DEBUG >= 1 ) {
      chomp( my $e = $@ );
      print "Debug :: network_interfaces fallback for discovery IPs: $e\n";
    }
  }
  for my $m ( nimble_parse_manual_discovery_ips($scfg) ) {
    push @ips, $m if !$seen_ip{$m}++;
  }
  my $from_config = @ips;
  my %seen_ord;
  my @merged;
  for my $p ( @session_first, @ips ) {
    next unless defined $p && $p =~ m/^\S+$/ && length($p) <= 253;
    push @merged, $p if !$seen_ord{$p}++;
  }
  if ( !$from_config && @session_first ) {
    print "Info :: Using iSCSI portal IP(s) from existing sessions (subnets API returned none): @merged\n";
  }
  return @merged;
}

sub nimble_iscsi_portal {
  my ($ip) = @_;
  return $ip if $ip =~ /:\d+$/;
  return "$ip:3260";
}

sub nimble_iscsiadm_path {
  my $iscsiadm = '/usr/sbin/iscsiadm';
  return -x $iscsiadm ? $iscsiadm : '/sbin/iscsiadm';
}

# True if an active session lists this target IQN (authoritative after login attempts).
sub nimble_iscsi_target_in_sessions {
  my ($target_iqn) = @_;
  return 0 if !length($target_iqn);
  my $iscsiadm = nimble_iscsiadm_path();
  return 0 unless -x $iscsiadm;
  my $out = `"$iscsiadm" -m session 2>/dev/null` // '';
  return index( $out, $target_iqn ) >= 0;
}

# One sendtargets pass per host (quiet). Caller then runs targeted --login; do not mix with global `node --login` on map.
sub iscsi_sendtargets_on_ips {
  my ($ips_ref) = @_;
  return unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  for my $ip ( @$ips_ref ) {
    next unless defined $ip && $ip =~ m/^\S+$/ && length($ip) <= 253;
    my $disc_ip = $ip;
    eval {
      run_command(
        [ $iscsiadm, '-m', 'discovery', '-t', 'sendtargets', '-p', $disc_ip ],
        timeout => 20,
        quiet   => 1
      );
    };
    if ( $@ && $DEBUG >= 1 ) {
      chomp( my $e = $@ );
      print "Debug :: sendtargets -p $disc_ip: $e\n";
    }
  }
}

# Login to target on all node records (open-iscsi), when portals are unknown but discovery already ran elsewhere.
sub nimble_iscsi_login_target_on_all_recorded_portals {
  my ($target_iqn) = @_;
  return unless length($target_iqn) && $target_iqn =~ m/^iqn\./i;
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  eval {
    run_command( [ $iscsiadm, '-m', 'node', '-T', $target_iqn, '--login' ], timeout => 90, quiet => 1 );
  };
}

# Same as PVE Datacenter → Add → iSCSI: "Enabled" (persist login across reboots) for this target+portal.
sub nimble_iscsi_node_set_startup_automatic {
  my ( $target_iqn, $portal ) = @_;
  return unless length( $target_iqn ) && length( $portal );
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  eval {
    run_command(
      [
        $iscsiadm, '-m', 'node', '-T', $target_iqn, '-p', $portal,
        '--op', 'update', '-n', 'node.startup', '-v', 'automatic',
      ],
      timeout => 10,
      quiet   => 1
    );
  };
}

# After iscsi_sendtargets_on_ips: login this volume IQN on each portal (no per-IP rediscovery; no global node --login).
# Mirrors manual PVE iSCSI: portal + per-volume Nimble IQN + "Use LUNs directly" (Nimble exposes LUN 0 on that IQN).
sub nimble_iscsi_login_target_on_portals {
  my ( $storeid, $target_iqn, $ips_ref ) = @_;
  return unless length( $target_iqn ) && $target_iqn =~ m/^iqn\./i;
  return unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  for my $ip ( @$ips_ref ) {
    next unless defined $ip && $ip =~ m/^\S+$/;
    my $portal = nimble_iscsi_portal($ip);
    eval {
      run_command(
        [ $iscsiadm, '-m', 'node', '-T', $target_iqn, '-p', $portal, '--login' ],
        timeout => 45,
        quiet   => 1
      );
    };
    if ( $@ && $DEBUG >= 1 ) {
      chomp( my $e = $@ );
      print "Debug :: iscsi login $target_iqn @ $portal: $e\n";
    }
    nimble_iscsi_node_set_startup_automatic( $target_iqn, $portal );
  }
  if ( !nimble_iscsi_target_in_sessions($target_iqn) ) {
    warn "Warning :: No active iSCSI session for volume target \"$target_iqn\" after portal logins; "
      . "check ACL, paths, and discovery_ip / iscsi_discovery_ips.\n";
  }
}

### Storage activate only: sendtargets (quiet) + automatic startup + global login (can exit 15 if some portals already logged in — harmless).
sub run_iscsi_discovery_and_login {
  my ( $storeid, $scfg, $ips_ref ) = @_;
  return unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  if ( !-x $iscsiadm ) {
    warn "Warning :: iscsiadm not found or not executable; skipping auto iSCSI discovery for storage \"$storeid\".\n";
    return;
  }
  iscsi_sendtargets_on_ips($ips_ref);
  eval { run_command( [ $iscsiadm, '-m', 'node', '--op', 'update', '-n', 'node.startup', '-v', 'automatic' ], timeout => 10, quiet => 1 ); };
  if ( $@ && $DEBUG >= 1 ) {
    chomp( my $e = $@ );
    print "Debug :: node startup update: $e\n";
  }
  eval { run_command( [ $iscsiadm, '-m', 'node', '--login' ], timeout => 120, quiet => 1 ); };
  if ( $@ && $DEBUG >= 1 ) {
    chomp( my $e = $@ );
    print "Debug :: global node --login (often exit 15 if sessions exist): $e\n";
  }
}

sub nimble_get_local_iscsi_iqn {
  my $path = '/etc/iscsi/initiatorname.iscsi';
  return undef unless -r $path;
  # Do not use only the first line: open-iscsi ships comment lines (## / #) before InitiatorName=.
  my $content = eval { file_get_contents($path) };
  return undef if !defined $content || $content eq '';
  for my $line ( split /\r?\n/, $content ) {
    next if $line =~ m/^\s*#/;
    next if $line =~ m/^\s*$/;
    next unless $line =~ m/^\s*InitiatorName\s*=\s*(\S+)/;
    my $iqn = $1;
    $iqn =~ s/^["']|["']$//g;
    return $iqn if length($iqn) && $iqn =~ m/^iqn\./;
  }
  return undef;
}

# True if Nimble chapuser_id on an initiator is set (plugin avoids CHAP groups for auto selection).
sub nimble_chapuser_id_truthy {
  my ($v) = @_;
  return 0 if !defined $v || $v eq '' || $v eq '0';
  return 1;
}

# True if inline iscsi_initiators on a group object includes CHAP.
sub nimble_initiator_group_inline_has_chap {
  my ($g) = @_;
  return 0 unless ref($g) eq 'HASH';
  my $inits = $g->{ iscsi_initiators };
  return 0 unless ref($inits) eq 'ARRAY';
  for my $i ( @$inits ) {
    next unless ref($i) eq 'HASH';
    return 1 if nimble_chapuser_id_truthy( $i->{ chapuser_id } );
  }
  return 0;
}

sub nimble_fetch_initiator_group {
  my ( $scfg, $id, $storeid ) = @_;
  return undef if !defined $id || $id eq '';
  my $r = nimble_api_call( $scfg, 'GET', "initiator_groups/$id", undef, $storeid );
  my $g = $r->{ data } || $r;
  return ref($g) eq 'HASH' ? $g : undef;
}

# Build per-group flags from GET initiators (authoritative when present): any CHAP in group, IQN membership.
sub nimble_initiator_group_flags_from_initiators_list {
  my ( $init_rows, $host_iqn_lc ) = @_;
  my ( %chap, %match );
  for my $row ( @$init_rows ) {
    next unless ref($row) eq 'HASH';
    next unless lc( $row->{ access_protocol } // '' ) eq 'iscsi';
    my $gid = $row->{ initiator_group_id };
    next unless defined $gid;
    my $gk = "$gid";
    $chap{ $gk } = 1 if nimble_chapuser_id_truthy( $row->{ chapuser_id } );
    my $iq = $row->{ iqn };
    if ( defined $iq && $iq ne '*' && $iq ne '' && lc($iq) eq $host_iqn_lc ) {
      $match{ $gk } = 1;
    }
  }
  return ( \%chap, \%match );
}

# When initiator_group is unset: prefer an existing iSCSI group that already lists this host's IQN
# (first in API order). Skip groups that use CHAP on any initiator. If none match, create pve-<nodename>.
sub nimble_find_initiator_group_id_for_local_iqn {
  my ( $scfg, $host_iqn, $storeid ) = @_;
  my $host_lc = lc($host_iqn);
  my $r         = nimble_api_call( $scfg, 'GET', 'initiator_groups', undef, $storeid );
  my $groups    = nimble_data_as_list( $r->{ data } );
  my $used_api  = 0;
  my $chap_map  = {};
  my $match_map = {};
  eval {
    my $ir    = nimble_api_call( $scfg, 'GET', 'initiators', undef, $storeid );
    my $ilist = nimble_data_as_list( $ir->{ data } );
    ( $chap_map, $match_map ) = nimble_initiator_group_flags_from_initiators_list( $ilist, $host_lc );
    $used_api = 1;
  };
  if ($used_api) {
    for my $g ( @$groups ) {
      next unless ref($g) eq 'HASH';
      next unless lc( $g->{ access_protocol } // '' ) eq 'iscsi';
      my $id = $g->{ id };
      next unless defined $id;
      my $gk = "$id";
      next if $chap_map->{ $gk };
      if ( $match_map->{ $gk } ) {
        print "Info :: Using existing Nimble initiator group \"$g->{name}\" (this host IQN is a member; CHAP groups skipped).\n";
        return $id;
      }
    }
  }
  # Inline / detail pass: covers arrays without a useful initiators list, or IQN visible only on the group object.
  for my $g ( @$groups ) {
    next unless ref($g) eq 'HASH';
    next unless lc( $g->{ access_protocol } // '' ) eq 'iscsi';
    my $det = $g;
    my $in  = $g->{ iscsi_initiators };
    if ( ref($in) ne 'ARRAY' || !@$in ) {
      $det = nimble_fetch_initiator_group( $scfg, $g->{ id }, $storeid ) // $g;
    }
    next if nimble_initiator_group_inline_has_chap($det);
    $in = $det->{ iscsi_initiators };
    next unless ref($in) eq 'ARRAY';
    for my $i ( @$in ) {
      next unless ref($i) eq 'HASH';
      my $iq = $i->{ iqn };
      next if !defined $iq || $iq eq '*' || $iq eq '';
      if ( lc($iq) eq $host_lc ) {
        print "Info :: Using existing Nimble initiator group \"$det->{name}\" (this host IQN is a member; CHAP groups skipped).\n";
        return $det->{ id };
      }
    }
  }
  return undef;
}

sub nimble_get_initiator_group_id {
  my ( $scfg, $name, $storeid ) = @_;
  my $enc  = uri_escape( $name );
  my $r    = nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  for my $g ( @$list ) {
    return $g->{ id } if $g->{ name } eq $name;
  }
  die "Error :: Initiator group \"$name\" not found on Nimble array.\n";
}

# Resolve initiator group ID without POST (for disconnect / deactivate). Returns undef if none exists yet.
sub nimble_resolve_initiator_group_id_no_create {
  my ( $scfg, $storeid ) = @_;
  my $ig_name = $scfg->{ initiator_group };
  if ( defined $ig_name && $ig_name ne '' ) {
    my $id = eval { nimble_get_initiator_group_id( $scfg, $ig_name, $storeid ) };
    return $id if defined $id && $id ne '' && !$@;
    return undef;
  }
  my $iqn = nimble_get_local_iscsi_iqn();
  return undef unless $iqn;
  my $reuse = nimble_find_initiator_group_id_for_local_iqn( $scfg, $iqn, $storeid );
  return $reuse if $reuse;
  my $nodename = PVE::INotify::nodename();
  my $want = "pve-$nodename";
  my $enc  = uri_escape($want);
  my $r    = eval { nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc", undef, $storeid ) };
  return undef unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $g ( @$list ) {
    return $g->{ id } if ref($g) eq 'HASH' && ( $g->{ name } // '' ) eq $want;
  }
  return undef;
}

# Resolve initiator group ID: use config name if set, else reuse existing group containing this IQN, else pve-<nodename> (create if missing).
sub nimble_ensure_initiator_group_id {
  my ( $scfg, $storeid ) = @_;
  my $ig_name = $scfg->{ initiator_group };
  if ( defined $ig_name && $ig_name ne '' ) {
    return nimble_get_initiator_group_id( $scfg, $ig_name, $storeid );
  }
  my $iqn = nimble_get_local_iscsi_iqn();
  die "Error :: initiator_group not set and could not read a valid IQN from /etc/iscsi/initiatorname.iscsi (install open-iscsi; need an uncommented line InitiatorName=iqn...., or set initiator_group to an existing Nimble group).\n"
    unless $iqn;
  my $existing = nimble_resolve_initiator_group_id_no_create( $scfg, $storeid );
  return $existing if $existing;
  my $nodename = PVE::INotify::nodename();
  $ig_name = "pve-$nodename";
  my $enc  = uri_escape( $ig_name );
  my $r    = nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );

  for my $g ( @$list ) {
    return $g->{ id } if $g->{ name } eq $ig_name;
  }
  my $body = {
    name             => $ig_name,
    access_protocol  => 'iscsi',
    iscsi_initiators => [ { label => $nodename, iqn => $iqn } ],
  };
  $r = nimble_api_call( $scfg, 'POST', 'initiator_groups', $body, $storeid );
  my $g  = $r->{ data } || $r;
  my $id = $g->{ id } or die "Error :: Failed to create initiator group \"$ig_name\".\n";
  print "Info :: Created initiator group \"$ig_name\" with this host's IQN.\n";
  return $id;
}

# True if Nimble reports this ACL already exists (HTTP 409 / SM_eexist, etc.).
sub nimble_acr_error_is_duplicate {
  my ($err) = @_;
  return 0 if !defined $err;
  my $e = "$err";
  return $e =~ /SM_eexist|SM_http_conflict|Object exists|\b409\b|already exists|due to a conflict/i;
}

# POST access_control_records; treat "already exists" as success (idempotent).
# Returns 1 if a new record was created, 0 if the array reported duplicate / conflict.
sub nimble_post_access_control_record_idempotent {
  my ( $scfg, $vol_id, $ig_id, $storeid ) = @_;
  eval {
    nimble_api_call( $scfg, 'POST', 'access_control_records', { vol_id => $vol_id, initiator_group_id => $ig_id }, $storeid );
  };
  if ( my $err = $@ ) {
    return 0 if nimble_acr_error_is_duplicate($err);
    die $err;
  }
  return 1;
}

# Check if volume already has an access_control_record for the given initiator group.
sub nimble_volume_has_acl_for_ig {
  my ( $scfg, $vol_id, $ig_id, $storeid ) = @_;
  return 0 if !defined $vol_id || !defined $ig_id;
  my $r    = nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH';
    my $a_vid = $acr->{ vol_id };
    my $a_ig  = $acr->{ initiator_group_id };
    next unless defined $a_vid && defined $a_ig;
    return 1 if "$a_vid" eq "$vol_id" && "$a_ig" eq "$ig_id";
  }
  return 0;
}

# Parallel to PureStoragePlugin::purestorage_volume_connection: $mode true = connect (POST), false = disconnect (DELETE).
# Nimble maps host access via access_control_records for this storage's initiator group (same ig as activate).
sub nimble_volume_connection {
  my ( $class, $storeid, $scfg, $volname, $mode ) = @_;
  if ($mode) {
    return $class->nimble_ensure_volume_acl_for_current_node( $scfg, $volname, $storeid );
  }
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return 1 unless $vol_id;
  my $ig_id = nimble_resolve_initiator_group_id_no_create( $scfg, $storeid );
  return 1 unless defined $ig_id && $ig_id ne '';
  my $r = eval { nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid ) };
  return 1 unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH' && defined $acr->{ id };
    next unless ( $acr->{ vol_id } // '' ) eq $vol_id && ( $acr->{ initiator_group_id } // '' ) eq $ig_id;
    eval { nimble_api_call( $scfg, 'DELETE', "access_control_records/" . $acr->{ id }, undef, $storeid ); };
  }
  return 1;
}

# Ensure Nimble has an access_control_record linking this volume to the storage initiator group
# (configured initiator_group name, or auto pve-<nodename>). Without that ACL, the array will
# not present the LUN and map_volume times out waiting for the device.
sub nimble_ensure_volume_acl_for_current_node {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $vol_id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return 1 unless $vol_id;
  my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
  return 1 if nimble_volume_has_acl_for_ig( $scfg, $vol_id, $ig_id, $storeid );
  print "Info :: Volume \"$volname\" granted Nimble access (initiator group ACL).\n"
    if nimble_post_access_control_record_idempotent( $scfg, $vol_id, $ig_id, $storeid );
  return 1;
}

sub nimble_get_volume_collection_id {
  my ( $scfg, $name, $storeid ) = @_;
  return undef if !defined $name || $name eq '';
  my $enc  = uri_escape( $name );
  my $r    = nimble_api_call( $scfg, 'GET', "volume_collections?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  for my $vc ( @$list ) {
    return $vc->{ id } if ref($vc) eq 'HASH' && $vc->{ name } eq $name;
  }
  return undef;
}

sub nimble_get_volume_id {
  my ( $scfg, $volname, $storeid ) = @_;
  my $name = nimble_volname( $scfg, $volname, undef );
  my $match = sub {
    my ($list) = @_;
    for my $v ( @$list ) {
      next unless ref($v) eq 'HASH' && defined $v->{ name };
      return $v if $v->{ name } eq $name;
    }
    return undef;
  };

  my $enc  = uri_escape($name);
  my $r    = nimble_api_call( $scfg, 'GET', "volumes?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  my $vol  = $match->($list);

  if ( !$vol ) {
    $r    = nimble_api_call( $scfg, 'GET', 'volumes', undef, $storeid );
    $list = nimble_data_as_list( $r->{ data } );
    $vol  = $match->($list);
  }
  return ( undef, undef ) unless $vol;

  # List/search often omit serial_number and target_name (per-volume iSCSI IQN); map_volume needs both.
  if ( defined $vol->{ id } ) {
    my $need_serial = !length( $vol->{ serial_number } // '' );
    my $need_target = !length( $vol->{ target_name } // '' );
    if ( $need_serial || $need_target ) {
      $r = nimble_api_call( $scfg, 'GET', "volumes/$vol->{ id }", undef, $storeid );
      my $full = $r->{ data } || $r;
      if ( ref($full) eq 'HASH' ) {
        $vol->{ serial_number } = $full->{ serial_number } if length( $full->{ serial_number } // '' );
        $vol->{ target_name }    = $full->{ target_name } if length( $full->{ target_name } // '' );
      }
    }
  }
  return ( $vol->{ id }, $vol );
}

sub nimble_list_volumes {
  my ( $class, $scfg, $vmid, $storeid, $vollist ) = @_;
  my $prefix = nimble_name_prefix( $scfg );
  my $r      = nimble_api_call( $scfg, 'GET', 'volumes', undef, $storeid );
  my $list   = nimble_data_as_list( $r->{ data } );
  my @volumes;
  for my $v ( @$list ) {
    my $name = $v->{ name };
    next if length( $prefix ) && index( $name, $prefix ) != 0;
    my $volname = length( $prefix ) ? substr( $name, length( $prefix ) ) : $name;
    next unless $volname =~ m/^vm-\d+-(disk-|cloudinit|state-)/;
    my ( undef, undef, $volvm ) = $class->parse_volname( $volname );
    push @volumes,
      {
        name   => $volname,
        vmid   => $volvm,
        serial => $v->{ serial_number },
        size   => ( $v->{ size } || 0 ) * 1024 * 1024,
        used   => ( $v->{ vol_usage_compressed_bytes } || $v->{ size } || 0 ) * 1024 * 1024,
        ctime  => $v->{ creation_time } || 0,
        volid  => $storeid ? "$storeid:$volname" : $volname,
        format => 'raw'
      };
  }
  # Match PVE::Storage::RBDPlugin::list_images: if vollist is passed (even []), only return those
  # volids; else filter by vmid. Empty vollist => no rows (same as RBD if ($vollist) branch).
  if ( defined($vollist) && ref($vollist) eq 'ARRAY' ) {
    my %want = map { $_ => 1 } @$vollist;
    @volumes = grep { $want{ $_->{ volid } } } @volumes;
  }
  elsif ( defined $vmid ) {
    @volumes = grep { defined $_->{ vmid } && "$_->{ vmid }" eq "$vmid" } @volumes;
  }
  return \@volumes;
}

sub nimble_get_volume_info {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return undef unless $vol;
  my $array_name = $vol->{ name };
  my $prefix     = nimble_name_prefix( $scfg );
  $array_name = substr( $array_name, length( $prefix ) ) if length( $prefix );
  return {
    name         => $array_name,
    serial       => $vol->{ serial_number },
    target_name  => $vol->{ target_name } // '',
    size         => ( $vol->{ size } || 0 ) * 1024 * 1024,
    used         => ( $vol->{ vol_usage_compressed_bytes } || $vol->{ size } || 0 ) * 1024 * 1024,
    ctime        => $vol->{ creation_time } || 0,
    volid        => $storeid ? "$storeid:$array_name" : $array_name,
    format       => 'raw'
  };
}

# Round size up to full MB (Veeam/import compatibility: odd sector counts must not truncate)
sub size_bytes_to_mb {
  my ( $size_bytes ) = @_;
  return 1 if $size_bytes < 1;
  my $size_mb = int( ( $size_bytes + 1024 * 1024 - 1 ) / ( 1024 * 1024 ) );
  return $size_mb < 1 ? 1 : $size_mb;
}

sub nimble_create_volume {
  my ( $class, $scfg, $volname, $size_bytes, $storeid ) = @_;
  my $name    = nimble_volname( $scfg, $volname, undef );
  my $size_mb = size_bytes_to_mb( $size_bytes );
  my $body = { name => $name, size => $size_mb };
  $body->{ pool_name } = $scfg->{ pool_name } if $scfg->{ pool_name };
  my $r      = nimble_api_call( $scfg, 'POST', 'volumes', $body, $storeid );
  my $vol    = $r->{ data } || $r;
  my $serial = $vol->{ serial_number } or die "Error :: No serial_number in create response\n";
  print "Info :: Volume \"$volname\" created (serial=$serial).\n";
  my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
  nimble_post_access_control_record_idempotent( $scfg, $vol->{ id }, $ig_id, $storeid );
  if ( $scfg->{ volume_collection } ) {
    my $volcoll_id = nimble_get_volume_collection_id( $scfg, $scfg->{ volume_collection }, $storeid );
    if ( $volcoll_id ) {
      nimble_api_call( $scfg, 'PUT', "volumes/$vol->{ id }", { volcoll_id => $volcoll_id }, $storeid );
      print "Info :: Volume \"$volname\" added to volume collection \"$scfg->{ volume_collection }\".\n";
    } else {
      warn "Warning :: volume_collection \"$scfg->{ volume_collection }\" not found; volume not added to any collection.\n";
    }
  }
  return 1;
}

# Nimble-specific: offline + child snapshots before DELETE (Pure destroy does not need this step).
sub nimble_delete_snapshots_for_volume_id {
  my ( $scfg, $vol_id, $storeid ) = @_;
  return unless defined $vol_id;
  my $r    = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) };
  return unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $s ( @$list ) {
    next unless ref($s) eq 'HASH' && defined $s->{ id };
    next unless ( $s->{ vol_id } // '' ) eq $vol_id;
    eval { nimble_api_call( $scfg, 'DELETE', "snapshots/" . $s->{ id }, undef, $storeid ); };
  }
}

sub nimble_delete_access_control_records_for_volume_id {
  my ( $scfg, $vol_id, $storeid ) = @_;
  return unless defined $vol_id;
  my $r    = eval { nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid ) };
  return unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH' && defined $acr->{ id };
    next unless ( $acr->{ vol_id } // '' ) eq $vol_id;
    eval { nimble_api_call( $scfg, 'DELETE', "access_control_records/" . $acr->{ id }, undef, $storeid ); };
  }
}

sub nimble_offline_volume_and_delete_snapshots {
  my ( $scfg, $vol_id, $storeid ) = @_;
  return unless defined $vol_id;
  my $d = eval { nimble_api_call( $scfg, 'GET', "volumes/$vol_id", undef, $storeid ) };
  if ( $d && ref( $d->{ data } ) eq 'HASH' && $d->{ data }->{ online } ) {
    eval {
      nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { online => JSON::XS::false }, $storeid );
    };
  }
  nimble_delete_snapshots_for_volume_id( $scfg, $vol_id, $storeid );
}

# Same order as PureStoragePlugin::purestorage_remove_volume: local DM cleanup → disconnect all hosts on
# the array → destroy. Nimble: multipath/LVM/part cleanup, DELETE every access_control_record for the
# volume, offline + snapshots, then DELETE volume.
sub nimble_remove_volume {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $vol_id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;

  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $storeid );
  my $wwid_safe = nimble_untaint_multipath_wwid($wwid);
  if ( length($wwid_safe) && -e "/dev/mapper/$wwid_safe" ) {
    cleanup_lvm_on_device($wwid_safe);
    cleanup_partitions_on_device($wwid_safe);
    if ( multipath_check($wwid) ) {
      eval { exec_command( [ get_command_path('multipath'), '-f', $wwid_safe ], -1 ); };
    }
  }

  nimble_delete_access_control_records_for_volume_id( $scfg, $vol_id, $storeid );
  nimble_offline_volume_and_delete_snapshots( $scfg, $vol_id, $storeid );

  eval { nimble_api_call( $scfg, 'DELETE', "volumes/$vol_id", undef, $storeid ); 1 }
    or do {
      my $e = $@ || '';
      if ( $e =~ /\b409\b/ || $e =~ /SM_http_conflict/ || $e =~ /SM_eperm/ ) {
        sleep(2);
        nimble_delete_access_control_records_for_volume_id( $scfg, $vol_id, $storeid );
        nimble_offline_volume_and_delete_snapshots( $scfg, $vol_id, $storeid );
        nimble_api_call( $scfg, 'DELETE', "volumes/$vol_id", undef, $storeid );
      }
      else {
        die $e;
      }
    };
  print "Info :: Volume \"$volname\" deleted.\n";
  return 1;
}

sub nimble_resize_volume {
  my ( $class, $scfg, $volname, $size_bytes, $storeid ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  my $size_mb = size_bytes_to_mb( $size_bytes );
  nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { size => $size_mb }, $storeid );
  return $size_bytes;
}

sub nimble_rename_volume {
  my ( $class, $scfg, $storeid, $source_volname, $target_volname ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $source_volname, $storeid );
  die "Error :: Volume \"$source_volname\" not found\n" unless $vol_id;
  my $new_name = nimble_volname( $scfg, $target_volname, undef );
  nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { name => $new_name }, $storeid );
  print "Info :: Volume \"$source_volname\" renamed to \"$target_volname\".\n";
  return 1;
}

sub nimble_snapshot_create {
  my ( $class, $scfg, $storeid, $volname, $snap_name ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  # Full snapshot name on array: prefix + volname + .snap-<name> (nimble_volname normalizes veeam_ → veeam-, adds snap-)
  my $snap_full_name = nimble_volname( $scfg, $volname, $snap_name );
  nimble_api_call( $scfg, 'POST', 'snapshots', { vol_id => $vol_id, name => $snap_full_name }, $storeid );
  print "Info :: Snapshot \"$snap_name\" created for volume \"$volname\".\n";
  return 1;
}

sub nimble_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap_name ) = @_;
  my $snap_full = nimble_volname( $scfg, $volname, $snap_name );
  my $enc       = uri_escape( $snap_full );
  my $r         = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
  my $list      = nimble_data_as_list( $r->{ data } );
  for my $s ( @$list ) {
    if ( $s->{ name } eq $snap_full ) {
      nimble_api_call( $scfg, 'DELETE', "snapshots/" . $s->{ id }, undef, $storeid );
      print "Info :: Snapshot \"$snap_name\" deleted.\n";
      return 1;
    }
  }
  warn "Warning :: Snapshot \"$snap_name\" not found for volume \"$volname\".\n";
  return 1;
}

sub nimble_volume_restore {
  my ( $class, $scfg, $storeid, $volname, $svolname, $snap, $overwrite ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  my $snap_full = nimble_volname( $scfg, $svolname, $snap );
  my $enc       = uri_escape( $snap_full );
  my $r         = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
  my $list      = nimble_data_as_list( $r->{ data } );
  my $snap_id;

  for my $s ( @$list ) {
    if ( $s->{ name } eq $snap_full ) { $snap_id = $s->{ id }; last; }
  }
  die "Error :: Snapshot \"$snap\" not found\n" unless $snap_id;
  # HPE REST API: POST v1/volumes/id/actions/restore with id and base_snap_id (both mandatory)
  nimble_api_call( $scfg, 'POST', "volumes/$vol_id/actions/restore", { id => $vol_id, base_snap_id => $snap_id }, $storeid );
  print "Info :: Volume \"$volname\" restored from snapshot \"$snap\".\n";
  return 1;
}

# Create a new volume from a snapshot (clone). API: POST volumes with clone=true, name, base_snap_id.
sub nimble_clone_from_snapshot {
  my ( $class, $scfg, $storeid, $new_volname, $source_volname, $snap_name ) = @_;
  my $snap_full = nimble_volname( $scfg, $source_volname, $snap_name );
  my $enc       = uri_escape( $snap_full );
  my $r         = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
  my $list      = nimble_data_as_list( $r->{ data } );
  my $snap_id;
  for my $s ( @$list ) {
    if ( $s->{ name } eq $snap_full ) { $snap_id = $s->{ id }; last; }
  }
  die "Error :: Snapshot \"$snap_name\" not found for volume \"$source_volname\".\n" unless $snap_id;
  my $name_on_array = nimble_volname( $scfg, $new_volname, undef );
  my $body = { clone => JSON::XS::true, name => $name_on_array, base_snap_id => $snap_id };
  $r = nimble_api_call( $scfg, 'POST', 'volumes', $body, $storeid );
  my $vol = $r->{ data } || $r;
  my $vol_id = $vol->{ id } or die "Error :: Clone did not return volume id.\n";
  my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
  nimble_post_access_control_record_idempotent( $scfg, $vol_id, $ig_id, $storeid );
  if ( $scfg->{ volume_collection } ) {
    my $volcoll_id = nimble_get_volume_collection_id( $scfg, $scfg->{ volume_collection }, $storeid );
    if ( $volcoll_id ) {
      nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { volcoll_id => $volcoll_id }, $storeid );
      print "Info :: Cloned volume \"$new_volname\" added to volume collection \"$scfg->{ volume_collection }\".\n";
    } else {
      warn "Warning :: volume_collection \"$scfg->{ volume_collection }\" not found; clone not added to any collection.\n";
    }
  }
  print "Info :: Cloned volume \"$new_volname\" from \"$source_volname\" snapshot \"$snap_name\".\n";
  return 1;
}

### Block device / multipath helpers (from Pure plugin pattern)
sub block_device_slaves {
  my ( $path ) = @_;
  my $device_path = abs_path( $path );
  die "Error :: Can't resolve device path for $path\n" unless $device_path =~ /^([\/a-zA-Z0-9_\-\.]+)$/;
  $device_path = $1;
  my $device_name = basename( $device_path );
  my $slaves_path = '/sys/block/' . $device_name . '/slaves';
  my @slaves;
  if ( -d $slaves_path ) {
    opendir( my $dh, $slaves_path ) or die "Cannot open directory: $!";
    @slaves = grep { !/^\.\.?$/ } readdir( $dh );
    closedir( $dh );
  }
  push @slaves, $device_name unless @slaves;
  return $device_path, @slaves;
}

sub block_device_action {
  my ( $action, @devices ) = @_;
  for my $device ( @devices ) {
    next unless $device =~ /^(sd[a-z]+)$/;
    $device = $1;
    my $flush = "/dev/$device";
    $flush = $1 if $flush =~ m{^(/dev/sd[a-z]+)$};
    my $device_path = '/sys/block/' . $device . '/device';
    if ( $action eq 'remove' ) {
      exec_command( [ 'blockdev', '--flushbufs', $flush ] );
      device_op( $device_path, 'state',  'offline' );
      device_op( $device_path, 'delete', '1' );
    } elsif ( $action eq 'rescan' ) {
      device_op( $device_path, 'rescan', '1' );
    }
  }
}

### Storage interface
sub parse_volname {
  my ( $class, $volname ) = @_;
  if ( $volname =~ m/^(vm|base)-(\d+)-(\S+)$/ ) {
    my $vtype = ( $1 eq "vm" ) ? "images" : "base";
    return ( $vtype, $3, $2, undef, undef, undef, 'raw' );
  }
  die "Error :: Invalid volume name ($volname).\n";
}

# Optional $storeid matches Pure-style paths that omit it; also checks $scfg keys used by some PVE call sites.
sub nimble_effective_storeid {
  my ( $scfg, $storeid ) = @_;
  return $storeid if defined $storeid && $storeid ne '';
  return undef unless ref($scfg) eq 'HASH';
  for my $k (qw( storage storagename storeid )) {
    my $v = $scfg->{ $k };
    return $v if defined $v && $v ne '';
  }
  return undef;
}

sub get_device_path_wwid {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my $sid = nimble_effective_storeid( $scfg, $storeid );
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $sid );
  return ( '', '' ) unless $volume && $volume->{ serial };
  return get_device_path_by_serial( $volume->{ serial } );
}

sub filesystem_path {
  my ( $class, $scfg, $volname, $snapname, $storeid ) = @_;
  die "Error :: filesystem_path: snapshot not implemented ($snapname)\n" if defined( $snapname );
  my ( $vtype, undef, $vmid ) = $class->parse_volname( $volname );
  my $sid          = nimble_effective_storeid( $scfg, $storeid );
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $sid );
  return wantarray ? ( "", "", "", "" ) : "" unless length( $path );
  $path = nimble_untaint_dev_path($path) || $path;
  return wantarray ? ( $path, $vmid, $vtype, $wwid ) : $path;
}

sub find_free_diskname {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix ) = @_;
  my $volumes   = $class->nimble_list_volumes( $scfg, $vmid, $storeid );
  my @disk_list = map { $_->{ name } } @$volumes;
  return PVE::Storage::Plugin::get_next_vm_diskname( \@disk_list, $storeid, $vmid, undef, $scfg );
}

sub alloc_image {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
  die "Error :: Unsupported format ($fmt).\n" if $fmt ne 'raw';
  if ( defined( $name ) ) {
    die "Error :: Illegal name \"$name\" - should be vm-$vmid-(disk-*|cloudinit|state-*).\n" if $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;
  } else {
    $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
  }
  $size = 1024 if $size < 1024;
  my $sizeB = $size * 1024;
  $class->nimble_create_volume( $scfg, $name, $sizeB, $storeid );
  return $name;
}

sub free_image {
  my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;
  $class->deactivate_volume( $storeid, $scfg, $volname );
  $class->nimble_remove_volume( $scfg, $volname, $storeid );
  return undef;
}

sub list_images {
  my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
  set_debug_from_config( $scfg );
  return $class->nimble_list_volumes( $scfg, $vmid, $storeid, $vollist );
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
  my ( $total, $used ) = ( 0, 0 );
  eval {
    my $r    = nimble_api_call( $scfg, 'GET', 'pools', undef, $storeid );
    my $list = nimble_data_as_list( $r->{ data } );
    for my $p ( @$list ) {
      $total += ( $p->{ capacity } || 0 );
      if ( $p->{ usage_valid } && defined $p->{ usage } ) {
        # API: usage is NsBytes (number); some versions return nested { compressed_usage, uncompressed_usage }
        my $u = $p->{ usage };
        $used += ( ref($u) eq 'HASH' )
          ? ( $u->{ compressed_usage } || $u->{ uncompressed_usage } || 0 )
          : ( 0 + $u );
      }
    }
    1;
  };
  if ( my $err = $@ ) {
    chomp($err);
    warn "Warning :: Nimble storage \"$storeid\" status (pools API): $err\n";
    # Avoid GUI "unknown" from a hard die; report inactive with minimal placeholder totals.
    return ( 1, 0, 0, 0 );
  }
  $total = 1 if $total <= 0;
  my $free = $total - $used;
  $free = 0 if $free < 0;
  return ( $total, $free, $used, 1 );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
  # PureStoragePlugin::activate_storage only returns 1; Nimble adds optional cluster-wide iSCSI discovery when configured.
  if ( $scfg->{ auto_iscsi_discovery } && $scfg->{ auto_iscsi_discovery } ne 'no' && $scfg->{ auto_iscsi_discovery } ne '0' ) {
    my $ig_ok = eval { nimble_ensure_initiator_group_id( $scfg, $storeid ); 1 };
    if ( !$ig_ok ) {
      chomp( my $err = $@ );
      warn "Warning :: Auto iSCSI discovery skipped for storage \"$storeid\": initiator group could not be ensured ($err). Install open-iscsi and set InitiatorName in /etc/iscsi/initiatorname.iscsi, or set initiator_group to an existing group.\n";
    } else {
      my @ips = get_nimble_iscsi_discovery_ips( $scfg, $storeid );
      if ( !@ips ) {
        warn "Warning :: No iSCSI discovery IPs returned by array for storage \"$storeid\"; skipping discovery. Check Nimble subnets (GET subnets + subnets/:id; type should include data for preferred portals).\n";
      } else {
        run_iscsi_discovery_and_login( $storeid, $scfg, \@ips );
      }
    }
  }
  return 1;
}

sub deactivate_storage {
  return 1;
}

sub volume_size_info {
  my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $storeid );
  die "Error :: No volume data for \"$volname\".\n" unless $volume;
  my $size = $volume->{ size };
  my $used = $volume->{ used };
  return wantarray ? ( $size, 'raw', $used, undef ) : $size;
}

sub map_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $hints ) = @_;
  # Signature aligned with PureStoragePlugin::map_volume; $hints unused (Nimble iSCSI path is fixed).
  # $storeid is required for nimble_api_credentials (priv .pw path) and token cache.
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found (cannot map).\n" unless $volume && $volume->{ serial };
  my $serial      = $volume->{ serial };
  my $target_iqn  = $volume->{ target_name } // '';
  my @dip = get_nimble_iscsi_discovery_ips( $scfg, $storeid );
  if ( !@dip ) {
    warn "Warning :: No iSCSI discovery IPs (Nimble subnets API, iscsi_discovery_ips, or active sessions) for storage \"$storeid\"; "
      . "set iscsi_discovery_ips or ensure iscsiadm sessions exist to this array.\n";
  }
  # Do not run global `iscsiadm -m node --login` here (exit 15 / noise when many targets). Sendtargets once, then per-volume IQN login only.
  iscsi_sendtargets_on_ips( \@dip ) if @dip;
  if ( length($target_iqn) ) {
    if (@dip) {
      nimble_iscsi_login_target_on_portals( $storeid, $target_iqn, \@dip );
      if ( !nimble_iscsi_target_in_sessions($target_iqn) ) {
        iscsi_sendtargets_on_ips( \@dip );
        nimble_iscsi_login_target_on_portals( $storeid, $target_iqn, \@dip );
      }
    }
    else {
      nimble_iscsi_login_target_on_all_recorded_portals($target_iqn);
      my $adm = nimble_iscsiadm_path();
      if ( -x $adm ) {
        eval {
          run_command(
            [
              $adm, '-m', 'node', '-T', $target_iqn,
              '--op', 'update', '-n', 'node.startup', '-v', 'automatic',
            ],
            timeout => 10,
            quiet   => 1
          );
        };
      }
    }
  }
  else {
    warn "Warning :: Volume \"$volname\" has no target_name (iSCSI IQN) from Nimble API.\n";
    if (@dip) {
      my $adm = nimble_iscsiadm_path();
      eval { run_command( [ $adm, '-m', 'node', '--login' ], timeout => 90, quiet => 1 ); } if -x $adm;
    }
  }
  # Like the GUI after attaching a LUN: rescan active iSCSI sessions so new LUNs appear without waiting only on sysfs scan.
  eval {
    my $adm = nimble_iscsiadm_path();
    run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 120, quiet => 1 ) if -x $adm;
  };
  eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
  scsi_scan_new( 'iscsi' );
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=30' ] ); };
  my $wait_ticks = 0;
  wait_for(
    sub {
      ++$wait_ticks;
      if ( $wait_ticks % 100 == 0 ) {
        eval { scsi_scan_new('iscsi'); };
      }
      my ( $p, $w ) = get_device_path_by_serial( $serial );
      return length($p) && -e $p;
    },
    "volume \"$volname\" to appear (API serial " . $serial . "; check iscsiadm -m session and ACL)",
    90
  );
  my ( $path, $wwid ) = get_device_path_by_serial( $serial );
  die "Error :: Volume \"$volname\" device did not appear after rescan (serial $serial).\n" unless length($path) && -b $path;
  $path = nimble_untaint_dev_path($path) || $path;
  if ( length( $wwid ) && !multipath_check( $wwid ) ) {
    for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
      eval { exec_command( [ 'multipathd', 'add', 'map', $w ], -1, timeout => 30 ); };
      last if multipath_check( $wwid );
    }
    my $mp_ready = sub { return multipath_check( $wwid ) };
    wait_for( $mp_ready, "multipath for \"$volname\"", 30 );
  }
  elsif ( !length($wwid) ) {
    eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
    ( $path, $wwid ) = get_device_path_by_serial( $serial );
    $path = nimble_untaint_dev_path($path) || $path if length $path;
    if ( length( $wwid ) && !multipath_check( $wwid ) ) {
      for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
        eval { exec_command( [ 'multipathd', 'add', 'map', $w ], -1, timeout => 30 ); };
        last if multipath_check( $wwid );
      }
      my $mp_ready = sub { return multipath_check( $wwid ) };
      wait_for( $mp_ready, "multipath for \"$volname\"", 30 );
    }
  }
  $path = nimble_untaint_dev_path($path) || $path;
  return $path;
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $storeid );
  return 0 unless length( $path ) && -b $path;
  $path = nimble_untaint_dev_path($path) || return 0;
  my ( $device_path, @slaves ) = block_device_slaves( $path );
  $device_path = nimble_untaint_dev_path($device_path) || $device_path;
  exec_command( ['sync'] );
  exec_command( [ 'blockdev', '--flushbufs', $device_path ] );
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=10' ] ) };
  exec_command( ['sync'] );

  if ( length( $wwid ) ) {
    my $active = nimble_multipath_active_wwid($wwid);
    $active = nimble_untaint_multipath_wwid($active) if length($active);
    exec_command( [ 'multipathd', 'remove', 'map', $active ] ) if length($active);
  }
  block_device_action( 'remove', @slaves );
  return 1;
}

sub activate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $hints ) = @_;
  $class->nimble_volume_connection( $storeid, $scfg, $volname, 1 );
  $class->map_volume( $storeid, $scfg, $volname, $snapname, $hints );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );
  $class->nimble_volume_connection( $storeid, $scfg, $volname, 0 );
  print "Info :: Volume \"$volname\" deactivated.\n";
  return 1;
}

sub volume_resize {
  my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
  return $class->nimble_resize_volume( $scfg, $volname, $size, $storeid );
}

sub rename_volume {
  my ( $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname ) = @_;
  die "Error :: not implemented in storage plugin \"$class\".\n" if $class->can( 'api' ) && $class->api() < 10;
  if ( length( $target_volname ) ) {
    my $exists = $class->nimble_get_volume_info( $scfg, $target_volname, $storeid );
    die "Error :: target volume '$target_volname' already exists\n" if $exists;
  }
  else {
    $target_volname = $class->find_free_diskname( $storeid, $scfg, $target_vmid );
  }
  $class->unmap_volume( $storeid, $scfg, $source_volname );
  $class->nimble_rename_volume( $scfg, $storeid, $source_volname, $target_volname );
  return "$storeid:$target_volname";
}

sub volume_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  $class->nimble_snapshot_create( $scfg, $storeid, $volname, $snap );
  return 1;
}

sub volume_snapshot_rollback {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  $class->nimble_volume_restore( $scfg, $storeid, $volname, $volname, $snap, 1 );
  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  $class->nimble_snapshot_delete( $scfg, $storeid, $volname, $snap );
  return 1;
}

sub clone_image {
  my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;
  my $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
  $class->nimble_clone_from_snapshot( $scfg, $storeid, $name, $volname, $snap );
  return $name;
}

sub volume_has_feature {
  my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;
  my $features = {
    copy       => { current => 1, snap => 1 },
    clone      => { current => 1, snap => 1 },
    snapshot   => { current => 1 },
    sparseinit => { current => 1 },
    rename     => { current => 1 },
  };
  my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) = $class->parse_volname( $volname );
  my $key = $snapname ? "snap" : ( $isBase ? "base" : "current" );
  return 1 if $features->{ $feature } && $features->{ $feature }->{ $key };
  return undef;
}

sub create_base {
  my ( $class, $storeid, $scfg, $volname ) = @_;
  die "Error :: Creating base image is not implemented.\n";
}

# raw+size: 8-byte little-endian size header (bytes), then raw stream (PVE/backup compatibility, e.g. Veeam V13+)
sub RAW_SIZE_HEADER_LEN { 8 }

sub volume_import_formats {
  my ( $class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  return ['raw+size'] if !$snapshot;
  return [];
}

sub volume_export_formats {
  my ( $class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  return ['raw+size'] if !$snapshot;
  return [];
}

sub volume_import {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename ) = @_;
  die "Error :: volume_import: only raw+size format is supported.\n" if $format ne 'raw+size';
  die "Error :: volume_import: snapshot import is not supported.\n" if $snapshot;

  my $hlen = RAW_SIZE_HEADER_LEN();
  my $buf;
  my $n = read( $fh, $buf, $hlen );
  die "Error :: volume_import: failed to read size header ($hlen bytes).\n" if !$n || $n != $hlen;
  my $size_bytes = unpack( 'Q<', $buf );
  die "Error :: volume_import: invalid size in header ($size_bytes).\n" if $size_bytes < 1;

  my $size_alloc_bytes = size_bytes_to_mb( $size_bytes ) * 1024 * 1024;
  $class->nimble_create_volume( $scfg, $volname, $size_alloc_bytes, $storeid );
  eval {
    $class->activate_volume( $storeid, $scfg, $volname, undef, {} );
    my ( $path, undef, undef, undef ) = $class->filesystem_path( $scfg, $volname, undef, $storeid );
    die "Error :: volume_import: device path not available.\n" if !length( $path ) || !-b $path;
    open( my $dev, '>:raw', $path ) or die "Error :: volume_import: cannot open device $path: $!\n";
    my $chunk = 1024 * 1024;
    my $remaining = $size_bytes;
    while ( $remaining > 0 ) {
      my $to_read = $remaining < $chunk ? $remaining : $chunk;
      my $got = read( $fh, $buf, $to_read );
      last if !$got;
      my $w = syswrite( $dev, $buf, $got );
      die "Error :: volume_import: write failed after " . ( $size_bytes - $remaining ) . " bytes.\n" if !defined $w || $w != $got;
      $remaining -= $got;
    }
    close( $dev );
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    eval { $class->nimble_remove_volume( $scfg, $volname, $storeid ); };
    die $@;
  }
  return "$storeid:$volname";
}

sub volume_export {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots ) = @_;
  die "Error :: volume_export: only raw+size format is supported.\n" if $format ne 'raw+size';
  die "Error :: volume_export: snapshot export is not supported.\n" if $snapshot;

  my ( $size_bytes, undef, undef, undef ) = $class->volume_size_info( $scfg, $storeid, $volname, 30 );
  die "Error :: volume_export: could not get volume size.\n" if !$size_bytes || $size_bytes < 1;

  $class->activate_volume( $storeid, $scfg, $volname, undef, {} );
  eval {
    my ( $path, undef, undef, undef ) = $class->filesystem_path( $scfg, $volname, undef, $storeid );
    die "Error :: volume_export: device path not available.\n" if !length( $path ) || !-b $path;
    print $fh pack( 'Q<', $size_bytes );
    open( my $dev, '<:raw', $path ) or die "Error :: volume_export: cannot open device $path: $!\n";
    my $chunk = 1024 * 1024;
    my $remaining = $size_bytes;
    my $buf;
    while ( $remaining > 0 ) {
      my $to_read = $remaining < $chunk ? $remaining : $chunk;
      my $got = sysread( $dev, $buf, $to_read );
      last if !$got;
      print $fh $buf;
      $remaining -= $got;
    }
    close( $dev );
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    die $@;
  }
  return 1;
}

# Same hook name as PureStoragePlugin (no-op here; password updates use on_update_hook).
sub on_update_hook_full {
  my ( $class, $storeid, $scfg, $updated_props, $deleted_props ) = @_;
  return;
}

1;
