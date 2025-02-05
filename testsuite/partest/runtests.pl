#!/usr/bin/perl

# Author: Per Östlund
#
# This script parses the makefiles in the testsuite and extracts (almost) all
# testcases. It then runs each test with the runtest.pl script, which creates a
# new directory for each test and symlinks all needed files into that directory.
# In this way it's possible to run all tests in parallel, which greatly speeds
# up testing when using more than two processor cores.
#
# Usage: Run without any arguments to run the whole testsuite.
#
# NOTE: This is the official OpenModelica way of running the testsuite, so
#       you should run this before committing any changes.
#
# NOTE: This script has been tested on Linux, Windows mingw, and OSX so far,
#       and will probably work on all other platforms except Windows without any
#       modifications.

use strict;
use warnings;

use threads;
use threads::shared;
use Thread::Queue;
use Term::ANSIColor;
use List::Util 'shuffle';
use Cwd;
use File::Path qw(rmtree);
use Time::HiRes qw( usleep ualarm gettimeofday tv_interval clock stat );

use Fcntl;

# Force the children to not use parallel mark
$ENV{GC_MARKERS}="1";

my $use_db = 1;
my $save_db = 1;
my $asan = 0;
my $notlm = 1;
my $nocolour = '';
my $count_tests = 0;
my $run_failing = 0;
my $file;
my $slowest:shared = 0;
my $slowest_name:shared = "";

# Default is two threads.
my $thread_count = 2;
my $check_proc_cpu = 1;
my $with_xml = 0;
my $with_xml_file = 'result.xml';
my $with_xml_cmd = 0;
my $withtxt = 0;
my $have_dwdiff = "";
my $rebase_test = "";
my $platform = "";

{
  eval { require File::Which; 1; };
  if(!$@) {
    if (File::Which->which('dwdiff')) {
      $have_dwdiff = "-have-dwdiff";
    }
  } else {
    if(0==system('which dwdiff > /dev/null 2>&1')) {
      $have_dwdiff = "-have-dwdiff";
    }
  }
}


# Check the flags.
for(@ARGV){
  if(/^-h|--help$/) {
    print("Usage: runtests.pl [OPTION]\n");
    print("\nOptions are:\n");
    print("  -asan         Skip all python tests.\n");
    print("  -b            Rebase tests in parallel. Use in conjuction with -file=/path/to/file.\n");
    print("  -counttests   Don't run the test; only count them.\n");
    print("  -failing      Run failing tests instead of working.\n");
    print("  -file         Reads testcases from the given file instead of from a makefile.\n");
    print("  -jN           Use N threads.\n");
    print("  -nocolour     Don't use colours in output.\n");
    print("  -nodb         Don't store timing data.\n");
    print("  -nosavedb     Don't overwrite stored timing data.\n");
    print("  -notlm        Skip all tlm tests.\n");
    print("  -platform     Force to use a specific platform, e.g. win or linux32.\n");
    print("  -with-txt     Output TXT log.\n");
    print("  -with-xml     Output XML log.\n");
    exit 1;
  }
  if(/^-asan$/) {
    $asan = 1;
  }
  elsif(/^-b$/) {
    $rebase_test = "-b";
  }
  elsif(/^-counttests$/) {
    $count_tests = 1;
  }
  elsif(/^-failing$/) {
    $run_failing = 1;
  }
  elsif(/^-file=(.*)$/) {
    $file = $1;
  }
  elsif(/^-j([0-9]+)$/) {
    $check_proc_cpu = 0;
    $thread_count = $1;
  }
  elsif(/^-nocolour$/) {
    $nocolour = '--no-colour';
  }
  elsif(/^-nodb$/) {
    $use_db = 0;
  }
  elsif(/^-nosavedb$/) {
    $save_db = 0;
  }
  elsif(/^-notlm$/) {
    $notlm = 1;
  }
  elsif(/^-platform(.*)$/) {
    $platform = $_;
  }
  elsif(/^-with-txt$/) {
    $withtxt = 1;
  }
  elsif(/^-with-xml$/) {
    $with_xml = 1;
    $with_xml_file = 'result.xml';
    $with_xml_cmd = '-with-xml';
  }
  elsif(/^-with-xml=(.*)$/) {
    $with_xml = 1;
    $with_xml_file = "$1";
    $with_xml_cmd = '-with-xml';
  }
  else {
    print("Unknown flag " . $_ . "!\n");
    exit 1;
  }
}

