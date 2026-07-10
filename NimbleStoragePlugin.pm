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
use Scalar::Util qw( looks_like_number );

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

# Min epoch treated as real calendar time for Nimble snapshot fields (not id-hash identity).
use constant NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH => 946684800;    # 2000-01-01 00:00:00 UTC

my $NIMBLE_API_VERSION = 'v1';
my $default_port       = 5392;
my $DEBUG              = $ENV{ NIMBLE_DEBUG } // 0;

# Canonical storage.cfg keys are nimble_-prefixed (v0.0.25+) so they can never collide with another
# plugin's properties() — PVE::SectionConfig merges every plugin's properties() into ONE global
# namespace and dies on any duplicate name (pve-purestorage-plugin owns address/vnprefix/check_ssl/
# token_ttl/debug; v0.0.23 died on the base class's `port`). Legacy pre-v0.0.25 spellings are still
# accepted: properties() declares them when no other plugin claims the name, options() references
# them when they exist globally, and check_config() rewrites them to the canonical key in-memory —
# so internal code only ever reads the canonical keys, and any later storage.cfg write persists the
# canonical spelling.
our %NIMBLE_LEGACY_CONFIG_KEYS = (
  nimble_address              => 'address',
  nimble_vnprefix             => 'vnprefix',
  nimble_check_ssl            => 'check_ssl',
  nimble_token_ttl            => 'token_ttl',
  nimble_debug                => 'debug',
  nimble_initiator_group      => 'initiator_group',
  nimble_pool_name            => 'pool_name',
  nimble_volume_collection    => 'volume_collection',
  nimble_auto_iscsi_discovery => 'auto_iscsi_discovery',
  nimble_iscsi_discovery_ips  => 'iscsi_discovery_ips',
  nimble_storeid              => 'storeid',
);

sub get_debug_level {
  my ( $scfg ) = @_;
  return $DEBUG unless defined $scfg;
  # Legacy key read: $scfg is canonicalized by check_config in all PVE flows, but this helper also
  # sees raw hashes (tests, defensive early-debug paths).
  my $v = $scfg->{ nimble_debug } // $scfg->{ debug };
  return defined $v ? $v : $DEBUG;
}

sub set_debug_from_config {
  my ( $scfg ) = @_;
  return unless defined $scfg;
  my $v = $scfg->{ nimble_debug } // $scfg->{ debug };
  $DEBUG = $v if defined $v;
}

### Configuration
sub api {
  # PVE::Storage::APIVER / APIAGE are `use constant` (subs), not package scalars — do not use $PVE::Storage::APIVER.
  # Call with (); bareword form trips strict subs under perl 5.36+ (e.g. CI Docker bookworm).
  my $tested_apiver = 14;
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
    content => [ { images => 1, rootdir => 1, none => 1 }, { images => 1, rootdir => 1 } ],
    format  => [ { raw    => 1 },            "raw" ],
    # `password` is sensitive (APIVER 11 mechanism): PVE keeps it out of storage.cfg and passes it
    # to on_add/on_update hooks separately; our hooks persist it to /etc/pve/priv/storage/<id>.pw.
    # This also matches PVE's pre-APIVER-11 hard-coded sensitive list (which included `password`),
    # so behavior is now uniform across PVE 8 and 9 — previously the empty {} declaration opted out
    # on APIVER 11+ hosts only, leaving the password in cluster-replicated, GUI-visible storage.cfg.
    # Legacy cfg password lines from older plugin versions still work (see nimble_api_credentials).
    'sensitive-properties' => { password => 1 },
  };
}

# Re-entrancy latch: our properties() probes other registered plugins' properties() (see below).
# If a co-installed plugin ever copies that pattern and probes ours back, both would recurse — the
# latch makes the inner call return the raw declaration list, which is exactly what a prober needs.
our $properties_in_progress = 0;

sub properties {
  # PVE::SectionConfig registers every plugin's properties() into ONE global propertyList and dies
  # ("duplicate property") on any name that is already there — regardless of whether the schemas are
  # identical. Two consequences shape this sub:
  #   - Canonical keys are nimble_-prefixed (v0.0.25+) so they cannot collide with the base class
  #     (`port`, `nodes`, …), core plugins (`username`/`password`), or other custom plugins
  #     (pve-purestorage-plugin owns address/vnprefix/check_ssl/token_ttl/debug).
  #   - Legacy pre-v0.0.25 spellings are still declared so existing storage.cfg entries keep parsing,
  #     but ONLY if no other registered plugin claims the name. The claim check walks the registered
  #     plugin list, which PVE::Storage fully populates BEFORE init() calls any properties() — that
  #     makes it deterministic for both merge orders. (The old check against the propertyList alone
  #     was racy: init() merges plugins in random hash order, so co-install with Pure still died on
  #     ~half of all daemon starts, whenever Pure's redeclaration merged second.)
  my $canonical = {
    nimble_address => {
      description => "HPE Nimble array management IP or DNS name.",
      type        => 'string'
    },
    nimble_initiator_group => {
      description => "Initiator group name (optional). If unset, a group is created automatically using this host's iSCSI IQN.",
      type        => 'string'
    },
    nimble_vnprefix => {
      description => "Prefix for volume names on the Nimble array.",
      type        => 'string'
    },
    nimble_pool_name => {
      description => "Pool name for new volumes (optional).",
      type        => 'string'
    },
    nimble_volume_collection => {
      description => "Nimble volume collection name (optional). New volumes will be added to this collection so array-side protection/snapshot schedules apply.",
      type        => 'string'
    },
    nimble_check_ssl => {
      description => "Verify the server's TLS certificate.",
      type        => 'boolean',
      default     => 'no'
    },
    nimble_token_ttl => {
      description => "Session token time-to-live in seconds.",
      type        => 'integer',
      default     => 3600
    },
    nimble_debug => {
      description => "Enable debug logging (0=off, 1=basic, 2=verbose, 3=trace).",
      type        => 'integer',
      minimum     => 0,
      maximum     => 3,
      default     => 0
    },
    nimble_auto_iscsi_discovery => {
      description => "When storage is activated, run iSCSI discovery and login using the array's discovery IPs (from Nimble subnets API). Default on; set to no/0 to disable.",
      type        => 'boolean',
      default     => 'yes'
    },
    nimble_iscsi_discovery_ips => {
      description => "iSCSI discovery portals (comma-separated; host or host:port). When set, the plugin uses ONLY these IPs for discovery — the Nimble subnets API and network_interfaces API are NOT queried, and no session-derived fallback is used. Use this to pin discovery to known-reachable portals and avoid timeout delays from unreachable subnets.",
      type        => 'string',
    },
    nimble_folder => {
      description => "Nimble folder name. New volumes are created inside this folder (POST v1/volumes folder_id). Leave unset to use the root folder (default Nimble behaviour).",
      type        => 'string',
    },
    nimble_limit_iops => {
      description => "IOPS limit for new volumes. Applied as limit_iops on POST v1/volumes. Range: 256–4294967294, or -1 for unlimited (default). If both limit_iops and limit_mbps are set, the IOPS constraint must not be hit after the MBPS limit (limit_iops <= limit_mbps*1048576/block_size). Does not retroactively change existing volumes.",
      type        => 'integer',
      default     => -1,
    },
    nimble_limit_mbps => {
      description => "Throughput limit in MB/s for new volumes. Applied as limit_mbps on POST v1/volumes. Range: 1–4294967294, or -1 for unlimited (default). If both limit_iops and limit_mbps are set, the MBPS limit must not be hit before the IOPS limit. Does not retroactively change existing volumes.",
      type        => 'integer',
      default     => -1,
    },
    nimble_storeid => {
      description => "Proxmox storage ID (storage.cfg section name). Auto-set by the plugin to match the section name so workers can resolve priv/password and token paths when the explicit storeid argument is omitted (cluster import/migration). Do not change manually.",
      type        => 'string',
      optional    => 1,
    },
  };
  my $props = { %$canonical };
  for my $new ( keys %NIMBLE_LEGACY_CONFIG_KEYS ) {
    my $old    = $NIMBLE_LEGACY_CONFIG_KEYS{ $new };
    my %schema = %{ $canonical->{ $new } };
    $schema{ description } = "Legacy alias of ${new} (pre-v0.0.25 configs). " . $schema{ description };
    $props->{ $old } = \%schema;
  }

  return $props if $properties_in_progress;
  local $properties_in_progress = 1;

  my $registered = eval { PVE::Storage::Plugin->private()->{ propertyList } } // {};
  my $plugins    = eval { PVE::Storage::Plugin->private()->{ plugins } }      // {};
  my %foreign;
  for my $type ( sort keys %$plugins ) {
    next if $type eq type();
    my $p = eval { $plugins->{ $type }->properties() } // {};
    $foreign{ $_ } = 1 for keys %$p;
  }
  # Never (re)declare a name someone else owns: base-class/core names are already in the
  # propertyList; other custom plugins are caught by the registered-plugin scan above regardless
  # of whether their properties() merges before or after ours.
  delete $props->{ $_ } for grep { $registered->{ $_ } || $foreign{ $_ } } keys %$props;
  return $props;
}

sub options {
  my $opts = {
    nimble_address => { optional => 1 },
    port           => { optional => 1 },
    username       => { optional => 1 },
    password       => { optional => 1 },
    nimble_initiator_group => { optional => 1 },

    nimble_vnprefix  => { optional => 1 },
    nimble_pool_name => { optional => 1 },
    nimble_volume_collection => { optional => 1 },
    nimble_check_ssl => { optional => 1 },
    nimble_token_ttl => { optional => 1 },
    nimble_debug     => { optional => 1 },
    nimble_auto_iscsi_discovery => { optional => 1 },
    nimble_iscsi_discovery_ips  => { optional => 1 },
    nimble_folder      => { optional => 1 },
    nimble_limit_iops  => { optional => 1 },
    nimble_limit_mbps  => { optional => 1 },
    nimble_storeid     => { optional => 1 },
    nodes          => { optional => 1 },
    disable        => { optional => 1 },
    content        => { optional => 1 },
    format         => { optional => 1 },
  };
  # Legacy spellings stay parseable whenever the property exists globally — either we declared it
  # in properties() (no rival plugin claims it) or another plugin owns the name (for the names Pure
  # owns the schemas match; ours were copied from Pure originally). init() calls options() AFTER
  # merging every plugin's properties(), so the propertyList is complete here. Referencing a name
  # nobody declared would make init() die ("undefined property"), hence the existence check.
  my $registered = eval { PVE::Storage::Plugin->private()->{ propertyList } } // {};
  for my $old ( values %NIMBLE_LEGACY_CONFIG_KEYS ) {
    $opts->{ $old } = { optional => 1 } if $registered->{ $old };
  }
  return $opts;
}

sub check_config {
  my ( $class, $sectionId, $config, $create, $skipSchemaCheck ) = @_;

  # Brief interim configs may have used nimble_user without username.
  if ( defined $config->{ nimble_user } && length( $config->{ nimble_user } ) ) {
    $config->{ username } //= $config->{ nimble_user };
  }

  # Rewrite legacy (pre-v0.0.25) key spellings to the canonical nimble_-prefixed keys BEFORE the
  # schema check: internal code reads only canonical keys, and any later storage.cfg write persists
  # the canonical spelling (one-way migration). When both spellings are present, canonical wins.
  for my $new ( keys %NIMBLE_LEGACY_CONFIG_KEYS ) {
    my $old = $NIMBLE_LEGACY_CONFIG_KEYS{ $new };
    next if !exists $config->{ $old };
    my $v = delete $config->{ $old };
    $config->{ $new } //= $v;
  }

  my $opts = $class->SUPER::check_config( $sectionId, $config, $create, $skipSchemaCheck );
  # TrueNAS-style: keep section id on $scfg (storage_config omits the key name from the hash body).
  # Ensures nimble_effective_storeid finds a store id for priv files / token cache when PVE passes
  # only $scfg (e.g. some worker paths).
  if ( ref($opts) eq 'HASH' && defined $sectionId && $sectionId ne '' ) {
    $opts->{ nimble_storeid } = $sectionId;
  }
  return $opts;
}

# Password file layout matches PVE core plugins with sensitive `password` (same path as ESXiPlugin /
# CIFSPlugin): /etc/pve/priv/storage/<storeid>.pw. We also write legacy paths for clusters that
# predate that convention.
sub nimble_password_file_paths {
  my ($storeid) = @_;
  return () if !defined $storeid || $storeid eq '';
  return (
    "/etc/pve/priv/storage/${storeid}.pw",
    "/etc/pve/priv/storage/${storeid}.nimble.pw",
    "/etc/pve/priv/nimble/${storeid}.pw",
  );
}

sub nimble_password_ensure_parent_dirs {
  for my $dir ( '/etc/pve/priv/storage', '/etc/pve/priv/nimble' ) {
    next if -d $dir;
    eval { File::Path::make_path( $dir, { mode => 0700 } ); };
    die "Error :: cannot create $dir: $@\n" if $@ || !-d $dir;
  }
}

sub nimble_set_password {
  my ( $storeid, $password ) = @_;
  nimble_password_ensure_parent_dirs();
  for my $f ( nimble_password_file_paths($storeid) ) {
    PVE::Tools::file_set_contents( $f, "$password\n", 0600, 1 );
  }
}

sub nimble_read_password_file {
  my ($storeid) = @_;
  return undef if !defined $storeid || $storeid eq '';
  for my $f ( nimble_password_file_paths($storeid) ) {
    next unless -f $f;
    my $c = PVE::Tools::file_get_contents($f);
    next unless defined $c;
    chomp $c;
    return $c if length $c;
  }
  return undef;
}

sub nimble_delete_password_file {
  my ($storeid) = @_;
  for my $f ( nimble_password_file_paths($storeid) ) {
    unlink $f if -e $f;
  }
}

sub on_add_hook {
  my ( $class, $storeid, $scfg, %sensitive ) = @_;
  my $pw = $sensitive{ password };
  $pw = $scfg->{ password } if ( !defined($pw) || $pw eq '' ) && ref($scfg) eq 'HASH';
  nimble_set_password( $storeid, $pw ) if defined($pw) && $pw ne '';
  return;
}

sub on_update_hook {
  my ( $class, $storeid, $opts, %sensitive ) = @_;
  $opts //= {};
  if ( exists $sensitive{ password } ) {
    my $pw = $sensitive{ password };
    if ( defined($pw) && $pw ne '' ) {
      nimble_set_password( $storeid, $pw );
    }
    else {
      nimble_delete_password_file($storeid);
    }
  }
  elsif ( exists $opts->{ password } ) {
    my $pw = $opts->{ password };
    if ( defined($pw) && $pw ne '' ) {
      nimble_set_password( $storeid, $pw );
    }
    else {
      nimble_delete_password_file($storeid);
    }
  }
  return;
}

sub on_delete_hook {
  my ( $class, $storeid, $scfg ) = @_;
  nimble_delete_password_file($storeid);
  if ( my $p = get_token_cache_path($storeid) ) {
    unlink $p if -e $p;
  }
  # Multipath alias state for this storage: cluster-replicated WWID cache plus this node's conf.d
  # fragment. Without this, removed storages leave aliases in multipathd forever. iSCSI sessions and
  # node.startup=automatic records are deliberately NOT torn down here: per-volume target sessions
  # cannot be attributed to one storeid (another storage definition may address the same array), and
  # killing sessions under running VMs would be worse than leaving idle logins behind.
  eval {
    my $wc = nimble_multipath_wwid_cache_path($storeid);
    unlink $wc if -e $wc;
    my $conf = nimble_multipath_conf_path($storeid);
    if ( -e $conf ) {
      unlink $conf;
      nimble_multipath_reconfigure();
    }
  };
  warn "Warning :: [nimble-multipath] cleanup on storage delete for \"$storeid\": $@\n" if $@;
  return;
}

# Storage section in storage.cfg usually does not repeat the section id; some PVE workers omit the
# explicit $storeid argument. Resolve the same id for priv files and token cache (import child, etc.).
sub nimble_effective_storeid {
  my ( $scfg, $storeid ) = @_;
  return $storeid if defined $storeid && $storeid ne '';
  return undef unless ref($scfg) eq 'HASH';
  # Injected in check_config (TrueNAS-style); authoritative when present. The legacy `storeid`
  # spelling still appears in raw hashes that bypassed check_config (tests, defensive).
  my $injected = $scfg->{ nimble_storeid } // $scfg->{ storeid };
  return $injected if defined $injected && $injected ne '';
  for my $k (qw( storage storagename name id cfgkey section )) {
    my $v = $scfg->{ $k };
    return $v if defined $v && $v ne '';
  }
  return undef;
}

sub nimble_api_credentials {
  my ( $scfg, $storeid ) = @_;
  my $user = $scfg->{ username } // $scfg->{ nimble_user };
  die "Error :: username not set\n" if !defined($user) || $user eq '';
  # Priv file first: with `password` declared sensitive, the API updates the priv file via hooks but
  # never rewrites a legacy plaintext line in storage.cfg — so after a password change the cfg copy
  # (if one still exists from an older plugin version) is stale while the file is current. The cfg
  # fallback keeps legacy configs working until their first password update. To change the password,
  # use `pvesm set <id> --password ...` (manual storage.cfg edits are ignored once a priv file exists).
  my $sid  = nimble_effective_storeid( $scfg, $storeid );
  my $pass = ( defined $sid && $sid ne '' ) ? nimble_read_password_file($sid) : undef;
  $pass = $scfg->{ password } if !defined($pass) || $pass eq '';
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
  my $prefix = $scfg->{ nimble_vnprefix } // '';
  return $prefix;
}

sub nimble_volname {
  my ( $scfg, $volname, $snapname ) = @_;
  $snapname //= '';
  my $name = nimble_name_prefix( $scfg ) . $volname;
  if ( length( $snapname ) ) {
    my $snap = $snapname;
    $snap =~ s/^(veeam_)/veeam-/;
    # Always prefix — a conditional prefix made PVE snapshots "x" and "snap-x" map to the SAME
    # array snapshot name (".snap-x"), so deleting one deleted the other's data. Reverse mapping in
    # volume_snapshot_info strips exactly one leading "snap-", so ".snap-snap-x" round-trips to
    # "snap-x" correctly. (Array snapshots created by pre-v0.0.24 plugins for PVE snapshots that
    # themselves started with "snap-" — a naming collision case — resolve as not-found afterwards.)
    $snap = 'snap-' . $snap;
    $name .= '.' . $snap;
  }
  return $name;
}

