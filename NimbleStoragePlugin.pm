package PVE::Storage::Custom::NimbleStoragePlugin;

use strict;
use warnings;

use Data::Dumper qw( Dumper );

use IO::File   ();
use File::Path ();

use PVE::JSONSchema ();
use PVE::Tools qw( file_read_firstline run_command );
use PVE::INotify         ();
use PVE::Storage::Plugin ();

use JSON::XS qw( decode_json encode_json );
use LWP::UserAgent ();
use HTTP::Headers  ();
use HTTP::Request  ();
use URI::Escape qw( uri_escape );
use File::Basename qw( basename );
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
  my $tested_apiver = 12;
  my $apiver        = PVE::Storage::APIVER;
  my $apiage        = PVE::Storage::APIAGE;
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
  };
}

sub properties {
  return {
    address => {
      description => "HPE Nimble array management IP or DNS name.",
      type        => 'string'
    },
    username => {
      description => "Nimble API username.",
      type        => 'string'
    },
    password => {
      description => "Nimble API password.",
      type        => 'string'
    },
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
  };
}

sub options {
  return {
    address         => { fixed    => 1 },
    username        => { fixed    => 1 },
    password        => { fixed    => 1 },
    initiator_group => { optional => 1 },

    vnprefix  => { optional => 1 },
    pool_name => { optional => 1 },
    check_ssl => { optional => 1 },
    token_ttl => { optional => 1 },
    debug     => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
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

sub exec_command {
  my ( $command, $dm, %param ) = @_;
  $dm //= 1;
  my $cmd_name = $command->[0];
  if ( exists $cmd->{ $cmd_name } ) {
    eval { $command->[0] = get_command_path( $cmd_name ); };
    warn "Warning :: $@" if $@ && $dm >= 0;
  }
  print "Debug :: execute '" . join( ' ', @$command ) . "'\n" if $DEBUG >= 2;
  $param{ 'quiet' } = 1 unless exists $param{ 'quiet' }       if $DEBUG < 3;
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

# Find block device path by SCSI serial (e.g. from Nimble volume serial_number).
# Unlike Pure (fixed prefix 3624a9370), Nimble has no fixed WWN prefix in this plugin;
# we match the API serial_number against /sys/block/*/device/serial and by-id.
sub get_device_path_by_serial {
  my ( $serial ) = @_;
  die 'Error :: Volume serial is missing' unless length( $serial );
  my $path = '/dev/disk/by-id';
  return ( '', '' ) unless -d $path;
  opendir( my $dh, $path ) or return ( '', '' );
  my $best_path = '';
  my $wwid      = '';
  while ( my $e = readdir( $dh ) ) {
    next if $e =~ /^\.\.?$/;
    my $full = "$path/$e";
    next unless -l $full;
    my $target = readlink( $full );
    next unless defined $target;
    my $abs = Cwd::abs_path( "$path/$target" );
    next unless $abs && -b $abs;
    my $blk      = basename( $abs );
    my $ser_path = "/sys/block/$blk/device/serial";

    if ( -f $ser_path ) {
      my $dev_serial = file_read_firstline( $ser_path );
      if ( defined $dev_serial && $dev_serial =~ /^\s*(.+?)\s*$/ ) {
        $dev_serial = $1;
        if ( $dev_serial eq $serial || $dev_serial =~ /\Q$serial\E/ ) {
          $best_path = $abs;
          $wwid      = $e if $e =~ /^wwn-/;    # prefer WWN for multipath
          last;
        }
      }
    }
  }
  closedir( $dh );
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

sub multipath_check {
  my ( $wwid ) = @_;
  return 0 unless length( $wwid );
  my $mp  = get_command_path( 'multipath' );
  my $out = `$mp -l $wwid 2>/dev/null`;
  return $out ne '';
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
  my ( $scfg, $method, $path, $body, $storeid ) = @_;
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
    $req->content( encode_json( { username => $scfg->{ username }, password => $scfg->{ password } } ) );
    my $res = $ua->request( $req );
    die "Error :: Nimble login failed: " . $res->status_line . "\n" . ( $res->decoded_content // '' ) . "\n" unless $res->is_success;
    my $data = decode_json( $res->decoded_content );
    $auth = $data->{ session_token } or die "Error :: No session_token in response\n";
    $scfg->{ _auth_token } = $auth;
    my $token_data = { session_token => $auth, created_at => time(), ttl => $ttl };
    write_token_cache( $cache_path, $token_data ) if $cache_path;
  }

  my $ua = LWP::UserAgent->new( timeout => 30 );
  $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 ) unless $scfg->{ check_ssl };
  my $req = HTTP::Request->new( $method, $url );
  $req->header( 'Content-Type' => 'application/json' );
  $req->header( 'X-Auth-Token' => $auth );
  $req->content( encode_json( $body ) ) if defined $body && ref $body eq 'HASH' && %$body;
  my $res     = $ua->request( $req );
  my $content = $res->decoded_content;

  if ( !$res->is_success ) {
    if ( $res->code == 401 && $cache_path ) {
      unlink $cache_path;
      delete $scfg->{ _auth_token };
      return nimble_api_call( $scfg, $method, $path, $body, $storeid );
    }
    die "Error :: Nimble API $method $path: " . $res->status_line . "\n" . ( $content // '' ) . "\n";
  }
  return length( $content ) ? decode_json( $content ) : {};
}

sub nimble_get_local_iscsi_iqn {
  my $path = '/etc/iscsi/initiatorname.iscsi';
  return undef unless -r $path;
  my $line = file_read_firstline( $path );
  return undef unless defined $line && $line =~ m/^\s*InitiatorName\s*=\s*(.+)\s*$/;
  my $iqn = $1;
  $iqn =~ s/^\s+|\s+$//g;
  return $iqn if length( $iqn ) && $iqn =~ m/^iqn\./;
  return undef;
}

sub nimble_get_initiator_group_id {
  my ( $scfg, $name, $storeid ) = @_;
  my $enc  = uri_escape( $name );
  my $r    = nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc", undef, $storeid );
  my $list = $r->{ data } || [];
  for my $g ( @$list ) {
    return $g->{ id } if $g->{ name } eq $name;
  }
  die "Error :: Initiator group \"$name\" not found on Nimble array.\n";
}

# Resolve initiator group ID: use config name if set, else auto-create/find by PVE nodename + local IQN.
sub nimble_ensure_initiator_group_id {
  my ( $scfg, $storeid ) = @_;
  my $ig_name = $scfg->{ initiator_group };
  if ( defined $ig_name && $ig_name ne '' ) {
    return nimble_get_initiator_group_id( $scfg, $ig_name, $storeid );
  }
  my $iqn = nimble_get_local_iscsi_iqn();
  die "Error :: initiator_group not set and could not read local iSCSI IQN (install open-iscsi and configure /etc/iscsi/initiatorname.iscsi).\n"
    unless $iqn;
  my $nodename = PVE::INotify::nodename();
  $ig_name = "pve-$nodename";
  my $enc  = uri_escape( $ig_name );
  my $r    = nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc", undef, $storeid );
  my $list = $r->{ data } || [];

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

sub nimble_get_volume_id {
  my ( $scfg, $volname, $storeid ) = @_;
  my $name = nimble_volname( $scfg, $volname, undef );
  my $enc  = uri_escape( $name );
  my $r    = nimble_api_call( $scfg, 'GET', "volumes?name=$enc", undef, $storeid );
  my $list = $r->{ data } || [];
  for my $v ( @$list ) {
    return ( $v->{ id }, $v ) if $v->{ name } eq $name;
  }
  return ( undef, undef );
}

sub nimble_list_volumes {
  my ( $class, $scfg, $vmid, $storeid ) = @_;
  $vmid = '*' unless defined $vmid;
  my $filter = "vm-$vmid-disk-*,vm-$vmid-cloudinit,vm-$vmid-state-*";
  my $prefix = nimble_name_prefix( $scfg );
  my $r      = nimble_api_call( $scfg, 'GET', 'volumes', undef, $storeid );
  my $list   = $r->{ data } || [];
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
  return \@volumes;
}

sub nimble_get_volume_info {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return undef unless $vol;
  my $volname = $vol->{ name };
  my $prefix  = nimble_name_prefix( $scfg );
  $volname = substr( $volname, length( $prefix ) ) if length( $prefix );
  return {
    name   => $volname,
    serial => $vol->{ serial_number },
    size   => ( $vol->{ size } || 0 ) * 1024 * 1024,
    used   => ( $vol->{ vol_usage_compressed_bytes } || $vol->{ size } || 0 ) * 1024 * 1024,
    ctime  => $vol->{ creation_time } || 0,
    volid  => $storeid ? "$storeid:$volname" : $volname,
    format => 'raw'
  };
}

sub nimble_create_volume {
  my ( $class, $scfg, $volname, $size_bytes, $storeid ) = @_;
  my $name    = nimble_volname( $scfg, $volname, undef );
  my $size_mb = int( $size_bytes / ( 1024 * 1024 ) );
  $size_mb = 1 if $size_mb < 1;
  my $body = { name => $name, size => $size_mb };
  $body->{ pool_name } = $scfg->{ pool_name } if $scfg->{ pool_name };
  my $r      = nimble_api_call( $scfg, 'POST', 'volumes', $body, $storeid );
  my $vol    = $r->{ data } || $r;
  my $serial = $vol->{ serial_number } or die "Error :: No serial_number in create response\n";
  print "Info :: Volume \"$volname\" created (serial=$serial).\n";
  my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
  nimble_api_call( $scfg, 'POST', 'access_control_records', { vol_id => $vol->{ id }, initiator_group_id => $ig_id }, $storeid );
  return 1;
}

sub nimble_delete_volume {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $vol_id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  nimble_api_call( $scfg, 'DELETE', "volumes/$vol_id", undef, $storeid );
  print "Info :: Volume \"$volname\" deleted.\n";
  return 1;
}

sub nimble_resize_volume {
  my ( $class, $scfg, $volname, $size_bytes, $storeid ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  my $size_mb = int( $size_bytes / ( 1024 * 1024 ) );
  $size_mb = 1 if $size_mb < 1;
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
  my $snap_suffix = $snap_name;
  $snap_suffix =~ s/^veeam_/veeam-/;
  $snap_suffix = 'snap-' . $snap_suffix unless $snap_suffix =~ /^snap-/;
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
  my $list      = $r->{ data } || [];
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
  my $list      = $r->{ data } || [];
  my $snap_id;

  for my $s ( @$list ) {
    if ( $s->{ name } eq $snap_full ) { $snap_id = $s->{ id }; last; }
  }
  die "Error :: Snapshot \"$snap\" not found\n" unless $snap_id;
  nimble_api_call( $scfg, 'POST', "volumes/$vol_id/restore", { base_snap_id => $snap_id }, $storeid );
  print "Info :: Volume \"$volname\" restored from snapshot \"$snap\".\n";
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
    my $device_path = '/sys/block/' . $device . '/device';
    if ( $action eq 'remove' ) {
      exec_command( [ 'blockdev', '--flushbufs', '/dev/' . $device ] );
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

sub get_device_path_wwid {
  my ( $class, $scfg, $volname ) = @_;
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, undef );
  return ( '', '' ) unless $volume && $volume->{ serial };
  return get_device_path_by_serial( $volume->{ serial } );
}

sub filesystem_path {
  my ( $class, $scfg, $volname, $snapname ) = @_;
  die "Error :: filesystem_path: snapshot not implemented ($snapname)\n" if defined( $snapname );
  my ( $vtype, undef, $vmid ) = $class->parse_volname( $volname );
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname );
  return wantarray ? ( "", "", "", "" ) : "" unless length( $path );
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
  $class->nimble_delete_volume( $scfg, $volname, $storeid );
  return undef;
}

sub list_images {
  my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
  set_debug_from_config( $scfg );
  return $class->nimble_list_volumes( $scfg, $vmid, $storeid );
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  my $r     = nimble_api_call( $scfg, 'GET', 'pools', undef, $storeid );
  my $list  = $r->{ data } || [];
  my $total = 0;
  my $used  = 0;
  for my $p ( @$list ) {
    $total += ( $p->{ capacity } || 0 );
    if ( $p->{ usage_valid } && $p->{ usage } ) {
      $used += ( $p->{ usage }->{ compressed_usage } || $p->{ usage }->{ uncompressed_usage } || 0 );
    }
  }
  $total = 1 if $total <= 0;
  my $free = $total - $used;
  return ( $total, $free, $used, 1 );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
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
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname );
  scsi_scan_new( 'iscsi' );
  my $path_exists = sub { return -e $path };
  wait_for( $path_exists, "volume \"$volname\" to appear", 30 );
  if ( length( $wwid ) && !multipath_check( $wwid ) ) {
    exec_command( [ 'multipathd', 'add', 'map', $wwid ] );
    my $mp_ready = sub { return multipath_check( $wwid ) };
    wait_for( $mp_ready, "multipath for \"$volname\"", 30 );
  }
  return $path;
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname );
  return 0 unless length( $path ) && -b $path;
  my ( $device_path, @slaves ) = block_device_slaves( $path );
  exec_command( ['sync'] );
  exec_command( [ 'blockdev', '--flushbufs', $device_path ] );
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=10' ] ) };
  exec_command( ['sync'] );

  if ( length( $wwid ) && multipath_check( $wwid ) ) {
    exec_command( [ 'multipathd', 'remove', 'map', $wwid ] );
  }
  block_device_action( 'remove', @slaves );
  return 1;
}

sub activate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  $class->map_volume( $storeid, $scfg, $volname, $snapname );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );
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
  $target_volname = $class->find_free_diskname( $storeid, $scfg, $target_vmid ) unless length( $target_volname );
  $class->unmap_volume( $storeid, $scfg, $source_volname );
  $class->nimble_rename_volume( $scfg, $storeid, $source_volname, $target_volname );
  return "$storeid:$target_volname";
}

sub volume_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  $class->nimble_snapshot_create( $scfg, $storeid, $snap, $volname );
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
  $class->nimble_volume_restore( $scfg, $storeid, $name, $volname, $snap );
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

sub volume_import {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename ) = @_;
  die "Error :: volume_import not implemented.\n";
}

1;
