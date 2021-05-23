#!/usr/bin/env perl
use warnings;
use strict;
use Env;
use MIME::Base64;
use Fcntl ':flock';
use Scalar::Util qw(looks_like_number);
use POSIX qw(strftime);

# This script is expected to be called once per record (usually via xargs in parallel)
my ($rowNum, $options, $outputDest, $gitalyBareRepoPath, $gitObjectID, $gitFileName, $gitFileSizeBytes) = @ARGV;
$options ||= '';

my $isParallelOp = (index($options, "is-parallel-op") != -1);

my $customDest;
my $outputFH;
if($outputDest && $outputDest ne 'STDOUT') {
    open($outputFH, '>>', $outputDest) || die "Unable to write to $outputDest: $1";
    $customDest = 1; # we need to close and lock custom destinations
} else {
    $outputFH = *STDOUT;
    $customDest = 0; # we don't close or lock STDOUT
}

if($rowNum eq 'csv-header' || $rowNum eq 'create-table-clauses' || $rowNum eq 'markdown') {
    my @header = (
        ['discovered_at', 'timestamptz', 'Timestamp of when the discovery of this row occurred'], 
        ['git_object_id', 'text', 'Git object (e.g. blob) ID acquired from bare Git repo'], 
        ['git_file_name', 'text', 'Git file name acquired from bare Git repo'],
        ['git_file_size_bytes', 'integer', 'Git file size in bytes acquired from bare Git repo'], 
        ['git_file_content_base64', 'text', 'Git file commit content, in Base64 format, from bare Git repo using git show -r {git_object_id}']);
    flock($outputFH, LOCK_EX) or die "Could not lock '$outputDest' for parallel op: $!" if $customDest && $isParallelOp;
    if($rowNum eq 'csv-header') {
        print $outputFH join(',', map { $_->[0] } @header) . "\n";
    } elsif($rowNum eq 'create-table-clauses') {
        print $outputFH join(",\n    ", map { "$_->[0] $_->[1]" } @header) . "\n";
    } elsif($rowNum eq 'markdown') {
        print $outputFH join("\n", map { "| \`$_->[0]\` | $_->[1] | $_->[2] |" } @header) . "\n";
    } else { 
        die "$rowNum must be either a row number or 'csv-header', 'markdown' or 'create-table-clauses'."
    }
    close($outputFH) if $customDest;
    exit 0;
}

if(!looks_like_number($rowNum)) {
    die "$rowNum must be either a row number or 'csv-header', 'markdown' or 'create-table-clauses'."
}

my $content = `sudo git --no-pager --git-dir $gitalyBareRepoPath show -r $gitObjectID`;
my @result = (strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()), $gitObjectID, $gitFileName =~ /,/ ? qq(" $gitFileName") :  $gitFileName, $gitFileSizeBytes, $content ? encode_base64($content, '') : '');
flock($outputFH, LOCK_EX) or die "Could not lock '$outputDest' for parallel op: $!" if $customDest && $isParallelOp;
print $outputFH join(',', @result) . "\n";
close($outputFH) if $customDest;