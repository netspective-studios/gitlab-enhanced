#!/usr/bin/env perl
use warnings;
use strict;
use Env;
use File::Path qw(make_path remove_tree);

# This script is expected to be called once per record (usually via xargs in parallel)
my ($projectID, $projectRepoID, $gitalyBareRepoPath, $cloneURL, $qualifiedProjectPath, $canonicalDestPath, $projectIdDestSymlinkPath) = @ARGV;

open(my $branchesCmd, '-|', 'sudo', 'git', '--no-pager', '--git-dir', $gitalyBareRepoPath, 'for-each-ref', '--format', '%(refname:short)', 'refs/heads/*');
while(<$branchesCmd>) {
    chomp;
    my $branch = $_;
    my $canonicalRepoDestPath = $canonicalDestPath =~ s!/BRANCH/!/$branch/!gr;
    if(-d $canonicalRepoDestPath) {
        system("sudo git -C $canonicalRepoDestPath pull --quiet --depth 1\n");
    } else {
        system("sudo git clone --quiet --depth 1 -b $branch $cloneURL $canonicalRepoDestPath\n");
    }

    # my $projectIdRepoDestSymlinkPath = $projectIdDestSymlinkPath =~ s!/BRANCH/!/$branch/!gr;
    # TODO: create symlink using $projectIdRepoDestSymlinkPath
}
close($branchesCmd);
