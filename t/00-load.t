#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Test::Pg' ) || print "Bail out!\n";
}

diag( "Testing Test::Pg $Test::Pg::VERSION, Perl $], $^X" );
