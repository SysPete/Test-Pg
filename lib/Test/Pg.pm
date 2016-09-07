package Test::Pg;

use 5.006;
use strict;
use warnings;

use Carp 'croak';
use File::Which;
use MooX::Types::MooseLike::Base qw(:all);
use Path::Tiny;
use POSIX qw(SIGTERM SIGINT SIGQUIT SIGKILL WNOHANG);
use Proc::Fork;
use Moo;
use namespace::clean;

our $errstr;
our $handles;

=head1 NAME

Test::Pg - The great new Test::Pg!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use DBI;
    use Test::Pg;
    use Test::More;

    my $pgsql = Test::Pg->new()
      or plan skip_all => $Test::Pg::errstr;


    ...

=head1 ATTRIBUTES

The following attributes can be passed to the constructor.

=head2 auth

The C<initdb> authentication method.  Defaults to 'trust'.

=cut

has auth => (
    is      => 'ro',
    isa     => Str,
    default => 'trust',
);

=head2 base_dir

The directory where the database cluster will be stored. Defaults to a
temporary directory. See also L</tempdir_options>.

Any directory provided as argument will be coerced into a C<Path::Tiny> object.

=cut

has base_dir => (
    is  => 'ro',
    isa => sub {
        croak "base_dir directory $_[0] does not exist" unless $_[0]->is_dir;
    },
    coerce => sub {
        ref( $_[0] ) eq 'Path::Tiny' ? $_[0] : path( $_[0] );
    },
    lazy    => 1,
    default => sub {
        Path::Tiny->tempdir( %{ $_[0]->tempdir_options } );
    },
);

=head2 base_port

We attempt to use this port first, and will increment from there.
The final port ends up in the L</port> attribute.

=cut

has base_port => (
    is      => 'ro',
    isa     => Int,
    default => 15432,
);

=head2 encoding

Defaults to 'UTF8'.

=cut

has encoding => (
    is      => 'ro',
    isa     => Str,
    default => 'UTF8',
);

=head2 initdb

The path to the C<initdb> executable. If not provided then L<File::Which> is
used to try and find it.

=cut

has initdb => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        which 'initdb';
    },
);

=head2 locale

Defaults to 'C'.

=cut

has locale => (
    is      => 'ro',
    isa     => Str,
    default => 'C',
);

=head2 nosync

By default we pass C<--nosync> option to C<initdb> and C<-F> to
L</postmaster> executable.

If you wish to disable this behaviour set this attribute to 0 (zero).

=cut

has nosync => (
    is      => 'ro',
    isa     => Bool,
    default => 1,
);

=head2 pgdata

The file system location of the database configuration files.

Defaults to subdir C<data> of L</base_dir>.

=cut

has pg_data => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        $_[0]->base_dir->child('data');
    },
);

=head2 postmaster

The path to the C<postmaster> or C<postgres> executable. If not provided
then L<File::Which> is used to try and find one of them.

=cut

has postmaster => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        which 'postmaster' || which 'postgres'
    },
);

=head2 tempdir_options

A hash reference of options to be passed to L<Path::Tiny/tempdir> when the
default value of L</pgdata> is used (a temporary directory).

If no options are provided but C<$ENV{TEST_PG_PRESERVE}> is set then
C<< CLEANUP => 0 >> will be used to prevent the L</pgdata> directory from
being cleaned up on exit.

=cut

has tempdir_options => (
    is      => 'ro',
    isa     => HashRef,
    lazy    => 1,
    default => sub {
        $ENV{TEST_PG_PRESERVE} ? +{ CLEANUP => 0 } : +{};
    },
);

=head2 username

Defaults to 'postgres'.

=cut

has username => (
    is      => 'ro',
    isa     => Str,
    default => 'postgres',
);

=head1 METHODS

=head2 BUILD

Called automatically after object construction ... MORE ...

=cut

sub BUILD {
    my $self = shift;
    $self->initdb;
    $self->create;
    $self->start;
}

=head2 DEMOLISH

Do our best to cleanup running PostgreSQL processes.

=cut

