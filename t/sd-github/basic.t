#!/usr/bin/perl -w

use strict;
use warnings;
use Prophet::Test;

BEGIN {
    plan skip_all => "Tests require Net::GitHub 0.44"
      unless eval { require Net::GitHub; Net::GitHub->VERSION(0.44); 1 };

    if ( !exists $ENV{GITHUB_USER} || !exists $ENV{GITHUB_PASS} ) {
        plan skip_all =>
          'You need to set GITHUB_USER and GITHUB_PASS for these tests to run';
    }

    if ( !exists $ENV{GITHUB_URL} ) {
        plan skip_all =>
          'You need to set GITHUB_URL: e.g "owner/repo", "https://github.com/owner/repo", "git@github.com:owner/repo.git"';
    }

}

plan tests => 8;
use App::SD::Test;

BEGIN {
    require File::Temp;
    $ENV{'PROPHET_REPO'} = $ENV{'SD_REPO'} =
      File::Temp::tempdir( CLEANUP => 1 ) . '/_svb';
    diag "export SD_REPO=" . $ENV{'PROPHET_REPO'} . "\n";
}

my $sd_github_url = "github:" . $ENV{GITHUB_URL};

my ( $ret, $out, $err );
( $ret, $out, $err ) =
  run_script( 'sd',
    [ 'clone', '--from', $sd_github_url, '--non-interactive' ] );
my $first_id;

diag($err) if ($err);
run_output_matches(
    'sd',
    [ 'ticket', 'list', '--regex', 'test for sd' ],
    [qr/(.*?)(?{ $first_id = $1 }) test for sd/]
);

( $ret, $out, $err ) = run_script( 'sd', [ 'ticket', 'comments', $first_id ] );
like( $out, qr/first comment.*second comment/s, 'comments pulled' );

( $ret, $out, $err ) =
  run_script( 'sd', [ 'pull', '--from', $sd_github_url ] );
diag($err);

run_script( 'sd',
    [ 'ticket', 'comment', $first_id, '-m', 'comment from sd' ] );

my $yatta_id;
run_output_matches(
    'sd',
    [ 'ticket', 'create', '--', '--summary', 'YATTA', '--status', 'open' ],
    [qr/Created ticket (\d+)(?{ $yatta_id = $1 })/]
);

run_output_matches(
    'sd',
    [ 'ticket', 'list', '--regex', 'YATTA' ],
    [qr/(.*?)(?{ $yatta_id = $1 }) YATTA open/]
);

( $ret, $out, $err ) =
  run_script( 'sd', [ 'push', '--to', $sd_github_url, '--dry-run' ] );
diag($out);
diag($err);

like( $out, qr/"content" set to "comment from sd"/, 'comment pushed' );
like( $out, qr/"summary" set to "YATTA"/,           'ticket yatta pushed' );
unlike( $out, qr/test for sd/, 'pulled tickets not pushed' );
unlike(
    $out,
    qr/first comment.*second comment/s,
    'pulled comments not pushed'
);