# Resolve the actual array-side name for $volname by querying the API.
# Returns prefix+volname (the standard constructed name) when the volume exists with
# the prefix.  Falls back to the bare volname when the volume was created before
# nimble_vnprefix was set.  Also accepts an optional $snapname and appends the
# .snap-<name> suffix to whatever base name is found on the array.
# Used by snapshot/clone/rename operations so they target the correct object name
# even when old volumes live without the prefix on the array.
sub nimble_actual_array_volname {
  my ( $scfg, $volname, $snapname, $storeid ) = @_;
  $snapname //= '';

  # Query the array to find the real name (handles prefix-less fallback volumes).
  # If the lookup fails (network, auth), fall back to the constructed name so callers
  # don't break when the array is temporarily unreachable.
  my $base_name;
  my $vol = eval {
    my ( undef, $v ) = nimble_get_volume_id( $scfg, $volname, $storeid );
    $v;
  };
  if ( $vol && ref($vol) eq 'HASH' && length( $vol->{ name } // '' ) ) {
    $base_name = $vol->{ name };
  } else {
    $base_name = nimble_volname( $scfg, $volname, undef );
  }

  if ( length($snapname) ) {
    my $snap = $snapname;
    $snap =~ s/^(veeam_)/veeam-/;
    $snap = 'snap-' . $snap;
    $base_name .= '.' . $snap;
  }
  return $base_name;
}

# True if this Nimble snapshot row was created by Proxmox through this plugin (POST snapshots with
# nimble_volname(vol, snap) => prefix+volname.snap-<name>). Those snaps are already represented in
# the VM config under the user snapshot name; nimble_sync_array_snapshots must not also treat them
# as array-only imports (nimble<epoch>), or the GUI shows two entries for one LUN snapshot.
sub nimble_array_snapshot_is_pve_ui_snapshot {
  my ( $scfg, $pve_volname, $array_snap_name, $storeid ) = @_;
  return 0 unless defined $array_snap_name && length $array_snap_name;
  # Use actual array name (handles prefix-less volumes); fall back to constructed name if unavailable.
  my $base = defined($storeid)
    ? nimble_actual_array_volname( $scfg, $pve_volname, undef, $storeid )
    : nimble_volname( $scfg, $pve_volname );
  return 0 unless index( $array_snap_name, "$base." ) == 0;
  my $suffix = substr( $array_snap_name, length($base) + 1 );
  return ( $suffix =~ /^snap-/ ) ? 1 : 0;
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

# multipathd map argument (friendly alias or hex WWID) for perl -T.
sub nimble_untaint_multipath_map_token {
  my ($s) = @_;
  return '' unless defined $s && length $s;
  return $1 if $s =~ /^([a-zA-Z0-9_.:@+=-]{1,256})$/;
  return '';
}

# API / storage.cfg / iscsiadm output for -T / -p must be laundered for perl -T or run_command dies
# ("Insecure dependency in exec") — eval in callers used to hide that and left sessions never established.
sub nimble_untaint_iscsiadm_scalar {
  my ($v) = @_;
  return '' unless defined $v && length $v;
  $v =~ s/^\s+|\s+$//g;
  return '' if $v eq '';
  return $1 if $v =~ /^([A-Za-z0-9.\[\]:,_=+-]+)$/ && length($1) <= 512;
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
    my $out = '';
    eval { run_command( [ $mp, '-l', $w ], outfunc => sub { $out .= shift . "\n" }, quiet => 1 ) };
    return 1 if length($out);
  }
  return 0;
}

sub nimble_multipath_active_wwid {
  my ($wwid) = @_;
  my $mp = get_command_path('multipath');
  for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
    my $out = '';
    eval { run_command( [ $mp, '-l', $w ], outfunc => sub { $out .= shift . "\n" }, quiet => 1 ) };
    return $w if length($out);
  }
  return '';
}

# Tear down multipath for unmap/migration. multipathd remove map / multipath -f often return non-zero
# (busy, already removed, race). exec_command(..., -1, quiet, errfunc): non-fatal, no Perl/task noise.
sub nimble_multipath_teardown_for_unmap {
  my ($wwid) = @_;
  return unless length($wwid);
  my $mp = get_command_path('multipath');
  my %silent = ( quiet => 1, errfunc => sub { } );
  for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
    next unless length($w);
    my $t = nimble_untaint_multipath_wwid($w);
    next unless length($t);
    exec_command( [ 'multipathd', 'remove', 'map', $t ], -1, %silent );
  }
  for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
    my $t = nimble_untaint_multipath_wwid($w);
    next unless length($t);
    exec_command( [ $mp, '-f', $t ], -1, %silent );
  }
}

# --- Multipath alias management ---
# Aliases are written to /etc/multipath/conf.d/nimble-<storeid>.conf (never /etc/multipath.conf).
# Alias lifetime follows volume lifetime: added on first map_volume, removed on free_image.
# WWIDs are cached in /etc/pve/priv/nimble/<storeid>.wwid.json so activate_storage can restore
# aliases on reboot without requiring devices to be present first.

sub nimble_multipath_alias_name {
  my ( $storeid, $volname ) = @_;
  return "$storeid-$volname";
}

sub nimble_multipath_conf_path {
  my ($storeid) = @_;
  return "/etc/multipath/conf.d/nimble-$storeid.conf";
}

sub nimble_multipath_wwid_cache_path {
  my ($storeid) = @_;
  return "/etc/pve/priv/nimble/$storeid.wwid.json";
}

sub nimble_multipath_load_wwid_cache {
  my ($storeid) = @_;
  my $path = nimble_multipath_wwid_cache_path($storeid);
  return {} unless -f $path;
  my $json = eval { file_get_contents($path) };
  return {} unless defined $json && length $json;
  my $data = eval { decode_json($json) };
  return ( ref($data) eq 'HASH' ) ? $data : {};
}

sub nimble_multipath_save_wwid_cache {
  my ( $storeid, $cache ) = @_;
  my $path = nimble_multipath_wwid_cache_path($storeid);
  File::Path::make_path( dirname($path), { mode => 0700 } ) unless -d dirname($path);
  my $tmp = "$path.tmp.$$";
  eval {
    open( my $fh, '>', $tmp ) or die "Cannot write $tmp: $!";
    print $fh encode_json($cache);
    close($fh);
    rename( $tmp, $path ) or die "Cannot rename $tmp to $path: $!";
  };
  if ($@) {
    unlink $tmp;
    warn "Warning :: [nimble-multipath] Failed to save WWID cache for $storeid: $@\n";
  }
}

sub nimble_multipath_wwid_in_main_conf {
  my ($wwid) = @_;
  return 0 unless length($wwid);
  return 0 unless -f '/etc/multipath.conf';
  my $content = eval { file_get_contents('/etc/multipath.conf') };
  return 0 unless defined $content;
  return index( lc($content), lc($wwid) ) >= 0 ? 1 : 0;
}

sub nimble_multipath_write_conf {
  my ( $storeid, $aliases ) = @_;
  my $path = nimble_multipath_conf_path($storeid);
  unless ( keys %$aliases ) {
    unlink $path if -f $path;
    return;
  }
  my $content = "# Managed by pve-nimble-plugin. Do not edit manually.\n";
  $content .= "multipaths {\n";
  for my $wwid ( sort keys %$aliases ) {
    $content .= "    multipath {\n";
    $content .= "        wwid $wwid\n";
    $content .= "        alias $aliases->{$wwid}\n";
    $content .= "    }\n";
  }
  $content .= "}\n";
  File::Path::make_path( dirname($path) ) unless -d dirname($path);
  my $tmp = "$path.tmp.$$";
  eval {
    open( my $fh, '>', $tmp ) or die "Cannot write $tmp: $!";
    print $fh $content;
    close($fh);
    rename( $tmp, $path ) or die "Cannot rename $tmp to $path: $!";
  };
  if ($@) {
    unlink $tmp;
    warn "Warning :: [nimble-multipath] Failed to write conf.d for $storeid: $@\n";
  }
}

sub nimble_multipath_build_aliases {
  my ( $storeid, $cache ) = @_;
  my %aliases;
  for my $vn ( keys %$cache ) {
    my $w = $cache->{$vn};
    next unless length($w);
    next if nimble_multipath_wwid_in_main_conf($w);
    $aliases{$w} = nimble_multipath_alias_name( $storeid, $vn );
  }
  return %aliases;
}

sub nimble_multipath_reconfigure {
  exec_command( ['multipathd', 'reconfigure'], -1, timeout => 15 );
}

# The WWID cache lives under /etc/pve/priv (pmxcfs, replicated to every cluster node), and
# register/deregister do a read-modify-write on it. Two nodes mapping/unmapping different volumes on the
# same storage at the same time can race on a plain read+write and silently drop each other's entry.
# cfs_lock_storage uses pmxcfs's own distributed lock (a local flock would not exclude other nodes).
# PVE::Cluster is soft-required: unit tests and other non-PVE contexts run without it, so degrade to
# unlocked best-effort there rather than failing the whole map/unmap.
sub nimble_multipath_with_storage_lock {
  my ( $storeid, $code ) = @_;
  return $code->() unless eval { require PVE::Cluster; 1 };
  my $res = eval { PVE::Cluster::cfs_lock_storage( $storeid, 10, $code ); };
  if ( my $err = $@ ) {
    chomp $err;
    warn "Warning :: [nimble-multipath] Could not lock storage \"$storeid\" for multipath alias update;"
      . " proceeding unlocked: $err\n";
    return $code->();
  }
  return $res;
}

# multipathd reconfigure re-reads config and re-checks every multipath map on the host (not just this
# plugin's), so only do it when the alias set actually changes rather than on every map_volume/free_image.
sub nimble_multipath_register {
  my ( $storeid, $volname, $wwid ) = @_;
  return unless length($wwid) && length($volname) && length($storeid);
  my $sane_wwid = nimble_untaint_multipath_wwid($wwid);
  return unless length($sane_wwid);
  if ( nimble_multipath_wwid_in_main_conf($sane_wwid) ) {
    warn "Warning :: [nimble-multipath] WWID $sane_wwid ($volname) is already defined in"
      . " /etc/multipath.conf — skipping alias management. Remove that entry from"
      . " /etc/multipath.conf to enable plugin-managed aliases.\n";
    return;
  }
  nimble_multipath_with_storage_lock( $storeid, sub {
    my $cache = nimble_multipath_load_wwid_cache($storeid);
    return if ( $cache->{$volname} // '' ) eq $sane_wwid;
    $cache->{$volname} = $sane_wwid;
    nimble_multipath_save_wwid_cache( $storeid, $cache );
    my %aliases = nimble_multipath_build_aliases( $storeid, $cache );
    nimble_multipath_write_conf( $storeid, \%aliases );
    nimble_multipath_reconfigure();
  } );
}

sub nimble_multipath_deregister {
  my ( $storeid, $volname ) = @_;
  return unless length($volname) && length($storeid);
  nimble_multipath_with_storage_lock( $storeid, sub {
    my $cache = nimble_multipath_load_wwid_cache($storeid);
    return unless exists $cache->{$volname};
    delete $cache->{$volname};
    nimble_multipath_save_wwid_cache( $storeid, $cache );
    my %aliases = nimble_multipath_build_aliases( $storeid, $cache );
    nimble_multipath_write_conf( $storeid, \%aliases );
    nimble_multipath_reconfigure();
  } );
}

# rename_volume: cache keys (and thus aliases) are volname-based; move the entry or the old alias
# lingers forever — deregister at free_image only ever sees the new name.
sub nimble_multipath_rename_cache_entry {
  my ( $storeid, $old_volname, $new_volname ) = @_;
  return unless length($storeid) && length($old_volname) && length($new_volname);
  return if $old_volname eq $new_volname;
  nimble_multipath_with_storage_lock( $storeid, sub {
    my $cache = nimble_multipath_load_wwid_cache($storeid);
    return unless exists $cache->{$old_volname};
    $cache->{$new_volname} = delete $cache->{$old_volname};
    nimble_multipath_save_wwid_cache( $storeid, $cache );
    my %aliases = nimble_multipath_build_aliases( $storeid, $cache );
    nimble_multipath_write_conf( $storeid, \%aliases );
    nimble_multipath_reconfigure();
  } );
}

sub nimble_multipath_restore_aliases {
  my ($storeid) = @_;
  my $cache = nimble_multipath_load_wwid_cache($storeid);
  return unless keys %$cache;
  my %aliases = nimble_multipath_build_aliases( $storeid, $cache );
  return unless keys %aliases;
  nimble_multipath_write_conf( $storeid, \%aliases );
  nimble_multipath_reconfigure();
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
  my $addr = $scfg->{ nimble_address } or die "Error :: nimble_address not set\n";
  $addr =~ s/^https?:\/\///;
  $addr =~ s/\/.*$//;
  my $port = $scfg->{ port } // $default_port;
  # Strip an explicit :port only where the colon can't be part of the host itself: bracketed IPv6
  # ("[fd00::1]:5392") or hostname/IPv4. A bare-colon suffix on an unbracketed IPv6 literal is a
  # hextet, not a port — "fd00::5392" must not lose its tail.
  if ( $addr =~ /^\[(.+)\](?::\d+)?$/ ) {
    return "https://[$1]:${port}";
  }
  if ( $addr =~ /:/ && $addr !~ /^[^:]+:\d+$/ ) {
    # Unbracketed IPv6 literal (multiple colons, or single colon not followed by digits-only)
    return "https://[${addr}]:${port}";
  }
  $addr =~ s/:\d+$//;
  return "https://${addr}:${port}";
}

sub nimble_api_call {
  my ( $scfg, $method, $path, $body, $storeid, $is_retry ) = @_;
  $is_retry //= 0;
  my $eff_sid    = nimble_effective_storeid( $scfg, $storeid );
  my $base       = nimble_base_url( $scfg );
  my $url        = $base . '/' . $NIMBLE_API_VERSION . '/' . $path;
  my $cache_path = ( defined $eff_sid && $eff_sid ne '' ) ? get_token_cache_path( $eff_sid ) : undef;
  my $ttl        = $scfg->{ nimble_token_ttl } // 3600;

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
    $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 ) unless $scfg->{ nimble_check_ssl };
    my $req = HTTP::Request->new( 'POST', $login_url );
    $req->header( 'Content-Type' => 'application/json' );
    # HPE Perl sample: request body is { "data": { "username", "password" } }; response has session_token under "data"
    my ( $api_user, $api_pass ) = nimble_api_credentials( $scfg, $eff_sid );
    $req->content( encode_json( { data => { username => $api_user, password => $api_pass } } ) );
    my $res = $ua->request( $req );
    die "Error :: Nimble login failed: " . $res->status_line . "\n" . ( $res->decoded_content // '' ) . "\n" unless $res->is_success;
    my $login_body = $res->decoded_content // '';
    my $data;
    eval { $data = decode_json( $login_body ); };
    die "Error :: Nimble login response is not valid JSON: $@\nBody: " . substr( $login_body, 0, 256 ) . "\n" if $@;
    $auth = ( $data->{ data } && $data->{ data }->{ session_token } ) ? $data->{ data }->{ session_token } : $data->{ session_token };
    $auth or die "Error :: No session_token in response\n";
    $scfg->{ _auth_token } = $auth;
    my $token_data = { session_token => $auth, created_at => time(), ttl => $ttl };
    write_token_cache( $cache_path, $token_data ) if $cache_path;
  }

  my $ua = LWP::UserAgent->new( timeout => 30 );
  $ua->ssl_opts( verify_hostname => 0, SSL_verify_mode => 0x00 ) unless $scfg->{ nimble_check_ssl };
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
      return nimble_api_call( $scfg, $method, $path, $body, $eff_sid, 1 );
    }
    die "Error :: Nimble API $method $path: " . $res->status_line . "\n" . ( $content // '' ) . "\n";
  }
  if ( !length( $content ) ) {
    return {};
  }
  my $decoded;
  eval { $decoded = decode_json( $content ); };
  die "Error :: Nimble API $method $path response is not valid JSON: $@\nBody: " . substr( $content, 0, 256 ) . "\n" if $@;
  return $decoded;
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

# Some firmware omits vol_name (and sometimes vol_id) on snapshots returned from GET snapshots?vol_id=…
sub nimble_snapshot_effective_vol_name {
  my ( $s, $implicit_full_vol_name ) = @_;
  for my $k (qw( vol_name volume_name )) {
    my $v = $s->{ $k };
    return $v if defined $v && length( $v );
  }
  return $implicit_full_vol_name if defined $implicit_full_vol_name && length( $implicit_full_vol_name );
  return '';
}

# Parse API scalar to epoch for display/matching; returns undef if not a plausible calendar time.
sub nimble_parse_scalar_to_epoch {
  my ($t) = @_;
  return undef unless defined $t;
  return undef if ref($t);
  if ( looks_like_number($t) ) {
    my $ti = int( 0 + $t );
    # Milliseconds since epoch (common in JSON)
    $ti = int( $ti / 1000 ) if $ti > 10_000_000_000;
    return $ti if $ti >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH;
    return undef;
  }
  # ISO-8601-style: Z = UTC; offset like +00:00 treated as UTC when hour and minute are 0
  if ( $t =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2}(?::\d{2})?)?$/ ) {
    my ( $Y, $Mo, $D, $h, $mi, $sec, $zone ) = ( $1, $2, $3, $4, $5, $6, $7 );
    eval {
      require Time::Local;
      my $utc = ( defined $zone && ( $zone eq 'Z' || $zone =~ /^[+]00:?00/ ) );
      my $epoch = $utc ? Time::Local::timegm( $sec, $mi, $h, $D, $Mo - 1, $Y - 1900 )
        : Time::Local::timelocal( $sec, $mi, $h, $D, $Mo - 1, $Y - 1900 );
      return $epoch if defined $epoch && $epoch >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH;
    };
  }
  return undef;
}

# Unix epoch for PVE storage **ctime** (VM Disks Date column): prefers creation_time, else last_modified.
sub nimble_volume_row_ctime_epoch {
  my ($v) = @_;
  return 0 unless ref($v) eq 'HASH';
  for my $k (qw( creation_time last_modified )) {
    next unless defined $v->{ $k };
    my $e = nimble_parse_scalar_to_epoch( $v->{ $k } );
    return $e if defined $e;
  }
  return 0;
}

