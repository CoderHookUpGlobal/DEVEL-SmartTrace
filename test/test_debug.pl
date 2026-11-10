#!/usr/bin/perl
use strict;
use warnings;

# Test script for Devel::SmartTrace and Devel::CTrace
my $global = 42;
my $message = "Hello";

print "Start: $message\n";

sub process {
    my $count = 10;
    my $total = $count * 2;
    print "In process: count=$count total=$total global=$global\n";
    $global++;
    return $total;
}

my $result = process();
print "Result: $result global now $global\n";

sub another {
    my @arr = (1,2,3);
    my %hash = (a=>1);
    print "In another\n";
}

another();
print "End\n";