#!/usr/bin/env perl
use warnings;
use strict;
use Env;
use MIME::Base64;
use Fcntl ':flock';

my ($rowNum, $options, $outputDest, $projectId, $repoId, $gitalyBareRepoPath) = @ARGV;
$options ||= '';

my $includeExtendedAttrs = (index($options, 'extended-attrs') != -1);
my $includeContent = (index($options, "content") != -1);
my $isParallelOp = (index($options, "is-parallel-op") != -1);

my $customDest;
my $outputFH;
if($outputDest && $outputDest ne 'STDOUT') {
    # if a directory is given, we're being asked to create separate files
    $outputDest = "$outputDest/$projectId-$repoId.csv" if -d $outputDest;
    open($outputFH, '>>', $outputDest) || die "Unable to write to $outputDest: $1";
    $customDest = 1; # we need to close and lock custom destinations
} else {
    $outputFH = *STDOUT;
    $customDest = 0; # we don't close or lock STDOUT
}

if($rowNum eq 'csv-header' || $rowNum eq 'create-table-clauses') {
    my @header = (
        ['index', 'integer'], 
        ['gl_project_id', 'integer'], 
        ['gl_project_repo_id', 'integer'], 
        ['git_branch', 'text'], 
        ['git_file_mode', 'text'], 
        ['git_asset_type', 'text'], 
        ['git_object_id', 'text'], 
        ['git_file_size_bytes', 'integer'], 
        ['git_file_name', 'text']);
    if($includeExtendedAttrs) {
        push(@header, 
            ['git_commit_hash', 'text'], 
            ['git_author_date', 'timestamptz'], 
            ['git_commit_date', 'timestamptz'], 
            ['git_author_name', 'text'], 
            ['git_author_email', 'text'], 
            ['git_committer_name', 'text'], 
            ['git_committer_email', 'text'], 
            ['git_commit_subject', 'text']);
    }
    if($includeContent) {
        push(@header, ['git_file_content_base64', 'text']);
    }
    flock($outputFH, LOCK_EX) or die "Could not lock '$outputDest' or parallel op: $!" if $customDest && $isParallelOp;
    if($rowNum eq 'create-table-clauses') {
        print $outputFH join(",\n    ", map { "$_->[0] $_->[1]" } @header) . "\n";
    } else {
        print $outputFH join(',', map { $_->[0] } @header) . "\n";
    }
    close($outputFH) if $customDest;
    exit 0;
} 

# build results first and then emit at once since this script can be run in parallel via xargs
my @results = ();
open(my $branchesCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'for-each-ref', '--format', '%(refname:short)', 'refs/heads/*');
while(<$branchesCmd>) {
    chomp;
    my $branch = $_;
    open(my $traverseCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'ls-tree', '-r', $branch, '--long');
    while(<$traverseCmd>) {
        chomp; 
        my @row = split(/[ \t]+/);
        if($includeExtendedAttrs) {
            open(my $extendedAttrsCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'log', '-1', '--pretty=%H||%aI||%cI||%aN||%ae||%cN||%ce||%s', $branch, '--', $row[-1]);
            chomp(my $extended = <$extendedAttrsCmd>);
            push(@row, split(/\|\|/, $extended));
            close($extendedAttrsCmd);
        }
        # prepare CSV-style output with double-quotes to escape , in any text column
        my @result = ($rowNum, $projectId, $repoId, $branch, map { /,/ ? qq("$_") : $_ } @row);
        if($includeContent) {
            my $content = `sudo git --no-pager --git-dir $gitalyBareRepoPath show -r $row[2]`;
            push(@result, $content ? encode_base64($content, '') : '');
        }
        push(@results, \@result);
    }
    close($traverseCmd);
}
close($branchesCmd);
flock($outputFH, LOCK_EX) or die "Could not lock '$outputDest' or parallel op: $!" if $customDest && $isParallelOp;
print $outputFH join("\n", map { join(',', @$_) } @results) . "\n";
close($outputFH) if $customDest;