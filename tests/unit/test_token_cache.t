#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 15;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use JSON;

# Create temporary cache directory
my $cache_dir = tempdir( CLEANUP => 1 );

# Mock functions from plugin (Nimble: single cache per storeid, session_token)
sub get_token_cache_path {
  my ( $storeid ) = @_;
  my $dir = "$cache_dir/nimble";
  make_path($dir) unless -d $dir;
  chmod 0700, $dir;
  return "$dir/${storeid}.json";
}

sub write_token_cache {
  my ( $cache_path, $token_data ) = @_;

  my $temp_path = "$cache_path.tmp.$$";
  open my $fh, '>', $temp_path or die "Cannot write to $temp_path: $!";
  print $fh encode_json($token_data);
  close $fh;

  chmod 0600, $temp_path;
  rename $temp_path, $cache_path or die "Cannot rename $temp_path to $cache_path: $!";
}

sub read_token_cache {
  my ( $cache_path ) = @_;

  return undef unless -f $cache_path;

  open my $fh, '<', $cache_path or return undef;
  my $content = do { local $/; <$fh> };
  close $fh;

  return undef unless $content;

  my $data = eval { decode_json($content) };
  return undef if $@;

  return $data;
}

sub is_token_valid {
  my ( $token_data, $ttl ) = @_;

  return 0 unless defined $token_data;
  return 0 unless defined $token_data->{session_token};
  return 0 unless defined $token_data->{created_at};

  my $now = time();
  my $age = $now - $token_data->{created_at};
  my $refresh_threshold = $ttl * 0.8;

  return $age < $refresh_threshold;
}

# Test 1: Cache directory creation
my $cache_path = get_token_cache_path('nimble1');
ok( -d "$cache_dir/nimble", 'Cache directory created' );

# Test 2: Cache directory permissions
my $mode = (stat("$cache_dir/nimble"))[2] & 0777;
is( $mode, 0700, 'Cache directory has correct permissions (700)' );

# Test 3: Write token cache
my $token_data = {
  session_token => 'test-session-token-12345',
  created_at    => time(),
  ttl           => 3600,
  expires_at    => time() + 3600
};

write_token_cache($cache_path, $token_data);
ok( -f $cache_path, 'Token cache file created' );

# Test 4: Cache file permissions
$mode = (stat($cache_path))[2] & 0777;
is( $mode, 0600, 'Cache file has correct permissions (600)' );

# Test 5: Read token cache
my $read_data = read_token_cache($cache_path);
ok( defined $read_data, 'Token cache read successfully' );

# Test 6: Verify token data
is( $read_data->{session_token}, 'test-session-token-12345', 'Session token matches' );

# Test 7: Valid token (fresh)
ok( is_token_valid($read_data, 3600), 'Fresh token is valid' );

# Test 8: Valid token at 79% of TTL
$token_data->{created_at} = time() - (3600 * 0.79);
write_token_cache($cache_path, $token_data);
$read_data = read_token_cache($cache_path);
ok( is_token_valid($read_data, 3600), 'Token at 79% TTL is still valid' );

# Test 9: Invalid token at 81% of TTL
$token_data->{created_at} = time() - (3600 * 0.81);
write_token_cache($cache_path, $token_data);
$read_data = read_token_cache($cache_path);
ok( !is_token_valid($read_data, 3600), 'Token at 81% TTL is invalid' );

# Test 10: Multiple storage caches
my $cache_path_2 = get_token_cache_path('nimble2');
write_token_cache($cache_path_2, $token_data);
ok( -f $cache_path_2, 'Second storage cache created' );
isnt( $cache_path, $cache_path_2, 'Different cache files for different storage' );

# Test 11: Read non-existent cache
my $missing_cache = read_token_cache("$cache_dir/nonexistent.json");
is( $missing_cache, undef, 'Non-existent cache returns undef' );

# Test 12: Invalid JSON in cache
my $corrupt_cache = "$cache_dir/nimble/corrupt.json";
open my $fh, '>', $corrupt_cache;
print $fh "{ invalid json }";
close $fh;
my $corrupt_data = read_token_cache($corrupt_cache);
is( $corrupt_data, undef, 'Corrupt cache returns undef' );

# Test 13: Missing required fields
my $incomplete_data = { session_token => 'test' };  # Missing created_at
ok( !is_token_valid($incomplete_data, 3600), 'Incomplete token data is invalid' );

# Test 14: Cache path format
like( $cache_path, qr/\/nimble1\.json$/, 'Cache path follows expected format (storeid.json)' );

done_testing();
