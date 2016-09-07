use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME               => 'Test::Pg',
    AUTHOR             => q{Peter Mottram (SysPete) <peter@sysnix.com>},
    VERSION_FROM       => 'lib/Test/Pg.pm',
    ABSTRACT_FROM      => 'lib/Test/Pg.pm',
    LICENSE            => 'artistic_2',
    PL_FILES           => {},
    MIN_PERL_VERSION   => 5.006,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'Carp'                   => 0,
        'DBD::Pg'                => 0,
        'DBI'                    => 0.
        'File::Which'            => 0,
        'Moo'                    => 0,
        'MooX::Types::MooseLike' => 0,
        'namespace::clean'       => 0,
        'Path::Tiny'             => 0,
        'POSIX'                  => 0,
        'Proc:Fork'              => 0,
        'strict'                 => 0,
        'warnings'               => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'Test-Pg-*' },
);