if ($use_db) {
  eval { require MLDBM; 1; };

  if(!$@) {
    MLDBM->import();
  } else {
    print "Could not load MLDBM module, falling back to nodb mode.\n";
    $use_db = 0;
  }
}

my @test_list;
my $test_queue = Thread::Queue->new();
my $tests_failed :shared = 0;
my @failed_tests :shared;
my $testscript = cwd() . "/runtest.pl";
my $testsuite_root = cwd() . "/../";
my %test_map :shared;

if($use_db) {
  tie (my %db_map, "MLDBM", "../runtest.db", O_RDWR|O_CREAT, 0664);
  %test_map = %db_map;
}

# Parse a makefile
sub read_makefile {
  my $dir = shift;
  my $header = shift;

  return if($notlm == 1 and $dir =~ m"/tlm"); # Skip tlm if -notlm is given.

  open(my $in, "<", "$dir/Makefile") or die "Couldn't open $dir/Makefile: $!";

  while(<$in>) {
    if(/(\S+) -f Makefile test[^s]/) { # Recursively parse makefiles.
      read_makefile("$dir/$1", $header);
    }
    elsif(/^$header\s*=.*$/) { # Found a list of tests, parse them.
      seek($in, -length($_), 1);
      parse_testfiles($in, $dir);
    }
  }
}

# Trims whitespace from both ends of a string.
sub trim {
  my $s = shift;
  $s =~ s/^\s+|\s+$//g;
  return $s;
}

# Reads test cases from a file.
sub read_file {
  my $file = shift;

  open(my $in, "<", $file) or die "Couldn't open $file: $!";

  while(<$in>) {
    push @test_list, trim($_);
  }
}

# Parse a list of tests given in a makefile by TESTFILES.
sub parse_testfiles {
  my $in = shift;
  my $path = shift;

  while(<$in>) {
    add_tests($_, $path) unless /#.*/; # Skip lines beginning with #
    last unless /\\/; # If the line doesn't end with \, stop.
  }
}

