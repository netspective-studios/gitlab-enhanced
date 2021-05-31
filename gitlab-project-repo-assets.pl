#!/usr/bin/env perl
use warnings;
use strict;
use Env;
use MIME::Base64;
use Fcntl ':flock';
use Scalar::Util qw(looks_like_number);
use POSIX qw(strftime);

# This script is expected to be called once per record (usually via xargs)
my ($rowNum, $options, $outputDest, $projectId, $repoId, $gitalyBareRepoHost, $gitalyBareRepoHostIPAddr, $gitalyBareRepoPath) = @ARGV;
$options ||= '';

my $includeLog = (index($options, 'log') != -1);
my $includeContent = (index($options, 'content') != -1);
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

if($rowNum eq 'csv-header' || $rowNum eq 'create-table-clauses' || $rowNum eq 'markdown') {
    my @header = (
        ['discovered_at', 'timestamptz', 'Timestamp of when the discovery of this row occurred'], 
        ['gl_project_id', 'integer', 'GitLab project ID acquired from [GitLab].projects.id table'], 
        ['gl_project_repo_id', 'integer', 'GitLab project repo ID acquired from [GitLab].project_repositories.id table'], 
        ['gl_gitaly_bare_repo_host', 'text', 'GitLab project Gitaly bare repo path host'],
        ['gl_gitaly_bare_repo_host_ip_addr', 'text', 'GitLab project Gitaly bare repo path host'],
        ['gl_gitaly_bare_repo_path', 'text', 'GitLab project Gitaly bare repo path'],
        ['git_branch', 'text', 'Git branch acquired from bare Git repo using git for-each-ref command'], 
        ['git_file_mode', 'text', 'Git file mode acquired from bare Git repo using git ls-tree -r {branch} command'], 
        ['git_asset_type', 'text', 'Git asset type (e.g. blob) acquired from bare Git repo using git ls-tree -r {branch} command'], 
        ['git_object_id', 'text', 'Git object (e.g. blob) ID acquired from bare Git repo using git ls-tree -r {branch} command'], 
        ['git_file_size_bytes', 'integer', 'Git file size in bytes acquired from bare Git repo using git ls-tree -r {branch} command'], 
        ['git_file_name', 'text', 'Git file name acquired from bare Git repo using git ls-tree -r {branch} command']);
    if($includeLog) {
        push(@header, 
            ['git_commit_hash', 'text', 'Git file commit hash acquired from bare Git repo using git log -1 {branch} {git_file_name} command'],
            ['git_author_date', 'timestamptz', 'Git file author date acquired from bare Git repo using git log -1 {branch} {git_file_name} command'], 
            ['git_commit_date', 'timestamptz', 'Git file commit date acquired from bare Git repo using git log -1 {branch} {git_file_name} command (commit date is usually the same as author date unless the repo was manipulated)'], 
            ['git_author_name', 'text', 'Git file author name acquired from bare Git repo using git log -1 {branch} {git_file_name} command'], 
            ['git_author_email', 'text', 'Git file author e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command'], 
            ['git_committer_name', 'text', 'Git file committer name acquired from bare Git repo using git log -1 {branch} {git_file_name} command'], 
            ['git_committer_email', 'text', 'Git file committer e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command'], 
            ['git_commit_subject', 'text', 'Git file commit message subject acquired from bare Git repo using git log -1 {branch} {git_file_name} command']);
    }
    if($includeContent) {
        push(@header, ['git_file_content_base64', 'text', 'Git file commit content, in Base64 format, from bare Git repo using git log -1 {branch} {git_file_name} command']);
    }
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

# build results first and then emit at once since this script can be run in parallel via xargs
my @results = ();
open(my $branchesCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'for-each-ref', '--format', '%(refname:short)', 'refs/heads/*');
while(<$branchesCmd>) {
    chomp;
    my $branch = $_;
    open(my $traverseCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'ls-tree', '-r', $branch, '--long');
    while(<$traverseCmd>) {
        chomp; 
        # git ls-dir returns: <mode> SP <type> SP <object> SP <object size> TAB <file>
        my ($meta, $fileName) = split(/\t/);
        my @row = split(/ +/, $meta);
        push(@row, $fileName); # now row is mode,type,objectId,objectSize,fileName
        if($includeLog) {
            open(my $extendedAttrsCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'log', '-1', '--pretty=%H||%aI||%cI||%aN||%ae||%cN||%ce||%s', $branch, '--', $fileName);
            chomp(my $extended = <$extendedAttrsCmd>);
            push(@row, split(/\|\|/, $extended));
            close($extendedAttrsCmd);
        }
        # prepare CSV-style output with double-quotes to escape , in any text column
        my @result = (strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()), $projectId, $repoId, $gitalyBareRepoHost, $gitalyBareRepoHostIPAddr, $gitalyBareRepoPath, $branch, map { /,/ ? qq("$_") : $_ } @row);
        if($includeContent) {
            my $content = `sudo git --no-pager --git-dir $gitalyBareRepoPath show -r $row[2]`;
            push(@result, $content ? encode_base64($content, '') : '');
        }
        push(@results, \@result);
    }
    close($traverseCmd);
}
close($branchesCmd);
flock($outputFH, LOCK_EX) or die "Could not lock '$outputDest' for parallel op: $!" if $customDest && $isParallelOp;
print $outputFH join("\n", map { join(',', @$_) } @results) . "\n";
close($outputFH) if $customDest;