sub nimble_epoch_from_snapshot_name {
  my ($n) = @_;
  $n //= '';
  # Nimble GUI style: NSs-<vol>-YYYY-MM-DD::HH:MM:SS.mmm
  if ( $n =~ /^NSs-.+-(\d{4})-(\d{2})-(\d{2})::(\d{2}):(\d{2}):(\d{2})/ ) {
    my ( $Y, $Mo, $D, $h, $mi, $sec ) = ( $1, $2, $3, $4, $5, $6 );
    eval {
      require Time::Local;
      my $epoch = Time::Local::timelocal( $sec, $mi, $h, $D, $Mo - 1, $Y - 1900 );
      return $epoch if defined $epoch && $epoch >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH;
    };
  }
  # Volume-collection / schedule style: ...-YYYY-MM-DD::HH:MM:SS[.fff] (e.g. test-collection-Schedule-new-2026-04-14::21:10:00.000)
  if ( $n =~ /-(\d{4})-(\d{2})-(\d{2})::(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?/ ) {
    my ( $Y, $Mo, $D, $h, $mi, $sec ) = ( $1, $2, $3, $4, $5, $6 );
    eval {
      require Time::Local;
      my $epoch = Time::Local::timelocal( $sec, $mi, $h, $D, $Mo - 1, $Y - 1900 );
      return $epoch if defined $epoch && $epoch >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH;
    };
  }
  return undef;
}

# Real epoch for PVE snaptime / UI when the array omits time fields; undef => unknown (do not use id-hash).
sub nimble_snapshot_display_epoch {
  my ($s) = @_;
  return undef unless $s && ref($s) eq 'HASH';
  for my $k (qw( creation_time snapshot_creation_time last_modified created_at ctime )) {
    my $e = nimble_parse_scalar_to_epoch( $s->{ $k } );
    return $e if defined $e;
  }
  return nimble_epoch_from_snapshot_name( $s->{ name } );
}

# Extract one snapshot object from GET snapshots/:id or snapshots?id= (data may be object or single-element array).
sub nimble_snapshot_detail_data_row {
  my ($r) = @_;
  return undef unless $r && ref($r) eq 'HASH';
  my $d = $r->{ data };
  return $d if ref($d) eq 'HASH' && ( defined $d->{ id } || defined $d->{ name } );
  if ( ref($d) eq 'ARRAY' && @$d && ref( $d->[0] ) eq 'HASH' ) {
    my $z = $d->[0];
    return $z if defined $z->{ id } || defined $z->{ name };
  }
  return undef;
}

# Merge API fields without clobbering with JSON null (undef): plain %a = (%a,%b) would wipe creation_time from a follow-up response that omits it.
sub nimble_merge_snapshot_hash_skip_undef {
  my ( $s, $h ) = @_;
  return 0 unless $s && ref($s) eq 'HASH' && $h && ref($h) eq 'HASH';
  for my $k ( keys %$h ) {
    my $v = $h->{ $k };
    next unless defined $v;
    next if $v eq '' && $k eq 'snap_collection_id';
    $s->{ $k } = $v;
  }
  return nimble_snapshot_display_epoch($s) ? 1 : 0;
}

# List GET snapshots may omit times. HPE documents snapshots as "volumes" — GET volumes/:id often returns creation_time when snapshots/:id does not.
# Scheduled snaps may carry snap_collection_id; GET snapshot_collections/:id has creation_time for the collection (Python SDK).
sub nimble_hydrate_snapshot_detail {
  my ( $scfg, $storeid, $s, $coll_cache ) = @_;
  return 0 unless $s && ref($s) eq 'HASH';
  my $id = $s->{ id };
  return 0 unless defined $id && length $id;
  return 1
    if nimble_snapshot_display_epoch($s) && defined nimble_snapshot_virtual_size_bytes($s);
  $coll_cache = {} if !$coll_cache || ref($coll_cache) ne 'HASH';

  my $try_merge_response = sub {
    my ($r) = @_;
    my $row = nimble_snapshot_detail_data_row($r);
    return 0 unless $row;
    return nimble_merge_snapshot_hash_skip_undef( $s, $row );
  };

  my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots/$id", undef, $storeid ) };
  return 1 if $r && $try_merge_response->($r);

  my $enc = uri_escape($id);
  $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?id=$enc", undef, $storeid ) };
  return 1 if $r && $try_merge_response->($r);

  $r = eval { nimble_api_call( $scfg, 'GET', "volumes/$id", undef, $storeid ) };
  return 1 if $r && $try_merge_response->($r);

  my $scid = $s->{ snap_collection_id } // '';
  if ( length $scid && !nimble_snapshot_display_epoch($s) ) {
    if ( !exists $coll_cache->{ $scid } ) {
      my $cr = eval { nimble_api_call( $scfg, 'GET', "snapshot_collections/$scid", undef, $storeid ) };
      if ( $cr && ref( $cr->{ data } ) eq 'HASH' ) {
        $coll_cache->{ $scid } = $cr->{ data };
      }
      else {
        my $sce = uri_escape($scid);
        $cr = eval { nimble_api_call( $scfg, 'GET', "snapshot_collections?id=$sce", undef, $storeid ) };
        if ( $cr && ref( $cr->{ data } ) eq 'HASH' ) {
          $coll_cache->{ $scid } = $cr->{ data };
        }
        elsif ( $cr && ref( $cr->{ data } ) eq 'ARRAY' && @{ $cr->{ data } } && ref( $cr->{ data }[0] ) eq 'HASH' ) {
          $coll_cache->{ $scid } = $cr->{ data }[0];
        }
        else {
          $coll_cache->{ $scid } = {};
        }
      }
    }
    my $c = $coll_cache->{ $scid };
    if ( ref($c) eq 'HASH' && keys %$c ) {
      for my $k (qw( creation_time last_modified )) {
        $s->{ $k } //= $c->{ $k } if defined $c->{ $k };
      }
      return 1 if nimble_snapshot_display_epoch($s);
    }
  }

  return nimble_snapshot_display_epoch($s) ? 1 : 0;
}

sub nimble_hydrate_snapshots_missing_display_time {
  my ( $scfg, $storeid, $snaps ) = @_;
  return unless ref($snaps) eq 'ARRAY';
  my %did;
  my %coll_cache;
  for my $s ( @$snaps ) {
    next unless ref($s) eq 'HASH' && $s->{ id };
    next if $did{ $s->{ id } }++;
    next if nimble_snapshot_display_epoch($s);
    eval { nimble_hydrate_snapshot_detail( $scfg, $storeid, $s, \%coll_cache ); 1 } or undef;
  }
}

# creation_time may be null on filtered snapshot lists; use last_modified, NSs-* name timestamp, or stable id hash.
sub nimble_snapshot_effective_creation_time {
  my ($s) = @_;
  for my $k (qw( creation_time snapshot_creation_time )) {
    my $e = nimble_parse_scalar_to_epoch( $s->{ $k } );
    return $e if defined $e;
  }
  my $e = nimble_parse_scalar_to_epoch( $s->{ last_modified } );
  return $e if defined $e;
  $e = nimble_epoch_from_snapshot_name( $s->{ name } // '' );
  return $e if defined $e;
  my $id = $s->{ id } // '';
  my $h  = 0;
  $h = ( ( $h << 5 ) - $h + ord($_) ) & 0x7FFFFFFF for split //, $id;
  return $h > 0 ? $h : 1;
}

# Distance for choosing the best row for PVE name nimble<digits>: ±60s for real epochs, else exact id-hash or raw API int.
sub nimble_snapshot_time_distance_for_nimble_suffix {
  my ( $s, $target_ts ) = @_;
  return undef unless $s && ref( $s ) eq 'HASH';
  my $eff = nimble_snapshot_effective_creation_time($s);
  if ( $target_ts >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH ) {
    my $d = abs( $eff - $target_ts );
    return $d <= 60 ? $d : undef;
  }
  return 0 if $eff == $target_ts;
  for my $k (qw( creation_time snapshot_creation_time last_modified )) {
    my $t = $s->{ $k };
    next unless defined $t && !ref($t) && looks_like_number($t);
    my $ti = int( 0 + $t );
    $ti = int( $ti / 1000 ) if $ti > 10_000_000_000;
    return 0 if $ti == $target_ts;
  }
  return undef;
}

# When the list was fetched with ?vol_id=, rows may omit vol_id; do not drop those rows.
sub nimble_snapshot_row_volume_id_mismatch {
  my ( $s, $expected_vid ) = @_;
  my $got = $s->{ vol_id };
  return 0 unless defined $got && length( $got );
  return $got ne $expected_vid;
}

# PVE snaptime stored in qemu conf for array-imported nimble<digits> keys (may differ from suffix when
# suffix used min effective time but snaptime used min display epoch across disks).
sub nimble_vm_snaptime_from_qemu_conf {
  my ( $volname, $snap_key ) = @_;
  return undef unless defined $volname && $volname =~ /^vm-(\d+)-/;
  my $vmid = $1;
  eval { require PVE::QemuConfig; 1 } or return undef;
  my $conf = eval { PVE::QemuConfig->load_config( $vmid ) };
  return undef unless $conf && ref( $conf->{ snapshots } ) eq 'HASH';
  my $e = $conf->{ snapshots }{ $snap_key };
  return undef unless $e && ref($e) eq 'HASH';
  my $st = $e->{ snaptime };
  return undef unless defined $st;
  my $i = int( 0 + $st );
  return $i >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH ? $i : undef;
}

# Hydrate list rows then pick best snapshot for rollback/delete matching nimble<target_ts> (same as sync after hydration).
sub nimble_best_snapshot_row_for_nimble_target_ts {
  my ( $scfg, $storeid, $vol_id, $target_ts, $list ) = @_;
  return ( undef, 1e30 ) unless ref($list) eq 'ARRAY';
  nimble_hydrate_snapshots_missing_display_time( $scfg, $storeid, $list );
  my ( $best, $best_d ) = ( undef, 1e30 );
  for my $s ( @$list ) {
    next if nimble_snapshot_row_volume_id_mismatch( $s, $vol_id );
    my $d = nimble_snapshot_time_distance_for_nimble_suffix( $s, $target_ts );
    next unless defined $d && $d < $best_d;
    $best_d = $d;
    $best   = $s;
  }
  return ( $best, $best_d );
}

# GET v1/pools list rows may omit capacity (summary-only). GET v1/pools/:id returns full pool (SDK: capacity, usage, free_space in bytes).

# storage.cfg nimble_pool_name may match pool name, search_name, or full_name; GET arrays rows often only have pool_id / pool_name.
sub nimble_pool_identifier_matches_want {
  my ( $row, $want ) = @_;
  return 1 if !defined $want || $want eq '';
  return 0 unless $row && ref($row) eq 'HASH';
  return 1
    if ( $row->{ name } // '' ) eq $want
    || ( $row->{ search_name } // '' ) eq $want
    || ( $row->{ full_name } // '' ) eq $want
    # pool_name: on pool rows the pool's own name is `name`; `pool_name` appears on array/volume-style rows — included so one helper serves both.
    || ( $row->{ pool_name } // '' ) eq $want;
  return 0;
}

# Include an array in status fallback when pool_name is set: match identifier on the array row, or link via pool_id / pool_name to pools in @use.
sub nimble_array_matches_status_pools {
  my ( $a, $want, $use_pools ) = @_;
  return 1 if !defined $want || $want eq '';
  return 0 unless ref($a) eq 'HASH';
  return 1 if nimble_pool_identifier_matches_want( $a, $want );
  return 0 unless ref($use_pools) eq 'ARRAY' && @$use_pools;
  my $apid = $a->{ pool_id } // '';
  if ( $apid ne '' ) {
    for my $p ( @$use_pools ) {
      next unless ref($p) eq 'HASH';
      my $pid = $p->{ id } // '';
      return 1 if $pid ne '' && $apid eq $pid;
    }
  }
  my $pn = $a->{ pool_name } // '';
  if ( $pn ne '' ) {
    for my $p ( @$use_pools ) {
      next unless ref($p) eq 'HASH';
      return 1 if $pn eq ( $p->{ name } // '' )
        || $pn eq ( $p->{ search_name } // '' )
        || $pn eq ( $p->{ full_name } // '' );
    }
  }
  return 0;
}

sub nimble_pool_usage_bytes {
  my ($p) = @_;
  return 0 unless $p && ref($p) eq 'HASH';
  my $u = $p->{usage};
  if ( ref($u) eq 'HASH' ) {
    return 0 + ( $u->{ compressed_usage } // $u->{ uncompressed_usage } // 0 );
  }
  return 0 + ( $u // 0 );
}

sub nimble_pool_capacity_bytes {
  my ($p) = @_;
  return 0 unless $p && ref($p) eq 'HASH';
  my $c = 0 + ( $p->{ capacity } // 0 );
  return $c if $c > 0;
  my $free = 0 + ( $p->{ free_space } // 0 );
  my $used = nimble_pool_usage_bytes($p);
  my $sum = $free + $used;
  # Known limitation: if API omits capacity and only uncompressed_usage is present, free_space (physical) + uncompressed (logical) can overstate physical total vs compression.
  return $sum if $sum > 0;
  return 0;
}

# Identity string for one GET arrays row (API id preferred, else array name / serial).
sub nimble_array_identity_from_row {
  my ($a) = @_;
  return undef unless ref($a) eq 'HASH';
  my $id = $a->{ id } // '';
  return "nimble:$id" if length($id);
  my $serial = $a->{ array_name } // $a->{ name } // $a->{ serial_number } // '';
  return "nimble:$serial" if length($serial);
  return undef;
}

sub nimble_pool_used_bytes {
  my ($p) = @_;
  return 0 unless $p && ref($p) eq 'HASH';
  if ( $p->{ usage_valid } ) {
    my $u = nimble_pool_usage_bytes($p);
    return $u if $u > 0;
    return 0;    # honour API: empty pool with valid zero usage (do not derive from cap - free_space)
  }
  my $cap = nimble_pool_capacity_bytes($p);
  my $free = 0 + ( $p->{ free_space } // 0 );
  if ( $cap > 0 && $free >= 0 && $free <= $cap ) {
    return $cap - $free;
  }
  # usage_valid false and cap/free_space path unavailable
  return nimble_pool_usage_bytes($p);
}

sub nimble_hydrate_pool_for_capacity {
  my ( $scfg, $storeid, $p ) = @_;
  return unless ref($p) eq 'HASH' && $p->{ id };
  return if nimble_pool_capacity_bytes($p) > 0;
  my $r = eval { nimble_api_call( $scfg, 'GET', "pools/$p->{id}", undef, $storeid ) };
  return unless $r && ref( $r->{ data } ) eq 'HASH';
  %$p = ( %$p, %{ $r->{ data } } );
}

# When pool list/detail still yield no capacity (some firmware/API paths), sum array usable capacity for the group (optional pool_name filter vs @use_pools).
sub nimble_status_arrays_fallback_bytes {
  my ( $scfg, $storeid, $pool_name, $use_pools ) = @_;
  my $r = eval { nimble_api_call( $scfg, 'GET', 'arrays', undef, $storeid ) };
  return ( 0, 0 ) unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  my ( $total, $used ) = ( 0, 0 );
  for my $a ( @$list ) {
    next unless ref($a) eq 'HASH';
    if ( defined $pool_name && $pool_name ne '' ) {
      next unless nimble_array_matches_status_pools( $a, $pool_name, $use_pools );
    }
    my $ua = 0 + ( $a->{ usable_capacity_bytes } // 0 );
    $total += $ua;
    next if $ua <= 0;
    my $avail = 0 + ( $a->{ available_bytes } // 0 );
    my $u = 0;
    if ( $a->{ usage_valid } ) {
      $u = nimble_pool_usage_bytes($a);
    }
    if ( $u <= 0 && ( ( $a->{ vol_usage_bytes } // 0 ) + ( $a->{ snap_usage_bytes } // 0 ) ) > 0 ) {
      $u = 0 + ( $a->{ vol_usage_bytes } // 0 ) + ( $a->{ snap_usage_bytes } // 0 );
    }
    if ( $u <= 0 && $avail >= 0 && $avail <= $ua ) {
      $u = $ua - $avail;
    }
    $used += $u if $u > 0;
  }
  return ( $total, $used );
}

# GET subnets/:id returns full subnet (type, discovery_ip, etc.). Always merge into list rows so discovery
# uses the same fields the API documents—no reliance on list view being summary or full.
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
    my $full = eval { nimble_fetch_subnet_by_id( $scfg, $storeid, $id ) };
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
  my $s = $scfg->{ nimble_iscsi_discovery_ips };
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

# Last-resort supplement only: IPs from existing tcp sessions on this host. Subnets API order is authoritative
# in get_nimble_iscsi_discovery_ips (API first, then this). Not a substitute for GET subnets + subnets/:id.
sub get_iscsi_discovery_ips_from_running_sessions {
  my @ips;
  my %seen;
  my $iscsiadm = '/usr/sbin/iscsiadm';
  $iscsiadm = '/sbin/iscsiadm' if !-x $iscsiadm;
  return () unless -x $iscsiadm;
  my $out = '';
  eval {
    run_command( [ $iscsiadm, '-m', 'session' ],
      outfunc => sub { $out .= shift . "\n" },
      errfunc => sub { },
      timeout => 15,
      quiet   => 1
    );
  };
  while ( $out =~ /^\s*tcp:\s*\[\d+\]\s+(\d{1,3}(?:\.\d{1,3}){3}):(\d+)/gm ) {
    my $host = $1;
    push @ips, $host if !$seen{$host}++;
  }
  return @ips;
}

### Discovery IPs: nimble_iscsi_discovery_ips (static override), else GET subnets + GET network_interfaces + session supplement.
sub get_nimble_iscsi_discovery_ips {
  my ( $scfg, $storeid ) = @_;

  # Static override: if the user set nimble_iscsi_discovery_ips, use ONLY those IPs.
  # Skip the Nimble subnets/network_interfaces API entirely so unreachable API subnets
  # (wrong VLAN, firewall, separate management network) never cause sendtargets timeouts.
  my @manual = nimble_parse_manual_discovery_ips($scfg);
  if ( @manual ) {
    print "Debug :: Using static discovery IPs (nimble_iscsi_discovery_ips), skipping Nimble subnets API: @manual\n"
      if $DEBUG >= 1;
    return @manual;
  }

  # --- Dynamic path: query the Nimble API for discovery IPs ---
  my @session_supplement = get_iscsi_discovery_ips_from_running_sessions();
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
          next unless defined $ip;
          $ip =~ s/^\s+|\s+$//g;
          next if $ip eq '';
          next unless $ip =~ m/^\S+$/ && length($ip) <= 253 && !$seen{$ip}++;
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
  my $from_api_or_manual = @ips;
  my %seen_ord;
  my @merged;
  for my $p ( @ips ) {
    next unless defined $p && $p =~ m/^\S+$/ && length($p) <= 253;
    push @merged, $p if !$seen_ord{$p}++;
  }
  # Session-derived IPs are portals of EVERY iSCSI session on this host — including other vendors'
  # arrays managed by other plugins. Only fall back to them when the Nimble API and manual config
  # produced nothing; merging them unconditionally would aim sendtargets at foreign arrays.
  if ( !$from_api_or_manual ) {
    for my $p ( @session_supplement ) {
      next unless defined $p && $p =~ m/^\S+$/ && length($p) <= 253;
      push @merged, $p if !$seen_ord{$p}++;
    }
    if ( $DEBUG >= 1 && @session_supplement ) {
      print "Debug :: No discovery IPs from subnets/API fallbacks; using active session portal IP(s): @merged\n";
    }
  }
  return @merged;
}

# open-iscsi stores node.portal as "host:port" or "host:port,tpgt". Strip ",N" so discovery/login -p matches.
sub nimble_iscsi_portal_strip_tpgt {
  my ($p) = @_;
  return '' if !defined $p;
  my $s = $p;
  $s =~ s/,[0-9]+\z//;
  return $s;
}

sub nimble_iscsi_portal {
  my ($ip) = @_;
  return '' if !defined $ip || $ip !~ m/\S/;
  my $s = nimble_iscsi_portal_strip_tpgt($ip);
  return $s if $s =~ /:\d+$/;
  return $s if $s =~ /^\[.+\]:\d+$/;
  # Unbracketed IPv6: open-iscsi expects -p [addr]:3260
  if ( $s =~ /:/ && $s !~ /^\d+\.\d+\.\d+\.\d+$/ ) {
    return "[$s]:3260";
  }
  return "$s:3260";
}

# Portals in the open-iscsi node DB for $target_iqn (populated by sendtargets).
# Uses array accumulation in outfunc — PVE run_command calls outfunc per line WITHOUT
# newlines, so string-concat + split-on-newline loses all but the first line.
sub nimble_iscsi_node_portals_for_target {
  my ($target_iqn) = @_;
  my $iqn = nimble_untaint_iscsiadm_scalar($target_iqn);
  return () if !length($iqn) || $iqn !~ m/^iqn\./i;
  my $iscsiadm = nimble_iscsiadm_path();
  return () unless -x $iscsiadm;
  my @lines;
  eval {
    run_command(
      [ $iscsiadm, '-m', 'node', '--targetname', $iqn ],
      outfunc => sub { push @lines, shift },    # one element per line
      errfunc => sub { },
      timeout => 25,
      quiet   => 1
    );
  };
  my %seen;
  my @out;
  for my $line ( @lines ) {
    # Short-list format: "10.1.1.1:3260,1 iqn.xxx"
    next unless $line =~ m/^\s*(\S+)\s+iqn\./i;
    my $portal = $1;
    $portal =~ s/,[0-9]+\z//;    # strip TPGT (",1")
    push @out, $portal unless $seen{$portal}++;
  }
  return @out;
}

# Login failures when the target is already up (e.g. open-iscsi exit 15).
sub nimble_iscsi_login_err_is_benign {
  my ($e) = @_;
  return 0 if !defined $e || $e eq '';
  my $m = nimble_iscsi_sanitize_cmd_err($e);
  return 1 if $m =~ /already\s+(?:exist|logged|established)/i;
  return 1 if $m =~ /\bexit\s+code\s+15\b/i;
  return 1 if $m =~ /\bcode\s+15\b/i;
  return 0;
}

# Raw stdout from `iscsiadm -m session` (one string; lines have no trailing newlines from run_command).
sub nimble_iscsi_session_output {
  my $iscsiadm = nimble_iscsiadm_path();
  return '' unless -x $iscsiadm;
  my $out = '';
  eval {
    run_command(
      [ $iscsiadm, '-m', 'session' ],
      outfunc => sub { $out .= shift . "\n" },
      errfunc => sub { },
      timeout => 15,
      quiet   => 1
    );
  };
  return $out;
}

# True when an active session exists for this IQN on this specific portal (multipath: each path separately).
sub nimble_iscsi_portal_in_sessions {
  my ( $target_iqn, $portal, $extra_tries, $session_out ) = @_;
  return 0 if !length($target_iqn) || !length($portal);
  $extra_tries //= 0;
  $extra_tries = 0 if $extra_tries < 0;
  my $iqn_safe = nimble_untaint_iscsiadm_scalar($target_iqn);
  my $portal_safe = nimble_untaint_iscsiadm_scalar($portal);
  return 0 unless length($iqn_safe) && length($portal_safe);
  my $iqn_needle  = nimble_iscsi_compact_lc($iqn_safe);
  my $portal_base = nimble_iscsi_portal_strip_tpgt($portal_safe);
  my $portal_needle = nimble_iscsi_compact_lc($portal_base);
  return 0 unless length($portal_needle);
  my $attempts = 1 + $extra_tries;
  for my $i ( 1 .. $attempts ) {
    my $out = defined($session_out) ? $session_out : nimble_iscsi_session_output();
    if ( length $out ) {
      for my $line ( split /\n/, $out ) {
        my $lc = nimble_iscsi_compact_lc($line);
        next unless index( $lc, $iqn_needle ) >= 0;
        return 1 if index( $lc, $portal_needle ) >= 0;
      }
    }
    select( undef, undef, undef, 0.5 ) if $i < $attempts;
    $session_out = undef;
  }
  return 0;
}

# True when every listed portal has an active session for this IQN (multipath-ready).
sub nimble_iscsi_all_portals_in_sessions {
  my ( $target_iqn, $portals_ref, $extra_tries ) = @_;
  return 0 unless ref($portals_ref) eq 'ARRAY' && @$portals_ref;
  my $session_out = nimble_iscsi_session_output();
  for my $portal (@$portals_ref) {
    return 0 unless nimble_iscsi_portal_in_sessions( $target_iqn, $portal, $extra_tries, $session_out );
  }
  return 1;
}

# Login one node DB record; skip only when this IQN is already logged in on this portal (Pure-style per-path).
sub nimble_iscsi_node_login_if_needed {
  my ( $iqn, $portal ) = @_;
  $iqn    = nimble_untaint_iscsiadm_scalar($iqn);
  $portal = nimble_untaint_iscsiadm_scalar($portal);
  return 1 unless length($iqn) && $iqn =~ m/^iqn\./i && length($portal);
  return 1 if nimble_iscsi_portal_in_sessions( $iqn, $portal, 0 );
  my $iscsiadm = nimble_iscsiadm_path();
  return 0 unless -x $iscsiadm;
  nimble_iscsi_node_set_startup_automatic( $iqn, $portal );
  eval {
    run_command(
      [ $iscsiadm, '-m', 'node', '-T', $iqn, '-p', $portal, '--login' ],
      timeout => 45,
      quiet   => 1
    );
  };
  if ( $@ && !nimble_iscsi_login_err_is_benign($@) ) {
    chomp( my $e = $@ );
    print "Debug :: iscsi login $iqn @ $portal: $e\n" if $DEBUG >= 1;
  }
  return nimble_iscsi_portal_in_sessions( $iqn, $portal, 4 );
}

# API/subnet/manual IPs plus any node.portal lines for this IQN (multipath needs every path logged in).
sub nimble_iscsiadm_path {
  my $iscsiadm = '/usr/sbin/iscsiadm';
  return -x $iscsiadm ? $iscsiadm : '/sbin/iscsiadm';
}

sub nimble_iscsi_compact_lc {
  my ($s) = @_;
  return '' unless defined $s;
  my $t = lc($s);
  $t =~ s/\s+//g;
  return $t;
}

# True if an active session exists for this IQN. Uses only `iscsiadm -m session` and matches the IQN in
# output (compact + plain). Do not use `-m session -T <iqn>`: on common open-iscsi builds `-T`/`--targetname`
# is for **node** mode, not session mode, and produces "option '-' is not allowed/supported" spam.
# $extra_tries: extra polls (0.5s apart) after the first miss (post-login race).
sub nimble_iscsi_target_in_sessions {
  my ( $target_iqn, $extra_tries ) = @_;
  return 0 if !length($target_iqn);
  $extra_tries //= 0;
  my $iqn_safe = nimble_untaint_iscsiadm_scalar($target_iqn);
  return 0 unless length $iqn_safe;
  my $needle_compact = nimble_iscsi_compact_lc($iqn_safe);
  $extra_tries = 0 if $extra_tries < 0;
  my $attempts = 1 + $extra_tries;
  for my $i ( 1 .. $attempts ) {
    my $out = nimble_iscsi_session_output();
    if ( length $out ) {
      return 1 if index( nimble_iscsi_compact_lc($out), $needle_compact ) >= 0;
      return 1 if index( lc($out), lc($iqn_safe) ) >= 0;
    }
    select( undef, undef, undef, 0.5 ) if $i < $attempts;
  }
  return 0;
}

# One sendtargets pass per host (quiet); returns the (portal, iqn) records this array itself just
# reported on each queried IP. Callers must use these records directly (not a scan of the host's whole
# iscsiadm node database, which can also hold records for other storage plugins or manually managed
# targets) so login / node.startup changes only ever touch targets that belong to this array.
# Caller then runs targeted --login; do not mix with global `node --login` on map.
sub iscsi_sendtargets_on_ips {
  my ($ips_ref) = @_;
  return () unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  return () unless -x $iscsiadm;
  my %seen;
  my @recs;
  for my $ip ( @$ips_ref ) {
    next unless defined $ip && $ip =~ m/^\S+$/ && length($ip) <= 253;
    my $disc_ip = nimble_untaint_iscsiadm_scalar($ip);
    next unless length $disc_ip;
    my @lines;
    eval {
      run_command(
        [ $iscsiadm, '-m', 'discovery', '-t', 'sendtargets', '-p', $disc_ip ],
        outfunc => sub { push @lines, shift },
        errfunc => sub { },
        timeout => 20,
        quiet   => 1
      );
    };
    if ( $@ ) {
      chomp( my $e = $@ );
      print "Debug :: sendtargets -p $disc_ip: $e\n" if $DEBUG >= 1;
      next;
    }
    for my $line (@lines) {
      next unless $line =~ m/^\s*(\S+)\s+(iqn\S+)/i;
      my $portal = $1;
      my $iqn    = $2;
      $portal =~ s/,[0-9]+\z//;
      $iqn = nimble_untaint_iscsiadm_scalar($iqn);
      next unless length($iqn) && $iqn =~ m/^iqn\./i;
      $portal = nimble_untaint_iscsiadm_scalar($portal);
      next unless length($portal);
      my $key = "$iqn|$portal";
      push @recs, { iqn => $iqn, portal => $portal } unless $seen{$key}++;
    }
  }
  return @recs;
}

# Login to target on all node records (open-iscsi), when portals are unknown but discovery already ran elsewhere.
# Collapse multi-line command errors into one line for task/syslog (avoid huge dumps).
sub nimble_iscsi_sanitize_cmd_err {
  my ($e) = @_;
  return '' if !defined $e;
  chomp $e;
  $e =~ s/\s+/ /g;
  return '' if $e eq '';
  return substr( $e, 0, 280 ) if length($e) > 280;
  return $e;
}

# Same as PVE Datacenter → Add → iSCSI: "Enabled" (persist login across reboots) for this target+portal.
sub nimble_iscsi_node_set_startup_automatic {
  my ( $target_iqn, $portal ) = @_;
  my $iqn = nimble_untaint_iscsiadm_scalar($target_iqn);
  my $p   = nimble_untaint_iscsiadm_scalar($portal);
  return unless length($iqn) && length($p);
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  eval {
    run_command(
      [
        $iscsiadm, '-m', 'node', '-T', $iqn, '-p', $p,
        '--op', 'update', '-n', 'node.startup', '-v', 'automatic',
      ],
      timeout => 10,
      quiet   => 1
    );
  };
}

# After iscsi_sendtargets_on_ips: login this volume IQN on each portal (no per-IP rediscovery; no global node --login).
# Mirrors manual PVE iSCSI: portal + per-volume Nimble IQN + "Use LUNs directly" (Nimble exposes LUN 0 on that IQN).
# $volume_serial_opt: when set and the block device is already visible by API serial, skip the "no session" warning
# (session listing can false-negative; the serial path is the ground truth we already have from the API).
sub nimble_iscsi_login_target_on_portals {
  my ( $storeid, $target_iqn, $ips_ref, $suppress_no_session_warn, $volume_serial_opt ) = @_;
  my $iqn = nimble_untaint_iscsiadm_scalar($target_iqn);
  return unless length($iqn) && $iqn =~ m/^iqn\./i;
  return unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  return unless -x $iscsiadm;
  my @tried_portals;
  my $last_login_err = '';
  for my $ip ( @$ips_ref ) {
    next unless defined $ip && $ip =~ m/^\S+$/;
    my $portal = nimble_untaint_iscsiadm_scalar( nimble_iscsi_portal($ip) );
    next unless length $portal;
    push @tried_portals, $portal;
    next if nimble_iscsi_node_login_if_needed( $iqn, $portal );
    $last_login_err = 'login did not establish session';
  }
  my $device_already = 0;
  if ( defined $volume_serial_opt && length $volume_serial_opt ) {
    my ( $p, $w ) = get_device_path_by_serial($volume_serial_opt);
    $device_already = 1 if length($p) && -b $p;
  }
  if ( !nimble_iscsi_target_in_sessions( $iqn, 12 ) && !$suppress_no_session_warn && !$device_already ) {
    my $portals_str = @tried_portals ? join( ', ', @tried_portals ) : '(none — check portal list / sendtargets)';
    my $errbit      = length($last_login_err) ? " Last iscsiadm error: $last_login_err." : '';
    my $serialbit   = ( defined $volume_serial_opt && length $volume_serial_opt )
      ? " API serial: $volume_serial_opt."
      : '';
    warn "Warning :: No iSCSI session detected for target \"$iqn\" after login attempts "
      . "(portals tried: $portals_str).$serialbit$errbit "
      . "If the disk still maps, this may be a false positive from session listing. "
      . "Otherwise verify ACL for this node's initiator group, L3 path to Nimble data portals (subnets discovery_ip), and open-iscsi.\n";
  }
}

# Best-effort logout for this volume's per-target IQN (mirrors portal loop used for login).
# Nimble returns 409 SM_vol_has_connections if PUT online=false while initiators are still connected.
sub nimble_iscsi_logout_volume_local {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $storeid );
  return 0 unless $volume && length( $volume->{ target_name } // '' );
  my $iqn = nimble_untaint_iscsiadm_scalar( $volume->{ target_name } );
  return 0 unless length($iqn) && $iqn =~ m/^iqn\./i;
  my $iscsiadm = nimble_iscsiadm_path();
  return 0 unless -x $iscsiadm;
  for my $portal ( nimble_iscsi_node_portals_for_target($iqn) ) {
    my $p = nimble_untaint_iscsiadm_scalar($portal);
    next unless length $p;
    eval {
      run_command(
        [ $iscsiadm, '-m', 'node', '-T', $iqn, '-p', $p, '--logout' ],
        timeout => 45,
        quiet   => 1
      );
    };
  }
  if ( nimble_iscsi_target_in_sessions( $iqn, 0 ) ) {
    eval {
      run_command( [ $iscsiadm, '-m', 'session', '-u', '-T', $iqn ], timeout => 45, quiet => 1 );
    };
  }
  return 1;
}

# Before PUT volumes/:id online=false (restore / strict offline): drop host mappings and array ACLs so
# no initiator has an active path (avoids SM_vol_has_connections). Re-ACL happens on next activate_volume.
sub nimble_volume_prepare_restore_disconnect {
  my ( $class, $scfg, $vol_id, $storeid, $volname ) = @_;
  return unless defined $vol_id && $vol_id ne '' && length($volname);
  eval { $class->unmap_volume( $storeid, $scfg, $volname, undef ); };
  eval { nimble_iscsi_logout_volume_local( $class, $scfg, $volname, $storeid ); };
  nimble_delete_access_control_records_for_volume_id( $scfg, $vol_id, $storeid );
}

# Nimble volume targets share the vendor IQN prefix (iqn.2007-11.com.nimblestorage:...). Baseline
# discovery must never log in to targets that are not Nimble's: a discovery portal can be (or answer
# for) a foreign array — e.g. a session-derived fallback IP that belongs to a Pure array — and its
# sendtargets response would list that vendor's targets. Substring match (not anchored prefix) so a
# firmware/rebrand prefix change (Alletra) that keeps "nimble" in the IQN does not silently break login.
sub nimble_iscsi_iqn_is_nimble_target {
  my ($iqn) = @_;
  return 0 unless defined $iqn && length $iqn;
  return $iqn =~ /nimble/i ? 1 : 0;
}

# Pure-style host iSCSI baseline (also on throttled status() refresh): sendtargets on discovery IPs,
# then login each (portal, iqn) record that sendtargets itself just reported for this array — not a scan
# of the host's whole iscsiadm node database, which may also hold records for other storage plugins or
# manually managed targets. Records are additionally filtered to Nimble vendor IQNs so a foreign portal
# in the IP list can never get its targets logged in or set to node.startup=automatic.
# No global `iscsiadm -m node --login` (exit 15 when some paths are already up, and no way to scope it
# to just this array's targets).
sub run_iscsi_discovery_and_login {
  my ( $storeid, $scfg, $ips_ref ) = @_;
  return unless ref($ips_ref) eq 'ARRAY' && @$ips_ref;
  my $iscsiadm = nimble_iscsiadm_path();
  if ( !-x $iscsiadm ) {
    warn "Warning :: iscsiadm not found or not executable; skipping auto iSCSI discovery for storage \"$storeid\".\n";
    return;
  }
  my @recs = grep { nimble_iscsi_iqn_is_nimble_target( $_->{ iqn } ) } iscsi_sendtargets_on_ips($ips_ref);
  if ( !@recs ) {
    print "Debug :: sendtargets on discovery IP(s) for \"$storeid\" reported no Nimble target records.\n"
      if $DEBUG >= 1;
    return;
  }
  my ( $logged, $skipped, $failed ) = ( 0, 0, 0 );
  for my $rec (@recs) {
    if ( nimble_iscsi_portal_in_sessions( $rec->{ iqn }, $rec->{ portal }, 0 ) ) {
      $skipped++;
      next;
    }
    if ( nimble_iscsi_node_login_if_needed( $rec->{ iqn }, $rec->{ portal } ) ) {
      $logged++;
    } else {
      $failed++;
    }
  }
  print "Debug :: iSCSI baseline for \"$storeid\": $skipped portal(s) already logged in, "
    . "$logged newly logged in, $failed failed.\n"
    if $DEBUG >= 1 && ( $logged || $failed );
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
  my $ig_name = $scfg->{ nimble_initiator_group };
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
  my $ig_name = $scfg->{ nimble_initiator_group };
  if ( defined $ig_name && $ig_name ne '' ) {
    my $id = nimble_get_initiator_group_id( $scfg, $ig_name, $storeid );
    if ( $DEBUG >= 1 ) {
      my $local_iqn = nimble_get_local_iscsi_iqn() // '(unknown)';
      print "Debug :: Using configured initiator group \"$ig_name\" (id=$id). "
        . "This node's IQN: $local_iqn. "
        . "Verify this IQN is a member of that group on the Nimble array if sendtargets returns no targets.\n";
    }
    return $id;
  }
  my $iqn = nimble_get_local_iscsi_iqn();
  die "Error :: nimble_initiator_group not set and could not read a valid IQN from /etc/iscsi/initiatorname.iscsi (install open-iscsi; need an uncommented line InitiatorName=iqn...., or set nimble_initiator_group to an existing Nimble group).\n"
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

# access_control_record list/detail may expose vol_id or volume_id depending on firmware / row shape.
sub nimble_acr_vol_id {
  my ($acr) = @_;
  return undef unless ref($acr) eq 'HASH';
  return $acr->{ vol_id } if defined $acr->{ vol_id };
  return $acr->{ volume_id } if defined $acr->{ volume_id };
  return undef;
}

# Check if volume already has an access_control_record for the given initiator group.
sub nimble_volume_has_acl_for_ig {
  my ( $scfg, $vol_id, $ig_id, $storeid ) = @_;
  return 0 if !defined $vol_id || !defined $ig_id;
  my $enc_vid = uri_escape($vol_id);
  my $r = eval { nimble_api_call( $scfg, 'GET', "access_control_records?vol_id=$enc_vid", undef, $storeid ) };
  $r = eval { nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid ) } unless $r;
  return 0 unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH';
    my $a_vid = nimble_acr_vol_id($acr);
    my $a_ig  = $acr->{ initiator_group_id };
    next unless defined $a_vid && defined $a_ig;
    return 1 if "$a_vid" eq "$vol_id" && "$a_ig" eq "$ig_id";
  }
  return 0;
}

# Ensure multi_initiator=true on the Nimble volume so that both source and destination nodes
# can hold simultaneous iSCSI sessions during live migration.  New volumes are created with this
# flag; this call fixes volumes created before the flag was introduced.  The PUT is idempotent:
# a no-op if the array already has multi_initiator=true.  Failures are non-fatal (warn only) so
# they do not block activation on arrays/firmware that do not expose this field.
sub nimble_ensure_volume_multi_initiator {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return unless $vol_id;
  eval {
    nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { multi_initiator => JSON::XS::true }, $storeid );
    print "Info :: Volume \"$volname\" multi_initiator=true (concurrent access for live migration).\n"
      if $DEBUG >= 1;
  };
  if ( my $e = $@ ) {
    chomp $e;
    warn "Warning :: Could not set multi_initiator on volume \"$volname\": $e\n";
  }
}

# Parallel to PureStoragePlugin::purestorage_volume_connection: $mode true = connect (POST), false = disconnect (DELETE).
# Nimble maps host access via access_control_records for this storage's initiator group (same ig as activate).
# For connect: ACL is ensured first, then the per-volume iSCSI session is established here (not deferred to
# map_volume).  map_volume then mirrors Pure's map_volume: rescan + wait for device.
sub nimble_volume_connection {
  my ( $class, $storeid, $scfg, $volname, $mode ) = @_;
  if ($mode) {
    $class->nimble_ensure_volume_acl_for_current_node( $scfg, $volname, $storeid );
    $class->nimble_ensure_volume_multi_initiator( $scfg, $volname, $storeid );
    $class->nimble_iscsi_establish_volume_session( $scfg, $volname, $storeid );
    return 1;
  }
  # Disconnect: the ACR is per (volume, initiator group). A configured `nimble_initiator_group` (or an
  # auto-selected group listing several hosts' IQNs) is shared by every cluster node, so there is
  # exactly ONE record granting access — deleting it here would revoke the volume for all nodes.
  # During live migration the source node deactivates AFTER the VM is already running on the target;
  # deleting a shared ACR at that point cuts the running VM off from its disk. Only revoke when the
  # group is this node's own single-node auto group (pve-<nodename>); shared-group ACLs stay until
  # nimble_remove_volume / restore-disconnect delete all records for the volume.
  return 1 if defined $scfg->{ nimble_initiator_group } && $scfg->{ nimble_initiator_group } ne '';
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return 1 unless $vol_id;
  my $node_group = 'pve-' . PVE::INotify::nodename();
  my $enc_g = uri_escape($node_group);
  my $gr = eval { nimble_api_call( $scfg, 'GET', "initiator_groups?name=$enc_g", undef, $storeid ) };
  return 1 unless $gr;
  my $ig_id;
  for my $g ( @{ nimble_data_as_list( $gr->{ data } ) } ) {
    next unless ref($g) eq 'HASH';
    if ( ( $g->{ name } // '' ) eq $node_group ) { $ig_id = $g->{ id }; last; }
  }
  return 1 unless defined $ig_id && $ig_id ne '';
  my $enc_vid = uri_escape($vol_id);
  my $r = eval { nimble_api_call( $scfg, 'GET', "access_control_records?vol_id=$enc_vid", undef, $storeid ) };
  $r = eval { nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid ) } unless $r;
  return 1 unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH' && defined $acr->{ id };
    my $acr_vid = nimble_acr_vol_id($acr) // '';
    next unless $acr_vid eq $vol_id && ( $acr->{ initiator_group_id } // '' ) eq $ig_id;
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
  if ( nimble_volume_has_acl_for_ig( $scfg, $vol_id, $ig_id, $storeid ) ) {
    print "Debug :: Volume \"$volname\" already has ACL for initiator group (id=$ig_id). "
      . "If sendtargets still returns no targets, verify this node's IQN is a member of that group.\n"
      if $DEBUG >= 1;
    return 1;
  }
  if ( nimble_post_access_control_record_idempotent( $scfg, $vol_id, $ig_id, $storeid ) ) {
    print "Info :: Volume \"$volname\" granted Nimble access (initiator group ACL, ig_id=$ig_id).\n";
    # ACL propagation is handled by the sendtargets retry loop in nimble_iscsi_establish_volume_session.
  }
  return 1;
}

# Establish (or verify) an iSCSI session for this volume's per-volume IQN.
#
# Follows the same pattern as TrueNAS _iscsi_login_all, adapted for Nimble's per-volume IQN
# model (each volume has a unique IQN, served on LUN 0, only by the owning controller port):
#
#   1. Fast exit if session already up.
#   2. Run sendtargets on discovery portals; retry until this IQN appears in the node DB.
#      (Nimble only returns a volume's IQN to authorised initiators; a fresh ACL may take
#      up to ~24 s to propagate before sendtargets responds.)
#   3. Read login portals from the node DB via `iscsiadm -m node --targetname <iqn>`.
#      These are the portals sendtargets populated — the actual data portals, not the
#      discovery IPs.  Login to each one explicitly with -T <iqn> -p <portal>.
#   4. Verify session and emit a diagnostic warning if still absent.
sub nimble_iscsi_establish_volume_session {
  my ( $class, $scfg, $volname, $storeid ) = @_;

  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $storeid );
  return 0 unless $volume && length( $volume->{ target_name } // '' );
  my $iqn = nimble_untaint_iscsiadm_scalar( $volume->{ target_name } );
  return 0 unless length $iqn;

  my $iscsiadm = nimble_iscsiadm_path();
  return 0 unless -x $iscsiadm;

  my @known_portals = nimble_iscsi_node_portals_for_target($iqn);
  # 1. Fast path: every known portal for this IQN already has a session (multipath-ready).
  return 1 if @known_portals && nimble_iscsi_all_portals_in_sessions( $iqn, \@known_portals, 0 );

  my @dip = get_nimble_iscsi_discovery_ips( $scfg, $storeid );
  if ( !@dip ) {
    warn "Warning :: No iSCSI discovery IPs for storage \"$storeid\"; cannot log in to "
      . "\"$iqn\". Check GET v1/subnets discovery_ip or set nimble_iscsi_discovery_ips.\n";
    return 0;
  }

  # 2. Sendtargets retry loop — wait for this IQN to appear in the node DB.
  #    Also collect portals directly from sendtargets output as a fallback so
  #    we can login even when the node DB write is delayed or suppressed.
  my $max_rounds  = 12;    # up to 24 s (12 x 2 s)
  my $in_node_db  = 0;
  my @direct_portals;      # portals reported by sendtargets for THIS IQN
  for my $round ( 1 .. $max_rounds ) {
    @known_portals = nimble_iscsi_node_portals_for_target($iqn);
    if ( @known_portals && nimble_iscsi_all_portals_in_sessions( $iqn, \@known_portals, 0 ) ) {
      return 1;
    }

    for my $dp ( @dip ) {
      my @lines;
      eval {
        run_command(
          [ $iscsiadm, '-m', 'discovery', '-t', 'sendtargets', '-p', $dp ],
          outfunc => sub { push @lines, shift },
          errfunc => sub { },
          timeout => 20,
          quiet   => 1
        );
      };
      if ( $DEBUG >= 1 ) {
        if ( $@ ) {
          chomp( my $e = $@ );
          print "Debug :: sendtargets -p $dp: FAILED: $e\n";
        } else {
          my $out = @lines ? join( '; ', @lines ) : '(no output)';
          print "Debug :: sendtargets -p $dp: OK, response: $out\n";
        }
      }
      # Collect portals that sendtargets itself reported for this exact IQN.
      # Format: "10.x.x.x:3260,2460 iqn.xxx"
      my $iqn_lc = lc($iqn);
      my %seen_dp;
      for my $line ( @lines ) {
        next unless defined $line;
        if ( $line =~ m/^(\S+)\s+(\S+)/i && lc($2) eq $iqn_lc ) {
          my $portal = $1;
          $portal =~ s/,[0-9]+\z//;    # strip TPGT
          push @direct_portals, $portal unless $seen_dp{$portal}++;
        }
      }
    }

    if ( nimble_iscsi_node_portals_for_target($iqn) ) {
      print "Info :: \"$iqn\" discovered in node DB (sendtargets round $round).\n"
        if $round > 1 || $DEBUG >= 1;
      $in_node_db = 1;
      last;
    }

    # Also exit early if sendtargets already told us the portal directly
    if ( @direct_portals ) {
      print "Info :: \"$iqn\" seen in sendtargets output (round $round); "
        . "will login on direct portal(s): " . join(', ', @direct_portals) . "\n"
        if $DEBUG >= 1;
      $in_node_db = 1;    # treat as found — proceed to login
      last;
    }

    last if $round >= $max_rounds;
    print "Info :: \"$iqn\" not yet in sendtargets response "
      . "(ACL propagation, round $round/$max_rounds); retrying in 2s...\n"
      if $round >= 2 || $DEBUG >= 1;
    sleep(2);
  }

  unless ($in_node_db) {
    print "Info :: \"$iqn\" not found via sendtargets after $max_rounds rounds; "
      . "attempting login on any pre-existing node DB records.\n";
  }

  # 3. Login to every portal the node DB has for this IQN.
  #    Fall back to portals collected directly from sendtargets output when the
  #    node DB is empty (e.g. iscsiadm version/config that delays DB writes).
  my @node_portals = nimble_iscsi_node_portals_for_target($iqn);
  if ( !@node_portals && @direct_portals ) {
    print "Info :: Node DB empty for \"$iqn\"; using portals from sendtargets output: "
      . join( ', ', @direct_portals ) . "\n";
    @node_portals = @direct_portals;
  }
  if ( !@node_portals ) {
    warn "Warning :: No node DB records for \"$iqn\" after sendtargets. "
      . "Check: ACL for this node's initiator group on the Nimble, L3 path from this "
      . "host to the data subnet, and open-iscsi / iscsiadm installation.\n";
    return 0;
  }

  for my $raw_portal ( @node_portals ) {
    my $portal = nimble_untaint_iscsiadm_scalar($raw_portal);
    next unless length $portal;
    nimble_iscsi_node_login_if_needed( $iqn, $portal );
  }

  # Settle udev so the kernel has processed any new device events.
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=15' ] ); };

  # 4. Verify at least one session; multipath needs every portal (warn if any path is still down).
  my $up = nimble_iscsi_target_in_sessions( $iqn, 20 );    # poll up to 10 s
  if ( $up && !nimble_iscsi_all_portals_in_sessions( $iqn, \@node_portals, 0 ) ) {
    my @missing = grep { !nimble_iscsi_portal_in_sessions( $iqn, $_, 0 ) } @node_portals;
    warn "Warning :: iSCSI session for \"$iqn\" is up but multipath portal(s) missing: "
      . join( ', ', @missing ) . ". Check data-network paths to all Nimble controllers.\n"
      if @missing;
  }
  unless ($up) {
    my $portals_str = join( ', ', @node_portals );
    warn "Warning :: No iSCSI session for \"$iqn\" after login on: $portals_str. "
      . "Check: initiator group ACL on Nimble, L3 path to data portals, open-iscsi.\n";
  }
  return $up;
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

# Look up a Nimble folder by name and return its id (or undef if not found).
# API: GET v1/folders?name=<name>  — the `folders` object set is listed in the Nimble API
# reference alongside volume_collections, pools, etc.  Each row has `id` and `name`.
sub nimble_get_folder_id {
  my ( $scfg, $name, $storeid ) = @_;
  return undef if !defined $name || $name eq '';
  my $enc  = uri_escape( $name );
  my $r    = nimble_api_call( $scfg, 'GET', "folders?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  for my $f ( @$list ) {
    return $f->{ id } if ref($f) eq 'HASH' && $f->{ name } eq $name;
  }
  return undef;
}

sub nimble_get_volume_id {
  my ( $scfg, $volname, $storeid ) = @_;
  my $name = nimble_volname( $scfg, $volname, undef );
  my $match = sub {
    my ($list, $want) = @_;
    for my $v ( @$list ) {
      next unless ref($v) eq 'HASH' && defined $v->{ name };
      return $v if $v->{ name } eq $want;
    }
    return undef;
  };

  my $enc  = uri_escape($name);
  my $r    = nimble_api_call( $scfg, 'GET', "volumes?name=$enc", undef, $storeid );
  my $list = nimble_data_as_list( $r->{ data } );
  my $vol  = $match->($list, $name);

  if ( !$vol ) {
    $r    = nimble_api_call( $scfg, 'GET', 'volumes', undef, $storeid );
    $list = nimble_data_as_list( $r->{ data } );
    $vol  = $match->($list, $name);
  }

  # Fallback: if a volume prefix is configured and the prefixed name was not found,
  # try the bare volname without the prefix.  This handles volumes that were created
  # before the nimble_vnprefix was set (or imported outside of PVE) so they still
  # exist on the array under their original name.  A clear warning is emitted so the
  # operator knows the prefix mismatch exists and can rename volumes if desired.
  if ( !$vol ) {
    my $prefix = nimble_name_prefix( $scfg );
    if ( length($prefix) && index( $name, $prefix ) == 0 ) {
      my $bare = substr( $name, length($prefix) );
      if ( length($bare) ) {
        my $enc_bare = uri_escape($bare);
        my $r2   = eval { nimble_api_call( $scfg, 'GET', "volumes?name=$enc_bare", undef, $storeid ) };
        if ( $r2 ) {
          my $list2 = nimble_data_as_list( $r2->{ data } );
          $vol = $match->($list2, $bare);
        }
        if ( !$vol ) {
          $vol = $match->($list, $bare);
        }
        if ( $vol ) {
          warn "Warning :: Volume \"$volname\" found on array as \"$bare\" (without prefix \"$prefix\"). "
            . "Consider renaming it to \"$name\" on the Nimble array to match the configured "
            . "nimble_vnprefix, or clear the prefix in storage config.\n";
        }
      }
    }
  }

  return ( undef, undef ) unless $vol;

  # List/search often omit serial_number, target_name (per-volume iSCSI IQN), size, and
  # creation_time / last_modified (PVE VM Disks Date column uses ctime).
  # Fetch the full detail record when any of these are absent so callers always get correct values.
  if ( defined $vol->{ id } ) {
    my $need_serial = !length( $vol->{ serial_number } // '' );
    my $need_target = !length( $vol->{ target_name } // '' );
    my $need_size   = !( $vol->{ size } // 0 );
    my $need_ctime  = !nimble_volume_row_ctime_epoch($vol);
    if ( $need_serial || $need_target || $need_size || $need_ctime ) {
      $r = nimble_api_call( $scfg, 'GET', "volumes/$vol->{ id }", undef, $storeid );
      my $full = $r->{ data } || $r;
      if ( ref($full) eq 'HASH' ) {
        $vol->{ serial_number } = $full->{ serial_number } if length( $full->{ serial_number } // '' );
        $vol->{ target_name }    = $full->{ target_name } if length( $full->{ target_name } // '' );
        $vol->{ size }           = $full->{ size } if ( $full->{ size } // 0 ) > 0;
        if ($need_ctime) {
          $vol->{ creation_time } = $full->{ creation_time } if defined $full->{ creation_time };
          $vol->{ last_modified }  = $full->{ last_modified }  if defined $full->{ last_modified };
        }
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

    # Primary match: name starts with configured prefix (or prefix is empty).
    my $volname;
    if ( !length($prefix) ) {
      $volname = $name;
    } elsif ( index( $name, $prefix ) == 0 ) {
      $volname = substr( $name, length($prefix) );
    } else {
      # Fallback: volume was created before nimble_vnprefix was set (or imported outside PVE).
      # Include it but emit a one-time debug note so the operator knows about the mismatch.
      # Only include if the bare name looks like a PVE volume (vm-<id>-disk/cloudinit/state).
      if ( $name =~ m/^vm-\d+-(disk-|cloudinit|state-)/ ) {
        $volname = $name;
        print "Debug :: nimble_list_volumes: volume \"$name\" has no prefix \"$prefix\" — "
          . "created before nimble_vnprefix was configured. Showing without prefix.\n"
          if $DEBUG >= 2;
      } else {
        next;
      }
    }

    next unless $volname =~ m/^vm-\d+-(disk-|cloudinit|state-)/;
    my ( undef, undef, $volvm ) = $class->parse_volname( $volname );
    # List endpoint sometimes omits size (returns 0) and/or times used for the GUI Date column.
    # Fetch the full record so move_disk and **ctime** match GET volumes/:id.
    my $need_size  = !( $v->{ size } // 0 );
    my $need_ctime = !nimble_volume_row_ctime_epoch($v);
    if ( ( $need_size || $need_ctime ) && defined $v->{ id } ) {
      my $detail = eval { nimble_api_call( $scfg, 'GET', "volumes/$v->{ id }", undef, $storeid ) };
      if ( $detail && ref( $detail->{ data } ) eq 'HASH' ) {
        my $d = $detail->{ data };
        if ( $need_size && ( $d->{ size } // 0 ) > 0 ) {
          $v->{ size } = $d->{ size };
        }
        if ($need_ctime) {
          $v->{ creation_time } = $d->{ creation_time } if defined $d->{ creation_time };
          $v->{ last_modified }  = $d->{ last_modified }  if defined $d->{ last_modified };
        }
      }
    }
    push @volumes,
      {
        name   => $volname,
        vmid   => $volvm,
        serial => $v->{ serial_number },
        size   => ( $v->{ size } || 0 ) * 1024 * 1024,
        used   => nimble_volume_used_bytes($v),
        ctime  => nimble_volume_row_ctime_epoch($v) || 0,
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

# HPE volume.size is MB; vol_usage_compressed_bytes is already bytes (NsBytes).
sub nimble_volume_used_bytes {
  my ($vol) = @_;
  return 0 unless ref($vol) eq 'HASH';
  if ( exists $vol->{ vol_usage_compressed_bytes }
    && defined $vol->{ vol_usage_compressed_bytes }
    && $vol->{ vol_usage_compressed_bytes } ne ''
    && looks_like_number( $vol->{ vol_usage_compressed_bytes } ) )
  {
    return int( 0 + $vol->{ vol_usage_compressed_bytes } );
  }
  return int( ( $vol->{ size } || 0 ) * 1024 * 1024 );
}

sub nimble_get_volume_info {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return undef unless $vol;
  my $array_name = $vol->{ name };
  my $prefix     = nimble_name_prefix( $scfg );
  # Only strip the prefix if the array name actually starts with it (fallback lookup
  # may have found a bare-named volume that doesn't carry the prefix).
  $array_name = substr( $array_name, length( $prefix ) )
    if length($prefix) && index( $array_name, $prefix ) == 0;
  return {
    name         => $array_name,
    serial       => $vol->{ serial_number },
    target_name  => $vol->{ target_name } // '',
    size         => ( $vol->{ size } || 0 ) * 1024 * 1024,
    used         => nimble_volume_used_bytes($vol),
    ctime        => nimble_volume_row_ctime_epoch($vol) || 0,
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

# Apply nimble_limit_iops / nimble_limit_mbps from storage config to a volume API request body.
# Called before POST volumes (create and clone). Values of -1 or 0 mean unlimited (omitted).
# Constraint: if both are set, limit_iops <= (limit_mbps * 1048576 / block_size).
# The plugin does not enforce this — the array will reject invalid combinations with an error.
sub nimble_apply_qos_to_body {
  my ( $scfg, $body ) = @_;
  my $iops = $scfg->{ nimble_limit_iops };
  my $mbps = $scfg->{ nimble_limit_mbps };
  if ( defined $iops && $iops =~ /^-?\d+$/ && $iops + 0 >= 256 ) {
    $body->{ limit_iops } = $iops + 0;
  }
  if ( defined $mbps && $mbps =~ /^-?\d+$/ && $mbps + 0 >= 1 ) {
    $body->{ limit_mbps } = $mbps + 0;
  }
}

sub nimble_create_volume {
  my ( $class, $scfg, $volname, $size_bytes, $storeid ) = @_;
  my $name    = nimble_volname( $scfg, $volname, undef );
  my $size_mb = size_bytes_to_mb( $size_bytes );
  my $body = { name => $name, size => $size_mb, multi_initiator => JSON::XS::true };
  # Note: the API body key stays `pool_name` (Nimble REST parameter); only the config key is nimble_-prefixed.
  $body->{ pool_name } = $scfg->{ nimble_pool_name } if $scfg->{ nimble_pool_name };
  nimble_apply_qos_to_body( $scfg, $body );

  # Resolve folder name → folder_id and pass it to the create body.
  # POST v1/volumes accepts `folder_id` (the Nimble API field name); the plugin config key is
  # `nimble_folder` (the human-readable folder name).  If the folder is not found we warn and
  # continue without the folder — the volume is still created in the root folder.
  if ( $scfg->{ nimble_folder } ) {
    my $folder_id = eval { nimble_get_folder_id( $scfg, $scfg->{ nimble_folder }, $storeid ) };
    if ( $@ ) {
      chomp( my $e = $@ );
      warn "Warning :: Could not look up Nimble folder \"$scfg->{ nimble_folder }\": $e. Volume will be created in root folder.\n";
    } elsif ( $folder_id ) {
      $body->{ folder_id } = $folder_id;
      print "Info :: Volume \"$volname\" will be created in folder \"$scfg->{ nimble_folder }\" (id=$folder_id).\n"
        if $DEBUG >= 1;
    } else {
      warn "Warning :: Nimble folder \"$scfg->{ nimble_folder }\" not found (GET v1/folders returned no match). Volume will be created in root folder.\n";
    }
  }

  my $r      = nimble_api_call( $scfg, 'POST', 'volumes', $body, $storeid );
  my $vol    = $r->{ data } || $r;
  my $serial = $vol->{ serial_number } or die "Error :: No serial_number in create response\n";
  $vol->{ id } or die "Error :: No id in create response\n";
  my $qos_info = '';
  if ( defined $body->{ limit_iops } || defined $body->{ limit_mbps } ) {
    $qos_info = join( ', ',
      ( defined $body->{ limit_iops } ? "IOPS=$body->{limit_iops}" : () ),
      ( defined $body->{ limit_mbps } ? "MBPS=$body->{limit_mbps}" : () ),
    );
    $qos_info = " [QoS: $qos_info]";
  }
  print "Info :: Volume \"$volname\" created (serial=$serial)$qos_info.\n";
  my $create_err;
  eval {
    my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
    nimble_post_access_control_record_idempotent( $scfg, $vol->{ id }, $ig_id, $storeid );
    if ( $scfg->{ nimble_volume_collection } ) {
      my $volcoll_id = nimble_get_volume_collection_id( $scfg, $scfg->{ nimble_volume_collection }, $storeid );
      if ( $volcoll_id ) {
        nimble_api_call( $scfg, 'PUT', "volumes/$vol->{ id }", { volcoll_id => $volcoll_id }, $storeid );
        print "Info :: Volume \"$volname\" added to volume collection \"$scfg->{ nimble_volume_collection }\".\n";
      } else {
        warn "Warning :: nimble_volume_collection \"$scfg->{ nimble_volume_collection }\" not found; volume not added to any collection.\n";
      }
    }
  };
  if ( $create_err = $@ ) {
    nimble_volume_offline_then_delete_best_effort( $scfg, $vol->{ id }, $storeid, $volname );
    die $create_err;
  }
  return 1;
}

# Nimble-specific: remove snapshots for this vol_id (multi-round; logs failed DELETEs).
# Newest-first tends to work better when snapshots form a chain; rounds catch API lag.
sub nimble_delete_snapshots_for_volume_id {
  my ( $scfg, $vol_id, $storeid ) = @_;
  return unless defined $vol_id;
  my $max_rounds = 5;
  for my $round ( 1 .. $max_rounds ) {
    my $enc_vid = uri_escape($vol_id);
    my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc_vid", undef, $storeid ) };
    $r = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) } unless $r;
    last unless $r;
    my $list = nimble_data_as_list( $r->{ data } );
    my @snaps;
    for my $s ( @$list ) {
      next unless ref($s) eq 'HASH' && defined $s->{ id };
      next if nimble_snapshot_row_volume_id_mismatch( $s, $vol_id );
      push @snaps, $s;
    }
    last unless @snaps;
    @snaps = sort {
      nimble_snapshot_effective_creation_time($b) <=> nimble_snapshot_effective_creation_time($a)
    } @snaps;
    for my $s (@snaps) {
      eval { nimble_api_call( $scfg, 'DELETE', "snapshots/" . $s->{ id }, undef, $storeid ); 1 };
      if ( my $e = $@ ) {
        warn "Warning :: Nimble DELETE snapshots/" . $s->{ id } . " (vol_id=$vol_id): $e";
      }
    }
    sleep(1) if $round < $max_rounds;
  }
}

sub nimble_delete_access_control_records_for_volume_id {
  my ( $scfg, $vol_id, $storeid ) = @_;
  return unless defined $vol_id;
  my $enc_vid = uri_escape($vol_id);
  my $r = eval { nimble_api_call( $scfg, 'GET', "access_control_records?vol_id=$enc_vid", undef, $storeid ) };
  $r = eval { nimble_api_call( $scfg, 'GET', 'access_control_records', undef, $storeid ) } unless $r;
  return unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  for my $acr ( @$list ) {
    next unless ref($acr) eq 'HASH' && defined $acr->{ id };
    my $acr_vid = nimble_acr_vol_id($acr) // '';
    next unless $acr_vid eq $vol_id;
    eval { nimble_api_call( $scfg, 'DELETE', "access_control_records/" . $acr->{ id }, undef, $storeid ); };
  }
}

# GET v1/volumes/:id — return the volume object under response data, or undef on failure.
sub nimble_volume_detail {
  my ( $scfg, $vol_id, $storeid ) = @_;
  my $r = eval { nimble_api_call( $scfg, 'GET', "volumes/$vol_id", undef, $storeid ) };
  return undef unless $r && ref( $r->{ data } ) eq 'HASH';
  return $r->{ data };
}

# Ensure the volume is offline on the array (PUT online=false only when GET shows online=true).
# If PUT fails with 409 / SM_vol_has_connections, Nimble often still has another LUN in the same cgroup
# connected (error text cites sibling vol=…); local disconnect on this volume is not enough. Retry with
# PUT { online: false, force: true } (HPE volume.force — forcibly offline).
# $label is for error messages (PVE volume name or "volume id …").
sub nimble_volume_ensure_offline {
  my ( $scfg, $vol_id, $storeid, $label ) = @_;
  $label ||= "volume id $vol_id";
  my $detail = nimble_volume_detail( $scfg, $vol_id, $storeid );
  return 1 unless !$detail || $detail->{ online };

  my $is_offline = sub {
    my $d = nimble_volume_detail( $scfg, $vol_id, $storeid );
    return $d && !$d->{ online };
  };

  my $try_force_offline = sub {
    eval {
      nimble_api_call(
        $scfg, 'PUT', "volumes/$vol_id",
        { online => JSON::XS::false, force => JSON::XS::true },
        $storeid
      );
      1;
    };
    return 1 if $is_offline->();
    my $ef = $@;
    die "Error :: Could not take \"$label\" offline on the Nimble array: $ef" if $ef;
    die "Error :: Could not take \"$label\" offline on the Nimble array (still online after forced PUT)\n";
  };

  eval { nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { online => JSON::XS::false }, $storeid ); 1 };
  my $e1 = $@;
  return 1 if $is_offline->();

  if ($e1) {
    return 1 if $is_offline->();
    if ( $e1 =~ /SM_vol_has_connections|\b409\b|SM_http_conflict/i ) {
      $try_force_offline->();
      return 1;
    }
    die "Error :: Could not take \"$label\" offline on the Nimble array: $e1";
  }

  # HTTP success but array still shows online (unusual): forced offline.
  $try_force_offline->();
  return 1;
}

# PUT online=true with retries. activate_volume / nimble_volume_connection do not set online on the array.
# After a successful PUT, GET volumes/:id and require online=true (matches ensure_offline asymmetry).
sub nimble_volume_ensure_online {
  my ( $scfg, $vol_id, $storeid, $label, $attempts ) = @_;
  $label    ||= "volume id $vol_id";
  $attempts //= 3;
  my $last_err;
  for my $attempt ( 1 .. $attempts ) {
    eval { nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { online => JSON::XS::true }, $storeid ); };
    if ($@) {
      $last_err = $@;
    } else {
      my $d = nimble_volume_detail( $scfg, $vol_id, $storeid );
      if ( $d && $d->{ online } ) {
        return 1;
      }
      $last_err = !$d
        ? "Error :: Nimble API: PUT online succeeded but GET volumes/$vol_id failed or returned no data"
          . ( $attempt < $attempts ? " (will retry)\n" : "\n" )
        : "Error :: Nimble API: PUT online succeeded but GET volumes/$vol_id still shows offline\n";
    }
    sleep(2) if $attempt < $attempts;
  }
  die "Error :: Could not bring \"$label\" back online on the Nimble array: $last_err\n";
}

# Used when create or clone post-steps fail: take the volume offline on the array (same semantics as
# nimble_volume_ensure_offline), then DELETE. Callers are fresh POST volumes (no snapshots yet); if an
# array policy ever created snapshots on new volumes before this runs, use nimble_remove_volume instead.
# Each step is eval-wrapped so a failed offline attempt does not skip DELETE; errors are ignored here
# because the caller will die with the original error.
sub nimble_volume_offline_then_delete_best_effort {
  my ( $scfg, $vol_id, $storeid, $label ) = @_;
  return unless defined $vol_id && $vol_id ne '';
  eval { nimble_volume_ensure_offline( $scfg, $vol_id, $storeid, $label ); };
  eval { nimble_api_call( $scfg, 'DELETE', "volumes/$vol_id", undef, $storeid ); };
}

# Purge snapshots, take volume offline, purge again (stragglers / array quiesce). Used before DELETE volume.
sub nimble_offline_volume_and_delete_snapshots {
  my ( $scfg, $vol_id, $storeid, $label ) = @_;
  return unless defined $vol_id;
  $label ||= "volume id $vol_id";
  nimble_delete_snapshots_for_volume_id( $scfg, $vol_id, $storeid );
  nimble_volume_ensure_offline( $scfg, $vol_id, $storeid, $label );
  nimble_delete_snapshots_for_volume_id( $scfg, $vol_id, $storeid );
}

# Same order as PureStoragePlugin::purestorage_remove_volume: local DM cleanup → disconnect all hosts on
# the array → destroy. Nimble: multipath/LVM/part cleanup, DELETE every access_control_record for the
# volume, offline + snapshots, then DELETE volume.
sub nimble_remove_volume {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my ( $vol_id, $vol ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;

  # Disk move with "delete source" often still has iSCSI sessions; without logout, offline/DELETE can
  # fail (SM_vol_has_connections / SM_eperm). Same disconnect as snapshot-restore prep.
  nimble_volume_prepare_restore_disconnect( $class, $scfg, $vol_id, $storeid, $volname );

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
  nimble_offline_volume_and_delete_snapshots( $scfg, $vol_id, $storeid, $volname );

  eval { nimble_api_call( $scfg, 'DELETE', "volumes/$vol_id", undef, $storeid ); 1 }
    or do {
      my $e = $@ || '';
      if ( $e =~ /\b409\b/ || $e =~ /SM_http_conflict/ || $e =~ /SM_eperm/ ) {
        sleep(3);
        nimble_volume_prepare_restore_disconnect( $class, $scfg, $vol_id, $storeid, $volname );
        nimble_delete_access_control_records_for_volume_id( $scfg, $vol_id, $storeid );
        nimble_offline_volume_and_delete_snapshots( $scfg, $vol_id, $storeid, $volname );
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
  eval { nimble_host_refresh_volume_size_after_array_resize( $class, $scfg, $storeid, $volname, $size_bytes ); };
  if ($@) {
    warn "Warning :: Resized \"$volname\" on Nimble but host block layer did not confirm new size: $@\n";
    die $@;
  }
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
  # Full snapshot name on array: actual_array_base + .snap-<name>
  # Uses actual array volume name so prefix-less volumes (created before nimble_vnprefix
  # was set) get snapshots named correctly (e.g. "vm-111-disk-0.snap-foo" not "stglx01-vm-111-disk-0.snap-foo").
  my $snap_full_name = nimble_actual_array_volname( $scfg, $volname, $snap_name, $storeid );
  nimble_api_call( $scfg, 'POST', 'snapshots', { vol_id => $vol_id, name => $snap_full_name }, $storeid );
  print "Info :: Snapshot \"$snap_name\" created for volume \"$volname\".\n";
  return 1;
}

sub nimble_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap_name ) = @_;
  my $snap_id;
  if ( $snap_name =~ /^nimble(\d+)$/ ) {
    # Array-imported snapshot: find by creation_time (±60s)
    my $target_ts = $1;
    my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
    if ( $vol_id ) {
      my $enc_vid = uri_escape($vol_id);
      my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc_vid", undef, $storeid ) };
      $r = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) } unless $r;
      return 1 unless $r;
      my $list = nimble_data_as_list( $r->{ data } );
      my ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $target_ts, $list );
      if ( !$best ) {
        my $alt = nimble_vm_snaptime_from_qemu_conf( $volname, $snap_name );
        if ( defined $alt && $alt != $target_ts ) {
          ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $alt, $list );
        }
      }
      $snap_id = $best->{ id } if $best;
    }
  } else {
    my $snap_full = nimble_actual_array_volname( $scfg, $volname, $snap_name, $storeid );
    my $enc  = uri_escape( $snap_full );
    my $r    = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
    my $list = nimble_data_as_list( $r->{ data } );
    for my $s ( @$list ) {
      if ( $s->{ name } eq $snap_full ) { $snap_id = $s->{ id }; last; }
    }
  }
  unless ( $snap_id ) {
    warn "Warning :: Snapshot \"$snap_name\" not found for volume \"$volname\".\n";
    return 1;
  }
  nimble_api_call( $scfg, 'DELETE', "snapshots/$snap_id", undef, $storeid );
  print "Info :: Snapshot \"$snap_name\" deleted.\n";
  return 1;
}

sub nimble_volume_restore {
  my ( $class, $scfg, $storeid, $volname, $svolname, $snap, $overwrite ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  die "Error :: Volume \"$volname\" not found\n" unless $vol_id;
  my $snap_id;
  if ( $snap =~ /^nimble(\d+)$/ ) {
    # Array-imported snapshot: find by creation_time (±60s) using vol_id
    my $target_ts = $1;
    my $enc_vid = uri_escape($vol_id);
    my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc_vid", undef, $storeid ) };
    $r = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) } unless $r;
    die "Error :: Could not query snapshots for volume \"$volname\"\n" unless $r;
    my $list = nimble_data_as_list( $r->{ data } );
    my ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $target_ts, $list );
    if ( !$best ) {
      my $alt = nimble_vm_snaptime_from_qemu_conf( $volname, $snap );
      if ( defined $alt && $alt != $target_ts ) {
        ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $alt, $list );
      }
    }
    die "Error :: Nimble snapshot for \"$svolname\" at time $target_ts not found\n" unless $best;
    $snap_id = $best->{ id };
  } else {
    my $snap_full = nimble_volname( $scfg, $svolname, $snap );
    my $enc  = uri_escape( $snap_full );
    my $r    = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
    my $list = nimble_data_as_list( $r->{ data } );
    for my $s ( @$list ) {
      if ( $s->{ name } eq $snap_full ) { $snap_id = $s->{ id }; last; }
    }
  }
  die "Error :: Snapshot \"$snap\" not found\n" unless $snap_id;
  # Nimble requires the volume to be offline before restore (SM_vol_not_offline_on_restore).
  # PUT online=false fails with SM_vol_has_connections while any initiator still has a session.
  # Unmap + iscsi logout + remove all access_control_records (this node and multi_initiator peers),
  # then take the volume offline on the array. Next activate_volume re-posts ACL and maps again.
  nimble_volume_prepare_restore_disconnect( $class, $scfg, $vol_id, $storeid, $volname );
  nimble_volume_ensure_offline( $scfg, $vol_id, $storeid, $volname );
  # HPE REST API: POST v1/volumes/id/actions/restore with id and base_snap_id (both mandatory)
  my $restore_err;
  eval {
    nimble_api_call( $scfg, 'POST', "volumes/$vol_id/actions/restore", { id => $vol_id, base_snap_id => $snap_id }, $storeid );
  };
  $restore_err = $@;
  eval { nimble_volume_ensure_online( $scfg, $vol_id, $storeid, $volname, 3 ); };
  my $online_err = $@;
  if ($restore_err) {
    warn "Warning :: Also could not bring volume \"$volname\" back online after failed restore: $online_err\n"
      if $online_err;
    die $restore_err;
  }
  die $online_err if $online_err;
  print "Info :: Volume \"$volname\" restored from snapshot \"$snap\".\n";
  return 1;
}

# Create a new volume from a snapshot (clone). API: POST volumes with clone=true, name, base_snap_id.
sub nimble_clone_from_snapshot {
  my ( $class, $scfg, $storeid, $new_volname, $source_volname, $snap_name ) = @_;
  print "Info :: Cloning \"$source_volname\" (snap \"$snap_name\") → \"$new_volname\" on Nimble array...\n";
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
  print "Info :: Sending clone request to array (instant server-side copy)...\n";
  my $body = { clone => JSON::XS::true, name => $name_on_array, base_snap_id => $snap_id, multi_initiator => JSON::XS::true };
  nimble_apply_qos_to_body( $scfg, $body );
  $r = nimble_api_call( $scfg, 'POST', 'volumes', $body, $storeid );
  my $vol = $r->{ data } || $r;
  my $vol_id = $vol->{ id } or die "Error :: Clone did not return volume id.\n";
  # Report QoS limits applied if any
  if ( defined $body->{ limit_iops } || defined $body->{ limit_mbps } ) {
    my $qos = join( ', ',
      ( defined $body->{ limit_iops } ? "IOPS=$body->{limit_iops}" : () ),
      ( defined $body->{ limit_mbps } ? "MBPS=$body->{limit_mbps}" : () ),
    );
    print "Info :: QoS limits applied to clone \"$new_volname\": $qos\n";
  }
  my $clone_err;
  eval {
    print "Info :: Granting iSCSI access to clone \"$new_volname\"...\n";
    my $ig_id = nimble_ensure_initiator_group_id( $scfg, $storeid );
    nimble_post_access_control_record_idempotent( $scfg, $vol_id, $ig_id, $storeid );
    if ( $scfg->{ nimble_volume_collection } ) {
      my $volcoll_id = nimble_get_volume_collection_id( $scfg, $scfg->{ nimble_volume_collection }, $storeid );
      if ( $volcoll_id ) {
        nimble_api_call( $scfg, 'PUT', "volumes/$vol_id", { volcoll_id => $volcoll_id }, $storeid );
        print "Info :: Cloned volume \"$new_volname\" added to volume collection \"$scfg->{ nimble_volume_collection }\".\n";
      } else {
        warn "Warning :: nimble_volume_collection \"$scfg->{ nimble_volume_collection }\" not found; clone not added to any collection.\n";
      }
    }
  };
  if ( $clone_err = $@ ) {
    nimble_volume_offline_then_delete_best_effort( $scfg, $vol_id, $storeid, $new_volname );
    die $clone_err;
  }
  print "Info :: Clone complete: \"$new_volname\" is ready (array-side instant copy — no data moved on host).\n";
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

sub nimble_blockdev_getsize64 {
  my ($path) = @_;
  $path = nimble_untaint_dev_path($path) || return undef;
  return undef unless -b $path;
  my $out = '';
  eval {
    run_command(
      [ get_command_path('blockdev'), '--getsize64', $path ],
      outfunc => sub { $out .= shift; },
      quiet    => 1,
    );
  };
  return undef if $@;
  chomp $out;
  return ( $out =~ /^(\d+)$/ ) ? int($1) : undef;
}

# Tell multipathd to re-read capacity after the array grew the LUN (best-effort per name variant).
sub nimble_multipathd_resize_maps_for_volume {
  my ( $storeid, $volname, $wwid ) = @_;
  return unless length($wwid);
  my %seen;
  for my $candidate ( nimble_multipath_alias_name( $storeid, $volname ), nimble_multipath_wwid_try_list($wwid) ) {
    my $t = nimble_untaint_multipath_map_token($candidate);
    next unless length $t;
    next if $seen{$t}++;
    eval { exec_command( [ 'multipathd', 'resize', 'map', $t ], -1, timeout => 60 ); };
  }
}

# After PUT volumes/:id size, the array is larger immediately but Linux often keeps the old path size
# until iSCSI/SCSI rescan and multipathd resize — without this, PVE fails the task and skips VM config
# update while Nimble already shows the new size.
sub nimble_host_refresh_volume_size_after_array_resize {
  my ( $class, $scfg, $storeid, $volname, $expected_bytes ) = @_;
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $storeid );
  return unless $volume && length( $volume->{ serial } // '' );
  my $serial = $volume->{ serial };

  eval {
    my $adm = nimble_iscsiadm_path();
    run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 120, quiet => 1 ) if -x $adm;
  };
  eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
  eval { scsi_scan_new('iscsi'); };

  my ( $path, $wwid ) = get_device_path_by_serial($serial);
  $path = nimble_untaint_dev_path($path) || '' if length $path;
  if ( length($path) && -b $path ) {
    my ( undef, @slaves ) = eval { block_device_slaves($path) };
    my $slaves_err = $@;
    eval { block_device_action( 'rescan', @slaves ) } unless $slaves_err;
  }

  nimble_multipathd_resize_maps_for_volume( $storeid, $volname, $wwid ) if length($wwid);

  eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=30' ] ); };

  return if !$expected_bytes || $expected_bytes <= 0;

  ( $path, $wwid ) = get_device_path_by_serial($serial);
  $path = nimble_untaint_dev_path($path) || '' if length $path;
  return unless length($path) && -b $path;

  # Mirror map_volume: periodic multipath resize while polling — slow HBAs may need a second resize map.
  my $resize_poll_ticks = 0;
  wait_for(
    sub {
      ++$resize_poll_ticks;
      if ( $resize_poll_ticks % 20 == 0 ) {
        my ( undef, $w_poll ) = get_device_path_by_serial($serial);
        eval { nimble_multipathd_resize_maps_for_volume( $storeid, $volname, $w_poll ) if length($w_poll); };
      }
      my ($p) = ( get_device_path_by_serial($serial) )[0];
      $p = nimble_untaint_dev_path($p) || '';
      return 0 unless length($p) && -b $p;
      my $sz = nimble_blockdev_getsize64($p);
      return 0 unless defined $sz && $sz >= $expected_bytes;
      return 1;
    },
    "block device for \"$volname\" to reflect new size ($expected_bytes bytes)",
    90,
    0.5
  );
}

### Storage interface
sub parse_volname {
  my ( $class, $volname ) = @_;
  if ( $volname =~ m/^((vm|base)-(\d+)-\S+)$/ ) {
    # Core block plugins (RBD/LVM/ZFS) return ('images', <full volname>, vmid, ..., $isBase, fmt).
    # 'base' is not a valid vtype — base images are vtype 'images' with the isBase flag. base-*
    # volumes cannot currently be created (create_base dies) but the contract must still hold.
    return ( 'images', $1, $3, undef, undef, ( $2 eq 'base' ? 1 : 0 ), 'raw' );
  }
  die "Error :: Invalid volume name ($volname).\n";
}

sub get_device_path_wwid {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my $sid = nimble_effective_storeid( $scfg, $storeid );
  my $volume = $class->nimble_get_volume_info( $scfg, $volname, $sid );
  return ( '', '' ) unless $volume && $volume->{ serial };
  return get_device_path_by_serial( $volume->{ serial } );
}

# Block path for $volname; map/activate first when the LUN is not visible (RAM snapshot vmstate volumes).
sub nimble_resolve_block_path_for_volname {
  my ( $class, $scfg, $volname, $storeid ) = @_;
  my $sid = nimble_effective_storeid( $scfg, $storeid );
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $sid );
  return ( $path, $wwid ) if length($path) && -b $path;
  eval { $class->activate_volume( $sid, $scfg, $volname, undef, undef, {} ); };
  if ( my $e = $@ ) {
    chomp $e;
    warn "Warning :: Could not activate \"$volname\" for path resolution: $e\n";
  }
  ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $sid );
  return ( $path, $wwid );
}

sub filesystem_path {
  my ( $class, $scfg, $volname, $snapname, $storeid ) = @_;
  die "Error :: filesystem_path: snapshot not implemented ($snapname)\n" if defined( $snapname );
  my ( $vtype, undef, $vmid ) = $class->parse_volname( $volname );
  my $sid          = nimble_effective_storeid( $scfg, $storeid );
  my ( $path, $wwid ) = $class->nimble_resolve_block_path_for_volname( $scfg, $volname, $sid );
  return wantarray ? ( "", "", "", "" ) : "" unless length( $path );
  $path = nimble_untaint_dev_path($path) || $path;
  return wantarray ? ( $path, $vmid, $vtype, $wwid ) : $path;
}

# Base PVE::Storage::Plugin::path() does not pass $storeid into filesystem_path; Nimble needs it for API/block resolution.
sub path {
  my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;
  return $class->filesystem_path( $scfg, $volname, $snapname, $storeid );
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
    die "Error :: Illegal name \"$name\" - should be vm-$vmid-disk-* (or cloudinit / state-* for QEMU VM disks).\n"
      if $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;
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
  nimble_multipath_deregister( $storeid, $volname );
  return undef;
}

# Sync array-created snapshots into PVE VM configs as fully functional PVE snapshots.
# Imported snapshot names use the format n<unix_timestamp> to avoid collision with
# user-named PVE snapshots and to allow rollback via creation_time lookup.
# Called from status() with a 30s throttle. Requires PVE::QemuConfig (pvestatd context).
sub nimble_sync_array_snapshots {
  my ( $scfg, $storeid ) = @_;

  eval { require PVE::QemuConfig };
  return if $@;

  my $debug  = get_debug_level( $scfg );
  my $prefix = nimble_name_prefix( $scfg );

  # All volumes belonging to this storage
  my $vr   = nimble_api_call( $scfg, 'GET', 'volumes', undef, $storeid );
  my $vols = nimble_data_as_list( $vr->{ data } );

  my %vol_map;    # full_nimble_name => { id, volname, vmid }
  my %vol_id_to_fullname;
  for my $v ( @$vols ) {
    my $name = $v->{ name } // '';
    next if length( $prefix ) && index( $name, $prefix ) != 0;
    my $volname = length( $prefix ) ? substr( $name, length( $prefix ) ) : $name;
    next unless $volname =~ /^vm-(\d+)-(disk-|cloudinit|state-)/;
    $vol_map{ $name } = { id => $v->{ id }, volname => $volname, vmid => $1 };
    my $vid = $v->{ id };
    $vol_id_to_fullname{ $vid } = $name if defined $vid && length($vid);
  }
  print "Debug :: nimble_sync [$storeid]: " . scalar( keys %vol_map ) . " PVE volumes found\n" if $debug >= 1;
  return unless %vol_map;

  # Prefer one GET snapshots (all rows) when the array allows it. Some firmware returns 400 unless
  # vol_id / vol_name / serial_number / app_uuid / id / Advanced Criteria is present (SM_missing_arg).
  # $fetch_incomplete: a per-volume GET failed, so the snapshot view is partial this round. Groups can
  # still be ADDED from what did arrive, but the stale-entry removal below must be skipped — with a
  # partial view "no longer on the array" is indistinguishable from "fetch failed".
  my @snaps;
  my $fetch_incomplete = 0;
  my $sr = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) };
  if ( $sr && ref($sr) eq 'HASH' ) {
    for my $s ( @{ nimble_data_as_list( $sr->{ data } ) } ) {
      next unless ref($s) eq 'HASH';
      my $copy = { %$s };
      if ( !length( nimble_snapshot_effective_vol_name( $copy, undef ) ) ) {
        my $vid = $copy->{ vol_id };
        if ( defined $vid && length($vid) && $vol_id_to_fullname{ $vid } ) {
          $copy->{ vol_name } = $vol_id_to_fullname{ $vid };
        }
      }
      push @snaps, $copy;
    }
  } else {
    for my $full_name ( keys %vol_map ) {
      my $vid = $vol_map{ $full_name }{ id };
      next unless defined $vid && length($vid);
      my $enc = uri_escape($vid);
      my $r   = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc", undef, $storeid ) };
      if ( !$r || ref($r) ne 'HASH' ) {
        $fetch_incomplete = 1;
      }
      next unless $r && ref($r) eq 'HASH';
      for my $s ( @{ nimble_data_as_list( $r->{ data } ) } ) {
        next unless ref($s) eq 'HASH';
        my $copy = { %$s };
        if ( !length( nimble_snapshot_effective_vol_name( $copy, undef ) ) ) {
          $copy->{ vol_name } = $full_name;
        }
        push @snaps, $copy;
      }
    }
    print "Debug :: nimble_sync [$storeid]: bulk GET snapshots unavailable; merged "
      . scalar(@snaps)
      . " snapshot(s) from per-volume GET\n" if $debug >= 1;
  }
  print "Debug :: nimble_sync [$storeid]: " . scalar(@snaps) . " total array snapshots (after fetch)\n" if $debug >= 1;
  my $snaps = \@snaps;
  nimble_hydrate_snapshots_missing_display_time( $scfg, $storeid, $snaps );
  print "Debug :: nimble_sync [$storeid]: hydrated snapshot detail for Nimble creation_time when list rows omitted it\n" if $debug >= 2;

  # Group: vmid => full_vol_name => [ { id, name, creation_time }, ... ]
  my %by_vmid;
  for my $s ( @$snaps ) {
    my $vname = nimble_snapshot_effective_vol_name( $s, undef );
    next unless length($vname) && exists $vol_map{ $vname };
    next
      if nimble_array_snapshot_is_pve_ui_snapshot( $scfg, $vol_map{ $vname }{ volname }, $s->{ name } // '' );
    my $vmid = $vol_map{ $vname }{ vmid };
    my $ctime = nimble_snapshot_effective_creation_time($s);
    push @{ $by_vmid{ $vmid }{ $vname } }, {
      id            => $s->{ id },
      name          => $s->{ name },
      creation_time => $ctime,
      display_epoch => nimble_snapshot_display_epoch($s),
    };
  }
  return unless %by_vmid;

  for my $vmid ( sort keys %by_vmid ) {
    # Skips CT IDs: PVE::QemuConfig->load_config dies for LXC containers; snapshot sync is QEMU-only.
    # Sorted (not raw hash key order) so the seed volume below is stable across repeated status() calls.
    my @vm_vols = sort grep { $vol_map{ $_ }{ vmid } eq $vmid } keys %vol_map;

    # Find consistent snapshot groups: all volumes for this VM covered within 60s.
    # Seed from first volume's snapshots and verify every other volume has a match.
    my %seen;
    my @groups;
    my ($seed_vol) = grep { exists $by_vmid{$vmid}{$_} } @vm_vols;
    my $seed_snaps = defined($seed_vol) ? ($by_vmid{$vmid}{$seed_vol} // []) : [];
    # PVE shows snaptime as calendar time; id-hash identity keys (nimble1xxxxx) are not Unix epochs.
    my $snaptime_fallback = time();

    for my $seed ( @$seed_snaps ) {
      my $ts = $seed->{ creation_time };
      next if $seen{ $ts }++;
      my $ok     = 1;
      my $min_ts = $ts;
      my $gui    = $seed->{ display_epoch };
      my @nimble_snap_names;
      if ( defined $seed_vol ) {
        my $sn = $seed->{ name };
        push @nimble_snap_names, "$seed_vol: $sn" if defined $sn && length $sn;
      }
      for my $vname ( @vm_vols ) {
        next if defined($seed_vol) && $vname eq $seed_vol;
        unless ( exists $by_vmid{$vmid}{$vname} ) { $ok = 0; last; }
        my $best;
        for my $vs ( @{ $by_vmid{ $vmid }{ $vname } // [] } ) {
          my $d = abs( $vs->{ creation_time } - $ts );
          $best = $vs if $d <= 60 && ( !$best || $d < abs( $best->{ creation_time } - $ts ) );
        }
        if ( $best ) {
          $min_ts = $best->{ creation_time } if $best->{ creation_time } < $min_ts;
          if ( defined $best->{ display_epoch } ) {
            $gui = $best->{ display_epoch } if !defined $gui || $best->{ display_epoch } < $gui;
          }
          my $sn = $best->{ name };
          push @nimble_snap_names, "$vname: $sn" if defined $sn && length $sn;
        } else {
          $ok = 0; last;
        }
      }
      if ($ok) {
        my $snaptime = defined $gui ? $gui
          : ( $min_ts >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH ? $min_ts : $snaptime_fallback );
        # Suffix must match what rollback resolves: snaptime uses min display epoch ($gui) when set, but we
        # previously used min_ts (min effective), so nimble<min_ts> did not match hydrated API times.
        my $pve_suffix = ( defined $gui && $gui >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH ) ? $gui : $min_ts;
        my $desc = '';
        if (@nimble_snap_names) {
          my %seen_name;
          @nimble_snap_names = grep { !$seen_name{$_}++ } @nimble_snap_names;
          $desc = join( '; ', @nimble_snap_names );
        }
        push @groups, { pve_name => "nimble${pve_suffix}", snaptime => $snaptime, description => $desc };
      }
    }

    my %nimble_names = map { $_->{ pve_name } => 1 } @groups;

    eval {
      PVE::QemuConfig->lock_config( $vmid, sub {
        my $conf   = PVE::QemuConfig->load_config( $vmid );
        my $psnaps = $conf->{ snapshots } //= {};
        my $changed = 0;

        # Add snapshot entries not yet in PVE; fix snaptime when older imports used id-hash as Unix time.
        for my $g ( @groups ) {
          my $pve_name = $g->{ pve_name };
          my $new_st   = $g->{ snaptime };
          if ( exists $psnaps->{ $pve_name } ) {
            my $old_st = $psnaps->{ $pve_name }{ snaptime };
            $old_st = defined $old_st ? int( 0 + $old_st ) : 0;
            if ( $new_st >= NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH && $old_st < NIMBLE_SNAPSHOT_PLAUSIBLE_EPOCH ) {
              $psnaps->{ $pve_name }{ snaptime } = $new_st;
              $changed = 1;
            }
            my $want_desc = $g->{ description } // '';
            if ( length $want_desc ) {
              my $cur = $psnaps->{ $pve_name }{ description };
              $cur = defined $cur ? "$cur" : '';
              my $legacy_generic = ( $cur =~ /^\s*imported\s+from\s+nimble\s+array\s*$/i );
              if ( ( $legacy_generic || $cur eq '' ) && $cur ne $want_desc ) {
                $psnaps->{ $pve_name }{ description } = $want_desc;
                $changed = 1;
              }
            }
            next;
          }
          # Snapshot section mirrors current live config (best available record of state at snap time)
          my $entry = { snaptime => $new_st, description => ( $g->{ description } // '' ) };
          for my $k ( keys %$conf ) {
            next if $k eq 'snapshots' || $k eq 'snapstate' || $k eq 'lock' || $k eq 'pending';
            next if ref( $conf->{ $k } );
            $entry->{ $k } = $conf->{ $k };
          }
          $psnaps->{ $pve_name } = $entry;
          $changed = 1;
        }

        # Remove stale imported entries whose Nimble snapshot no longer exists — but only entries
        # THIS storage created. A VM can have disks on several Nimble storages (or two storeids on
        # one array); each storage's sync only sees its own volumes, so an unscoped delete would
        # remove the other storage's imports every 30s (add/delete flip-flop between the two syncs).
        # Ownership test: our import descriptions list "<full array volume name>: <snap name>" pairs
        # for volumes in this storage's %vol_map. Entries without a matching description (including
        # legacy generic "Imported from Nimble array" ones) are left alone. Skipped entirely when
        # this round's snapshot fetch was partial ($fetch_incomplete).
        if ( !$fetch_incomplete ) {
          for my $sname ( keys %$psnaps ) {
            next unless $sname =~ /^nimble\d+$/;
            next if $nimble_names{ $sname };
            my $desc = $psnaps->{ $sname }{ description };
            $desc = defined $desc ? "$desc" : '';
            my $ours = 0;
            for my $fvn (@vm_vols) {
              if ( $desc =~ /(?:^|;\s*)\Q$fvn\E:/ ) { $ours = 1; last; }
            }
            next unless $ours;
            delete $psnaps->{ $sname };
            $changed = 1;
          }
        }

        if ( $changed ) {
          PVE::QemuConfig->write_config( $vmid, $conf );
          print "Debug :: nimble_sync [$storeid]: vmid $vmid config updated\n" if $debug >= 1;
        }
      } );
    };
    warn "Warning :: Nimble snapshot sync vmid $vmid: $@" if $@;
  }
}

sub list_images {
  my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
  set_debug_from_config( $scfg );
  if ( ref($cache) eq 'HASH' ) {
    $cache->{nimble}{$storeid} //= $class->nimble_list_volumes( $scfg, undef, $storeid, undef );
    my $all = $cache->{nimble}{$storeid};
    if ( defined($vollist) && ref($vollist) eq 'ARRAY' ) {
      my %want = map { $_ => 1 } @$vollist;
      return [ grep { $want{ $_->{ volid } } } @$all ];
    }
    return [ grep { defined $_->{ vmid } && "$_->{ vmid }" eq "$vmid" } @$all ] if defined $vmid;
    return [@$all];
  }
  return $class->nimble_list_volumes( $scfg, $vmid, $storeid, $vollist );
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
  my ( $total, $used ) = ( 0, 0 );
  eval {
    my $r    = nimble_api_call( $scfg, 'GET', 'pools', undef, $storeid );
    my $list = nimble_data_as_list( $r->{ data } );
    my @pools = grep { ref($_) eq 'HASH' } @$list;
    for my $p (@pools) {
      nimble_hydrate_pool_for_capacity( $scfg, $storeid, $p );
    }
    my $want = $scfg->{ nimble_pool_name };
    my @use = @pools;
    if ( defined $want && $want ne '' ) {
      my @m = grep { nimble_pool_identifier_matches_want( $_, $want ) } @pools;
      if (@m) {
        @use = @m;
      }
      else {
        warn "Warning :: Nimble storage \"$storeid\" status: nimble_pool_name \"$want\" not found in pools list; using all pools.\n";
      }
    }
    for my $p (@use) {
      $total += nimble_pool_capacity_bytes($p);
      $used  += nimble_pool_used_bytes($p);
    }
    if ( $total <= 0 ) {
      my ( $at, $au ) = nimble_status_arrays_fallback_bytes( $scfg, $storeid, $scfg->{ nimble_pool_name }, \@use );
      if ( $at > 0 ) {
        $total = $at;
        # Always take fallback usage (may be 0); avoids leaving stale pool-path $used when $total was 0 before fallback.
        $used = $au;
      }
    }
    $used = $total if $used > $total;
    1;
  };
  if ( my $err = $@ ) {
    chomp($err);
    warn "Warning :: Nimble storage \"$storeid\" status (pools API): $err\n";
    # Inactive storage: active=0; totals zero (PVE treats inactive without requiring a fake 1-byte total).
    return ( 0, 0, 0, 0 );
  }
  my $free = $total - $used;
  $free = 0 if $free < 0;

  # Periodic import of array-created snapshots into PVE VM configs (throttled to 30s per storage).
  # Timestamp is always updated after each attempt (success or failure) to prevent hammering
  # the Nimble API and pvestatd when the array is unreachable or a VM config is locked.
  # status() runs inside pvestatd's sequential loop for ALL storages on the node — the sync makes
  # many API calls (each with a 30s LWP timeout), so it gets a hard wall-clock budget. On timeout
  # this round's partial work is discarded and retried at the next throttle window.
  my $ts_file = "/var/run/pve-nimble-sync-${storeid}.ts";
  my $last    = 0;
  if ( open my $fh, '<', $ts_file ) { $last = <$fh> // 0; chomp $last; close $fh; }
  if ( time() - $last >= 30 ) {
    eval { PVE::Tools::run_with_timeout( 25, sub { nimble_sync_array_snapshots( $scfg, $storeid ) } ) };
    warn "Warning :: Nimble snapshot sync: $@" if $@;
    my $tmp = "$ts_file.tmp.$$";
    if ( open my $fh, '>', $tmp ) {
      print $fh time();
      close $fh;
      rename( $tmp, $ts_file );
    }
  }

  eval { __PACKAGE__->nimble_iscsi_refresh_baseline_if_due( $storeid, $scfg ); };

  return ( $total, $free, $used, 1 );
}

# Activate-time discovery: on by default; only no/0 disables (missing key = on for legacy configs).
sub nimble_auto_iscsi_discovery_enabled {
  my ($scfg) = @_;
  return 0 unless ref($scfg) eq 'HASH';
  my $v = $scfg->{ nimble_auto_iscsi_discovery };
  return 1 if !defined($v);
  my $s = "$v";
  return 0 if $s eq '0' || $s eq 'no';
  return 1;
}

# Throttled Pure-style iSCSI baseline refresh (sendtargets + per-portal login if dropped).
# Called from status() (pvestatd) AND activate_storage — one 60s throttle covers both, so repeated
# VM starts / status cycles don't each pay a discovery round-trip. The ts file is written BEFORE the
# work: a failing attempt (array unreachable, no portals) is throttled the same as a successful one,
# instead of retrying on every 10s pvestatd cycle. /var/run is tmpfs, so the first call after boot
# always runs. Hard wall-clock budget for the same pvestatd-stall reason as the snapshot sync.
sub nimble_iscsi_refresh_baseline_if_due {
  my ( $class, $storeid, $scfg ) = @_;
  return unless nimble_auto_iscsi_discovery_enabled($scfg);
  my $ts_file = "/var/run/pve-nimble-iscsi-${storeid}.ts";
  my $last    = 0;
  if ( open my $fh, '<', $ts_file ) { $last = <$fh> // 0; chomp $last; close $fh; }
  return if time() - $last < 60;
  my $tmp = "$ts_file.tmp.$$";
  if ( open my $fh, '>', $tmp ) {
    print $fh time();
    close $fh;
    rename( $tmp, $ts_file );
  }
  eval {
    PVE::Tools::run_with_timeout( 30, sub {
      my $ig_ok = eval { nimble_ensure_initiator_group_id( $scfg, $storeid ); 1 };
      if ( !$ig_ok ) {
        chomp( my $err = $@ );
        warn "Warning :: Auto iSCSI discovery skipped for storage \"$storeid\": initiator group could not be ensured ($err). Install open-iscsi and set InitiatorName in /etc/iscsi/initiatorname.iscsi, or set initiator_group to an existing group.\n";
        return;
      }
      my @ips = get_nimble_iscsi_discovery_ips( $scfg, $storeid );
      if ( !@ips ) {
        warn "Warning :: No iSCSI discovery portals from Nimble API for storage \"$storeid\" (GET v1/subnets plus GET v1/subnets/:id per subnet; prefer subnets whose type includes data and discovery_ip is set). Skipping discovery. Check HTTPS/API access from this host and subnet configuration on the array.\n";
        return;
      }
      run_iscsi_discovery_and_login( $storeid, $scfg, \@ips );
    } );
  };
  warn "Warning :: iSCSI baseline refresh for \"$storeid\": $@\n" if $@;
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
  # PureStoragePlugin::activate_storage only returns 1; Nimble ensures host iSCSI baseline on activate
  # unless disabled. Shares the 60s throttle with status(): activate_storage runs before every volume
  # operation (each VM start, migration prep, vdisk alloc), and an unthrottled discovery round-trip
  # added seconds to each. Per-volume session establishment in activate_volume/map_volume covers any
  # gap within the window; the first call after boot always runs (ts file lives on tmpfs).
  $class->nimble_iscsi_refresh_baseline_if_due( $storeid, $scfg );
  nimble_multipath_restore_aliases($storeid);
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
  my $serial = $volume->{ serial };
  my $target_raw = $volume->{ target_name } // '';
  my $target_iqn = nimble_untaint_iscsiadm_scalar($target_raw);
  if ( length($target_raw) && !length($target_iqn) ) {
    warn "Warning :: Volume \"$volname\" target_name is not usable for iscsiadm (sanitization failed); check Nimble API target_name.\n";
  }
  # Session should already be up from nimble_volume_connection (activate_volume path).
  # If not (called directly, session dropped, or multipath path missing), establish now.
  if ( length($target_iqn) ) {
    my @vol_portals = nimble_iscsi_node_portals_for_target($target_iqn);
    my $need_session = @vol_portals
      ? !nimble_iscsi_all_portals_in_sessions( $target_iqn, \@vol_portals, 0 )
      : !nimble_iscsi_target_in_sessions( $target_iqn, 0 );
    if ($need_session) {
      print "Info :: iSCSI session incomplete for \"$target_iqn\" at map time; attempting connect.\n";
      $class->nimble_iscsi_establish_volume_session( $scfg, $volname, $storeid );
    }
  }
  elsif ( !length($target_iqn) ) {
    warn "Warning :: Volume \"$volname\" has no target_name (iSCSI IQN) from Nimble API.\n";
  }
  # Like the GUI after attaching a LUN: rescan active iSCSI sessions so new LUNs appear without waiting only on sysfs scan.
  eval {
    my $adm = nimble_iscsiadm_path();
    run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 120, quiet => 1 ) if -x $adm;
  };
  eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
  eval { scsi_scan_new( 'iscsi' ); };
  warn "Warning :: iSCSI host scan failed: $@" if $@;
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=30' ] ); };
  my $wait_ticks = 0;
  wait_for(
    sub {
      ++$wait_ticks;
      if ( $wait_ticks % 100 == 0 ) {
        eval { scsi_scan_new('iscsi'); };
      }
      # Sessions up but LUN/multipath slow: periodic rescan + multipath refresh (migration target).
      if ( $wait_ticks % 50 == 0 ) {
        eval {
          my $adm = nimble_iscsiadm_path();
          run_command( [ $adm, '-m', 'session', '--rescan' ], timeout => 90, quiet => 1 ) if -x $adm;
        };
        eval { exec_command( [ get_command_path('multipath'), '-v2' ], -1, timeout => 60 ); };
      }
      my ( $p, $w ) = get_device_path_by_serial( $serial );
      return length($p) && -e $p;
    },
    "volume \"$volname\" to appear (API serial "
      . $serial
      . (
      length($target_iqn)
      ? "; IQN $target_iqn"
      : ''
      )
      . "; stuck: see prior Nimble iSCSI warnings for portals tried / iscsiadm errors, then iscsiadm -m session, ACL, data-network)",
    180
  );
  my ( $path, $wwid ) = get_device_path_by_serial( $serial );
  die "Error :: Volume \"$volname\" device did not appear after rescan (serial $serial"
    . ( length($target_iqn) ? "; IQN $target_iqn" : '' )
    . "). See task log for portals tried and iscsiadm errors above.\n"
    unless length($path) && -b $path;
  $path = nimble_untaint_dev_path($path) || $path;
  if ( length( $wwid ) && !multipath_check( $wwid ) ) {
    for my $w ( nimble_multipath_wwid_try_list($wwid) ) {
      eval { exec_command( [ 'multipathd', 'add', 'map', $w ], -1, timeout => 30 ); };
      last if multipath_check( $wwid );
    }
    my $mp_ready = sub { return multipath_check( $wwid ) };
    wait_for( $mp_ready, "multipath for \"$volname\"", 45 );
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
      wait_for( $mp_ready, "multipath for \"$volname\"", 45 );
    }
  }
  $path = nimble_untaint_dev_path($path) || $path;
  nimble_multipath_register( $storeid, $volname, $wwid ) if length($wwid);
  return $path;
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  my ( $path, $wwid ) = $class->get_device_path_wwid( $scfg, $volname, $storeid );
  return 0 unless length( $path ) && -b $path;
  $path = nimble_untaint_dev_path($path) || return 0;
  my ( $device_path, @slaves ) = eval { block_device_slaves( $path ) };
  if ( $@ ) {
    warn "Warning :: unmap_volume: block_device_slaves failed for \"$path\": $@\n";
    return 0;
  }
  $device_path = nimble_untaint_dev_path($device_path) || $device_path;
  exec_command( ['sync'] );
  exec_command( [ 'blockdev', '--flushbufs', $device_path ] );
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=10' ] ) };
  exec_command( ['sync'] );

  if ( length( $wwid ) ) {
    nimble_multipath_teardown_for_unmap($wwid);
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
  my ( $class, $scfg, $storeid, $volname, $size, $running, $snapname ) = @_;
  if ( defined($snapname) && length($snapname) ) {
    die "Error :: Resizing a snapshot is not supported on Nimble storage (no snapshot-as-volume-chain).\n";
  }
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
  # Nimble's per-volume target_name embeds the volume name, so it changes with the rename. Log out
  # the old IQN first (while nimble_get_volume_info can still resolve the old name) — otherwise the
  # node keeps a stale session + node-db records for a target that no longer exists.
  eval { nimble_iscsi_logout_volume_local( $class, $scfg, $source_volname, $storeid ); };
  $class->nimble_rename_volume( $scfg, $storeid, $source_volname, $target_volname );
  nimble_multipath_rename_cache_entry( $storeid, $source_volname, $target_volname );
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

sub volume_rollback_is_possible {
  my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;
  my $ok = eval {
    my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
    die "Error :: Volume \"$volname\" not found\n" unless $vol_id;

    if ( $snap =~ /^nimble(\d+)$/ ) {
      my $target_ts = $1;
      my $enc_vid = uri_escape($vol_id);
      my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc_vid", undef, $storeid ) };
      $r = eval { nimble_api_call( $scfg, 'GET', 'snapshots', undef, $storeid ) } unless $r;
      die "Error :: Could not query snapshots for volume \"$volname\"\n" unless $r;
      my $list = nimble_data_as_list( $r->{ data } );
      my ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $target_ts, $list );
      if ( !$best ) {
        my $alt = nimble_vm_snaptime_from_qemu_conf( $volname, $snap );
        if ( defined $alt && $alt != $target_ts ) {
          ( $best, $best_d ) = nimble_best_snapshot_row_for_nimble_target_ts( $scfg, $storeid, $vol_id, $alt, $list );
        }
      }
      die "Error :: Snapshot \"$snap\" not found for volume \"$volname\"\n" unless $best;
    } else {
      my $snap_full = nimble_volname( $scfg, $volname, $snap );
      my $enc  = uri_escape( $snap_full );
      my $r    = nimble_api_call( $scfg, 'GET', "snapshots?name=$enc", undef, $storeid );
      my $list = nimble_data_as_list( $r->{ data } );
      my $found = 0;
      for my $s ( @$list ) {
        if ( ( $s->{ name } // '' ) eq $snap_full ) { $found = 1; last; }
      }
      die "Error :: Snapshot \"$snap\" not found for volume \"$volname\"\n" unless $found;
    }
    1;
  };

  if ( !$ok ) {
    push @$blockers, $snap if ref($blockers) eq 'ARRAY';
    return 0;
  }
  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  $class->nimble_snapshot_delete( $scfg, $storeid, $volname, $snap );
  return 1;
}

# Nimble snapshot size is in MB; PVE virtual-size is bytes (volume size at snap time).
sub nimble_snapshot_virtual_size_bytes {
  my ( $snap ) = @_;
  return undef unless ref($snap) eq 'HASH';
  my $size_mb = $snap->{ size };
  return undef if !defined($size_mb) || $size_mb eq '';
  $size_mb = 0 + $size_mb;
  return undef if $size_mb <= 0;
  return int( $size_mb ) * 1024 * 1024;
}

# Returns { $pve_snapname => { id => $nimble_uuid, timestamp => $epoch, virtual-size => $bytes }, ... }
# for all snapshots on this volume. PVE-created snaps are reverse-mapped from the array name
# (prefix+volname+.snap-name); array-created snaps fall back to nimble<epoch> (nimble_sync_array_snapshots).
sub volume_snapshot_info {
  my ( $class, $scfg, $storeid, $volname ) = @_;
  my ( $vol_id ) = nimble_get_volume_id( $scfg, $volname, $storeid );
  return {} unless $vol_id;
  my $enc_vid = uri_escape($vol_id);
  my $r = eval { nimble_api_call( $scfg, 'GET', "snapshots?vol_id=$enc_vid", undef, $storeid ) };
  return {} unless $r;
  my $list = nimble_data_as_list( $r->{ data } );
  # Compute the array-side base name once using the actual array volume name (handles
  # prefix-less volumes that were created before nimble_vnprefix was configured).
  my $sep = nimble_actual_array_volname( $scfg, $volname, undef, $storeid ) . '.';
  my %info;
  my %snap_coll_cache;
  for my $s ( @$list ) {
    next if nimble_snapshot_row_volume_id_mismatch( $s, $vol_id );
    if ( !nimble_snapshot_display_epoch($s) || !defined nimble_snapshot_virtual_size_bytes($s) ) {
      eval { nimble_hydrate_snapshot_detail( $scfg, $storeid, $s, \%snap_coll_cache ) };
    }
    my $array_name = $s->{ name } // '';
    my $ts_id      = nimble_snapshot_effective_creation_time($s);
    my $ts_gui     = nimble_snapshot_display_epoch($s);
    my $id         = $s->{ id } // '';
    my $pve_name;
    if ( index( $array_name, $sep ) == 0 ) {
      my $suffix = substr( $array_name, length($sep) );
      if ( $suffix =~ /^snap-(.+)$/ ) {
        $pve_name = $1;
        $pve_name =~ s/^veeam-/veeam_/;  # reverse nimble_volname's veeam_ → veeam- substitution
      }
    }
    $pve_name //= "nimble${ts_id}";
    my $entry = { id => $id, timestamp => ( $ts_gui // $ts_id ) };
    my $virtual_size = nimble_snapshot_virtual_size_bytes($s);
    $entry->{'virtual-size'} = $virtual_size if defined $virtual_size;
    $info{ $pve_name } = $entry;
  }
  return \%info;
}

# Stable backend identity for this storage definition (PVE storage API 14).
# Prefer GET arrays id (scoped by pool_name like status()); fallback to address when arrays API fails.
# Two storage.cfg entries for the same array with different DNS names may get different address fallbacks.
sub get_identity {
  my ( $class, $scfg, $storeid ) = @_;
  my @use_pools;
  my $want = $scfg->{ nimble_pool_name };
  my $pr   = eval { nimble_api_call( $scfg, 'GET', 'pools', undef, $storeid ) };
  if ($pr) {
    my @pools = grep { ref($_) eq 'HASH' } @{ nimble_data_as_list( $pr->{ data } ) };
    @use_pools = @pools;
    if ( defined $want && $want ne '' ) {
      my @m = grep { nimble_pool_identifier_matches_want( $_, $want ) } @pools;
      @use_pools = @m if @m;
    }
  }
  my $r = eval { nimble_api_call( $scfg, 'GET', 'arrays', undef, $storeid ) };
  if ($r) {
    my $list = nimble_data_as_list( $r->{ data } );
    my @rows = grep { ref($_) eq 'HASH' } @$list;
    if ( defined $want && $want ne '' ) {
      @rows = grep { nimble_array_matches_status_pools( $_, $want, \@use_pools ) } @rows;
    }
    @rows = sort { ( $a->{ id } // '' ) cmp ( $b->{ id } // '' ) } @rows;
    for my $a (@rows) {
      my $ident = nimble_array_identity_from_row($a);
      return $ident if defined $ident;
    }
  }
  my $addr = $scfg->{ nimble_address } // '';
  return "nimble:$addr" if length($addr);
  die "Error :: Could not determine Nimble array identity (arrays API unavailable and no address in storage config).\n";
}

sub rename_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap, $newsnapname ) = @_;
  die "Error :: rename_snapshot is not supported.\n";
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

# Tell PVE/QEMU to use storage-side snapshots rather than QEMU internal snapshots (APIVER 12).
sub volume_qemu_snapshot_method {
  my ( $class, $scfg, $storeid, $volname ) = @_;
  return 'storage';
}

# Return QEMU blockdev options for this volume (APIVER 12). Nimble volumes are raw block devices;
# the host_device driver is the correct QEMU driver for mapped iSCSI/multipath block nodes.
# Nimble array snapshots are not host-attachable block devices, so a snapshot blockdev request must
# die rather than fall through to the live volume's device — silently attaching the current state
# under a snapshot's name would hand QEMU the wrong data.
sub qemu_blockdev_options {
  my ( $class, $scfg, $storeid, $volname, $machine_version, $options ) = @_;
  my $snap = ref($options) eq 'HASH' ? $options->{'snapshot-name'} : undef;
  die "Error :: cannot attach a snapshot of a Nimble volume as a block device (snapshot \"$snap\" of \"$volname\").\n"
    if defined $snap && length $snap;
  my $path = $class->filesystem_path( $scfg, $volname, undef, $storeid );
  return undef unless length($path) && -b $path;
  return { driver => 'host_device', filename => $path };
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
      die "Error :: volume_import: read failed after " . ( $size_bytes - $remaining ) . " bytes.\n" if !defined $got;
      last if $got == 0;
      my $w = syswrite( $dev, $buf, $got );
      die "Error :: volume_import: write failed after " . ( $size_bytes - $remaining ) . " bytes.\n" if !defined $w || $w != $got;
      $remaining -= $got;
    }
    die "Error :: volume_import: unexpected end of input after " . ( $size_bytes - $remaining ) . " of $size_bytes bytes.\n"
      if $remaining > 0;
    close( $dev );
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( my $err = $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    eval { $class->nimble_remove_volume( $scfg, $volname, $storeid ); };
    die $err;
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
      die "Error :: volume_export: read failed after " . ( $size_bytes - $remaining ) . " bytes.\n" if !defined $got;
      last if $got == 0;
      print $fh $buf or die "Error :: volume_export: write to stream failed after " . ( $size_bytes - $remaining ) . " bytes.\n";
      $remaining -= $got;
    }
    die "Error :: volume_export: unexpected end of device after " . ( $size_bytes - $remaining ) . " of $size_bytes bytes.\n"
      if $remaining > 0;
    close( $dev );
    $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} );
  };
  if ( my $err = $@ ) {
    eval { $class->deactivate_volume( $storeid, $scfg, $volname, undef, {} ); };
    die $err;
  }
  return 1;
}

# PVE::API2::Storage::Config: on_update_hook_full($storeid, $scfg, $opts, $delete, $sensitive)
# Mirror password to priv .pw when operators still rely on file-based secrets; cfg is authoritative for API.
sub on_update_hook_full {
  my ( $class, $storeid, $scfg, $opts, $delete, $sensitive ) = @_;
  $opts      //= {};
  $delete    //= [];
  $sensitive //= {};
  my %del = map { $_ => 1 } @$delete;

  if ( exists $opts->{ password } ) {
    my $pw = $opts->{ password };
    if ( defined($pw) && $pw ne '' ) {
      nimble_set_password( $storeid, $pw );
    }
    else {
      nimble_delete_password_file($storeid);
    }
  }
  elsif ( $del{ password } ) {
    nimble_delete_password_file($storeid);
  }
  elsif ( exists $sensitive->{ password } ) {
    my $pw = $sensitive->{ password };
    if ( defined($pw) && $pw ne '' ) {
      nimble_set_password( $storeid, $pw );
    }
    else {
      nimble_delete_password_file($storeid);
    }
  }
  return;
}

1;