sub DEMOLISH {
    my ( $self, $in_global_destruction ) = @_;
    if ($in_global_destruction) {

        # Objects get garbage collected before unblessed references so we use
        # the database handle data we stashed in $handles since we know that
        # anything still in there didn't get cleaned up during normal object
        # destruction.
        foreach my $pid ( keys %$handles ) {
            remove_connections( $handles->{$pid} );

            # kindest to harshest signal
            foreach my $signal ( SIGTERM, SIGINT, SIGQUIT, SIGKILL ) {
                kill $signal, $pid;
                my $timeout = 5;
                while ( $timeout > 0 and waitpid( $pid, WNOHANG ) <= 0 ) {
                    $timeout -= sleep(1);
                }
                last if $timeout > 0;
            }
        }
    }
    else {
        # object destruction so try a normal stop
        $self->stop;
    }
}

=head2 remove_connections

Try to cleanly remove database connections.

=cut

# cargo-culted from Test::Mojo::Pg
sub remove_connections {
    my $dsn = shift;
    my ( $self, $p ) = @_;
    say 'Removing existing connections' if $self->verbose;
    my $pf = $self->get_version($p) < 90200 ? 'procpid' : 'pid';
    my $q =
        q|SELECT pg_terminate_backend(pg_stat_activity.|
      . $pf . q|) |
      . q|FROM   pg_stat_activity |
      . q|WHERE  pg_stat_activity.datname='|
      . $self->db . q|' |
      . q|AND    |
      . $pf
      . q| <> pg_backend_pid();|;
    $p->db->query($q);
}

=head2 initdb

=cut

sub initdb {
    my $self = shift;

    # initdb not required if we already have pg_data directory
    return if $self->pg_data->is_dir;

    my @options = (
        '-A', $self->auth,
        '-E', $self->encoding,
        '--locale', $self->locale,
        '-U', $self->username,
    );
    push @options, '-N' if $self->nosync;

    if ( $self->pg_ctl ) {
        my @cmd = (
            $self->pg_ctl,
            'initdb',
            '-s',    # silent mode: print only errors
            '-D', $self->pgdata,
            '-o',    # initdb-options
            join( ' ', @options ),
        );
        system(@cmd) == 0 or croak "@cmd failed:$?";
    }
    elsif ( $self->initdb ) {
        my @cmd = (
            $self->initdb,
            '-D', $self->pgdata,
            @options,
        );
        system(@cmd) == 0 or croak "@cmd failed:$?";
    }
    else {
        croak "Cannot find pg_ctl or initdb executables."
    }
}

=head2 start

=cut

sub start {
    my $self = shift;

    if ( $self->pg_ctl ) {
        my @cmd = (
            $self->pgctl,
            'start',
            '-w',   # wait for startup to complete
            '-s',   # silent mode: print only errors
            '-D', $self->pg_data,
            '-l', $self->base_dir->child('postgres.log'),
            '-o',
            join( ' ',
                '-A', $self->auth,
                '-E', $self->encoding,
                '--locale=' . $self->locale,
                '-p', $self->port,
                '-h', '127.0.0.1',
                $self->nosync ? '-F' : '',
            )
        );
    }
    else {
        run_fork {
            child {} parent {
                my $shild_pid = shift;

                # stash db connection info

                waitpid $child_pid, 0;
            }
            retry {
                my $attempts = shift;
            }
            error {}
        };
    }
}

=head2 stop

=cut

sub stop {
    my $self = shift;
    print "Stopping...\n";
}

=head1 AUTHOR

Peter Mottram (SysPete), C<< <peter at sysnix.com> >>

=head1 BUGS

Please report any bugs or feature requests via the GitHub issue tracker
at L<https://github.com/SysPete/Test-Pg/issues>.  I will be notified, and
then you'll automatically be notified of progress on your bug as I make
changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Test::Pg

You can also look for information at:

=over 4

=item * GitHub issue tracker (report bugs here)

L<https://github.com/SysPete/Test-Pg/issues>

=item * meta::cpan

L<https://metacpan.org/pod/Test::Pg>

=back

=head1 SEE ALSO

L<Test::PostgreSQL>, L<Test::Mojo::Pg>

=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2016 Peter Mottram (SysPete).

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;    # End of Test::Pg
