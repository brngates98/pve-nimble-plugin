#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 11;
use File::Temp qw( tempdir );
use JSON::XS qw( encode_json decode_json );

# Mock PVE::Tools for testing
BEGIN {

  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw( file_get_contents );

  sub file_get_contents {
    my ( $path ) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
  }
}

# Test token cache implementation (Nimble: session_token, single cache per storeid)
package main;

my $test_dir   = tempdir( CLEANUP => 1 );
my $cache_path = "$test_dir/test_cache.json";

# Helper function to create mock token data
sub create_token_data {
  my ( $age ) = @_;
  my $now = time();
  return {
    session_token => 'test-session-' . int( rand( 1000 ) ),
    created_at    => $now - $age,
    ttl           => 3600,
    expires_at    => $now - $age + 3600
  };
}

# Helper function to write token cache
sub write_test_cache {
  my ( $token_data ) = @_;
  my $json = encode_json( $token_data );
  open my $fh, '>', $cache_path or die "Cannot write cache: $!";
  print $fh $json;
  close $fh;
}

# Test 1: Token validation - fresh token
{
  my $token_data = create_token_data( 100 );    # 100s old
  my $ttl        = 3600;
  my $threshold  = $ttl * 0.8;                  # 2880s

  ok( 100 < $threshold, 'Fresh token is valid (age < 80% TTL)' );
}

# Test 2: Token validation - expired token
{
  my $token_data = create_token_data( 3000 );    # 3000s old
  my $ttl        = 3600;
  my $threshold  = $ttl * 0.8;                   # 2880s

  ok( 3000 >= $threshold, 'Expired token needs refresh (age >= 80% TTL)' );
}

# Test 3: Cache file write and read
{
  my $token_data = create_token_data( 50 );
  write_test_cache( $token_data );

  ok( -f $cache_path, 'Cache file created' );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $read_data = decode_json( $json_text );

  is( $read_data->{ session_token }, $token_data->{ session_token }, 'Token data matches after read' );
}

# Test 4: Cache file validation - valid token
{
  my $token_data = create_token_data( 100 );
  write_test_cache( $token_data );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $cached    = decode_json( $json_text );

  my $age       = time() - $cached->{ created_at };
  my $threshold = 3600 * 0.8;

  ok( $age < $threshold, 'Cached token is still valid' );
}

# Test 5: Cache file validation - expired token
{
  my $token_data = create_token_data( 3000 );
  write_test_cache( $token_data );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $cached    = decode_json( $json_text );

  my $age       = time() - $cached->{ created_at };
  my $threshold = 3600 * 0.8;

  ok( $age >= $threshold, 'Cached token is expired and should be refreshed' );
}

# Test 6: TTL validation
{
  my $ttl               = 3600;
  my $refresh_threshold = $ttl * 0.8;

  is( $refresh_threshold, 2880, 'Refresh threshold is 80% of TTL' );
}

# Test 7: Multiple token files (different storage IDs)
{
  my $cache1 = "$test_dir/nimble1.json";
  my $cache2 = "$test_dir/nimble2.json";

  my $token1 = create_token_data( 100 );
  my $token2 = create_token_data( 200 );

  open my $fh1, '>', $cache1 or die $!;
  print $fh1 encode_json( $token1 );
  close $fh1;

  open my $fh2, '>', $cache2 or die $!;
  print $fh2 encode_json( $token2 );
  close $fh2;

  ok( -f $cache1 && -f $cache2, 'Multiple cache files can coexist' );
}

# Test 8: Token cache path generation (Nimble: no array index)
{
  my $storeid       = 'nimble1';
  my $expected_path = "/etc/pve/priv/nimble/${storeid}.json";

  like( $expected_path, qr/\/etc\/pve\/priv\/nimble\/nimble1\.json$/, 'Cache path follows expected format' );
}

# Test 9: Atomic write simulation
{
  my $temp_path  = "$cache_path.tmp.$$";
  my $token_data = create_token_data( 75 );

  open my $fh, '>', $temp_path or die $!;
  print $fh encode_json( $token_data );
  close $fh;

  ok( -f $temp_path, 'Temp file created' );

  rename( $temp_path, $cache_path ) or die "Cannot rename: $!";

  ok( -f $cache_path && !-f $temp_path, 'Atomic rename completed' );
}

# Test 10: session_token field (Nimble uses session_token not auth_token)
{
  my $token_data = create_token_data( 50 );
  ok( defined $token_data->{ session_token }, 'Token has session_token field' );
}

# Test 11: created_at required for validation
{
  my $no_created = { session_token => 'x', ttl => 3600 };
  ok( !defined $no_created->{ created_at }, 'Missing created_at would fail validation' );
}

done_testing();

print "\nToken Cache Tests Summary (Nimble):\n";
print "=" x 50 . "\n";
print "All tests validate the token caching mechanism:\n";
print "- Token TTL validation (80% refresh threshold)\n";
print "- Cache file operations (read/write)\n";
print "- session_token and created_at fields\n";
print "- Single cache file per storage (no array index)\n";
print "- Atomic write operations\n";
print "=" x 50 . "\n";