# Extract all files beginning with .lua|.py|.xml from a line.
sub add_tests {
  my @tests = split(/\s|=|\\/, shift);
  my $path = shift;

  if ($asan) {
    @tests = grep(/\.lua|\.xml/, @tests);
  } else {
    @tests = grep(/\.lua|\.py|\.xml/, @tests);
  }
  @tests = map { $_ = ("$path/$_" =~ s/\/\//\//rg) } @tests;

  push @test_list, @tests;
}

# Run the tests by dequeuing them from the list of tests and calling the
# runtest.pl script.
sub run_tests {
  while(defined(my $test_full = $test_queue->dequeue_nb())) {
    (my $test_dir, my $test) = $test_full =~ /(.*)\/([^\/]*)$/;

    my $t0 = [gettimeofday];
    my $cmd = "$testscript $test_full $have_dwdiff $nocolour $with_xml_cmd $rebase_test $platform";
    my $x = system("$cmd") >> 8;
    my $elapsed = tv_interval ( $t0, [gettimeofday]);

    if($use_db) {
      lock(%test_map);
      lock($slowest);
      $test_map{$test_full} = $elapsed;
      if ($slowest < $elapsed) {
        lock($slowest_name);
        $slowest_name = $test_full;
        $slowest = $elapsed;
      }
    }

    if($x == 0) { # Add the test to the list of failed tests if it failed.
      lock($tests_failed);
      $tests_failed++;
      lock(@failed_tests);
      push @failed_tests, $test_full;
    }
  }
}

if (!defined($file)) {
  # Assume that we are in a subdirectory of the testsuite, so go up one level and
  # parse the makefile there.
  chdir("..");

  if($run_failing == 0) {
    read_makefile(".", "TESTFILES");
  } else {
    read_makefile(".", "FAILINGTESTFILES|WRONGRESULTTEST|NOTCOMPILETEST|NOTSIMULATETEST");
  }
} else {
  read_file($file);
  chdir("..");
}

if($use_db) {
  # Sort most expensive operations first
  @test_list = reverse @test_list;
  @test_list = sort {
    my $la = $test_map{$a};
    my $lb = $test_map{$b};
    $la = defined($la) ? $la : 20;
    $lb = defined($lb) ? $lb : 20;
    $lb <=> $la
  } @test_list;
}

# Put all the found tests in the queue.
foreach(@test_list) {
  $test_queue->enqueue($_);
}

# Signal that there is no more work to be sent
$test_queue->end();

# Check if we can open /proc/cpuinfo to see how many cores are available, and
# use that many threads instead.
if ($check_proc_cpu) {
  if (open(my $in, "<", "/proc/cpuinfo")) {
    $thread_count = 0;

    while(<$in>) {
      $thread_count++ if /processor/;
    }
  } else { # On OSX, try syscyl
    my @contents = `sysctl -n hw.ncpu`;
    if (int($contents[0]) > 0) {
      $thread_count = int($contents[0]);
    }
  }
}
# Make sure that omc-diff is generated before trying to run any tests.
system("make --quiet -j$thread_count omc-diff ReferenceFiles > /dev/null 2>&1");

my $test_count = @test_list;

if ($count_tests) {
  print $test_count;
  exit 0;
}

print "$thread_count threads\n";

# Run the tests by calling the run_tests function with multiple threads.
for(my $i = 0; $i < $thread_count; $i++) {
  threads->create(\&run_tests);
}

# Wait for the tests to finish.
foreach my $thr (threads->list()) {
  $thr->join();
  print "{joined thread: " . $thr->tid() . "}"
}

# Print out the list of tests that failed, and a summary of how many failed.
print color 'reset';
print "\n";

chomp(my $ext = `(git symbolic-ref --short HEAD 2>/dev/null) || (echo 'log')`);
if($withtxt) {
  unlink("$testsuite_root/failed.".$ext);
}

if(@failed_tests) {
  print "\nFailed tests:\n";
  my @sorted = sort @failed_tests;
  foreach my $failed_test (@sorted) {
    print "\t" . $failed_test . "\n";
  }

  if($withtxt) {
    open my $TXTOUT, '>', "$testsuite_root/failed.".$ext or die "Couldn't open failed.".$ext.": $!";
    binmode $TXTOUT, ":encoding(UTF-8)";

    print $TXTOUT localtime(time)."\n\n";

    foreach my $failed_test (@sorted) {
      print $TXTOUT $failed_test . "\n";
    }

    print $TXTOUT "\n$tests_failed of $test_count failed\n";
    close $TXTOUT;

    print "\n[Statistics have been stored in failed.".$ext."]\n";
  }
}

if ($slowest) {
  print sprintf("\nSlowest test %.3fs $slowest_name",$slowest);
}

print "\n$tests_failed of $test_count failed\n";

if($use_db && $save_db) {
  tie (my %db_map, "MLDBM", "runtest.db", O_RDWR|O_CREAT, 0664);
  %db_map = %test_map;
}

# Read the files in serial; seems to get issues otherwise
if($with_xml) {
  unlink($with_xml_file);
  unlink("partest/$with_xml_file");
  open my $XMLOUT, '>', "$testsuite_root/partest/$with_xml_file" or die "Couldn't open $with_xml_file: $!";
  binmode $XMLOUT, ":encoding(UTF-8)";
  print $XMLOUT '<?xml version="1.0" encoding="UTF-8"?>';
  print $XMLOUT "<testsuite>\n";

  foreach(@test_list) {
    my $test_full = $_;
    (my $test_dir, my $test) = $test_full =~ /(.*)\/([^\/]*)$/;
    my $filename = "$testsuite_root$test_full.result.xml";

    my $data = "";
    if (open my $fh, '<', $filename) {
      $data = do { local $/; <$fh> };
    }
    if ($data !~ m,^<testcase.*>, || $data !~ m,</testcase>,) {
      my $classname = $test_dir;
      # Replace ./abc/def with abc.def
      $classname =~ s,\./,,g;
      $classname =~ s,/,.,g;
      print "\nERROR: Result xml not found: $filename. Cwd is: ".cwd(). "data is: $data\n";
      $data = "<testcase classname=\"$classname\" name=\"$test\"><failure type=\"Result not found\">Result xml-file not found</failure></testcase>";
    }
    print $XMLOUT "$data";
  }

  print $XMLOUT "</testsuite>\n";
}

# Clean up the temporary rtest directory, so it doesn't get overrun.
my $username = getpwuid($<);
my @dirs = glob "/tmp/omc-rtest-$username*";
if (@dirs) {
  rmtree(@dirs);
}

if(@failed_tests) {
  exit 7;
}
