package Devel::SmartTrace;

use strict;
use warnings;

our $VERSION = '1.00';

use File::Basename qw(fileparse);
use Data::Dumper;

# PadWalker required for lexical variable inspection via peek_my()
our $HAVE_PADWALKER = eval {
    require PadWalker;
    PadWalker->import('peek_my');
    1;
} || 0;

our $TRACE = 1;          # Master switch (like Devel::Trace)
our $config_file;        # User-specified or auto-detected
our %inspect_points;     # loc_key => [var1, var2, ...]
our $do_trace  = 1;      # Enable deduplicated line tracing
our $do_vars   = 0;      # Enable variable inspection at points
our %seen;               # For deduplication: file:line => 1

my ($name) = fileparse($0);
my $ts = time();
our $log_file = "$name.$ts.tracefile";
our $log_fh;

if (open my $fh, '>', $log_file) {
            $fh->autoflush(1);
            $log_fh = $fh;
            print $log_fh "=== SmartTrace log for $0 started ", scalar(localtime), " ===\n";
} 
else {
            warn "Devel::SmartTrace: Cannot create log '$log_file': $!  Using STDERR"; 
            $log_fh = *STDERR;
            print 
}

sub import {
    my $class = shift; 
    my @args  = @_;

    # Parse -d:Devel::SmartTrace=config=foo.conf,trace=1,vars=0 etc.
    foreach my $arg (@args) {
        if ($arg =~ /^config=(.+)$/i) {
            $config_file = $1;
        } elsif ($arg =~ /^trace=(0|1)$/i) {
            $do_trace = $1;
        } elsif ($arg =~ /^vars=(0|1)$/i) {
            $do_vars = $1;
        } elsif ($arg eq 'trace') {
            # Export trace() function to caller like original Devel::Trace
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::trace"} = \&trace;
        }
    }

    # Auto-detect config: scriptname.trace or scriptname.conf next to $0
    if (!defined $config_file) {
        my $script = $0;
        if ($script ne '-e' && $script ne '-') {
            my ($name, $dir) = fileparse($script);
            $dir ||= './';
            my $c1 = "$dir$name.trace";
            my $c2 = "$dir$name.conf";
            $config_file = -e $c1 ? $c1 : (-e $c2 ? $c2 : undef);
        }
    }

    _load_config() if defined $config_file && -e $config_file;

    # Default behavior if nothing configured: trace only (dedup)
    if (!%inspect_points) {
        $do_vars = 0;
        $do_trace = 1 unless defined $do_trace;
    }

    if ($do_vars && !$HAVE_PADWALKER) {
        warn "Devel::SmartTrace: vars mode requires PadWalker (cpanm PadWalker). Disabling variable inspection.\n";
        $do_vars = 0;
    }
}

sub _load_config {
    my $file = $config_file;
    open my $fh, '<', $file or do {
        warn "Devel::SmartTrace: Cannot read config '$file': $!\n";
        return;
    };
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*//;           # strip comments
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;

        if ($line =~ /^MODE\s*=\s*(trace|vars|both)$/i) {
            my $m = lc $1;
            if    ($m eq 'trace') { $do_trace = 1; $do_vars = 0; }
            elsif ($m eq 'vars')  { $do_trace = 0; $do_vars = 1; }
            elsif ($m eq 'both')  { $do_trace = 1; $do_vars = 1; }
        }
        elsif ($line =~ /^(.+):(.+):(\d+):(.+)$/ && $do_vars) {
            # Format: Package::Subroutine:line:var1,var2,var3
            my ($package, $file, $ln, $vars_str) = ($1, $2, $3, $4);
            my @vars = grep { length($_) } split /\s*,\s*/, $vars_str;
            
            $inspect_points{"$package:$file:$ln"} = \@vars;
            
            
        }
    }
    close $fh;
}

# Toggle tracing at runtime (exportable)
sub trace {
    my $arg = shift;
    if (defined $arg) {
        my %map = (on => 1, off => 0);
        $arg = $map{lc $arg} if exists $map{lc $arg};
        $TRACE = $arg ? 1 : 0;
    }
    return $TRACE;
}

# Core debugger hook - called by Perl before every statement
sub DB::DB {
    return unless $TRACE;

    my ($pkg, $file, $line) = caller();
    # Avoid recursing into our own module
    return if $file =~ /SmartTrace\.pm$/;

    # --- Line tracing mode: print each unique source line only once ---
    if ($do_trace) {
        my $key = "$file:$line";
        if (! exists $seen{$key}) {
            $seen{$key} = 1;
            my $code_ref;
            {
                no strict 'refs';
                $code_ref = \@{"::_<$file"};
            }
            my $src = defined $code_ref->[$line] ? $code_ref->[$line] : '';
            $src =~ s/[\r\n]+$//;
            print $log_fh "[TRACE] $file:$line: $src\n";
        }
    }

    # --- Variable inspection mode at configured points ---
    if ($do_vars && %inspect_points && $HAVE_PADWALKER) {
        my $loc_key = "$pkg:$file:$line";
        if (exists $inspect_points{$loc_key}) {
            
            my $var_list = $inspect_points{$loc_key};
            print $log_fh "[VARS] $pkg:$file:$line\n";

            my $lex = peek_my(1);  # Level 1 = caller's lexical scope
            
            if ($@) {
                print $log_fh "  (peek_my failed: $@)\n";
            }
            
            foreach my $v (@$var_list) {
                
                my $val;
                my $is_lexical = 0;

                if ($lex && exists $lex->{$v}) {
                    $val = $lex->{$v};
                    $is_lexical = 1;
                } else {
                    # Fallback to package variable in current package
                    no strict 'refs';
                     $val = eval "\$$pkg\::$v";
                    if (!defined $val && $@) {
                        $val = undef;
                    }
                }

                local $Data::Dumper::Terse     = 1;
                local $Data::Dumper::Indent    = 0;
                local $Data::Dumper::Sortkeys  = 1;

                my $dval = defined $val ? Data::Dumper->Dump([$val], [$v]) : '(undef)';
                my $prefix = $is_lexical ? 'my ' : '';
                print $log_fh "  $prefix$dval\n";
            }
        }
    }
}

1;

__END__

=head1 NAME

Devel::SmartTrace - Configurable drop-in replacement for Devel::Trace with deduplicated tracing and targeted variable inspection

=head1 SYNOPSIS

    perl -d:Devel::SmartTrace script.pl
    perl -d:Devel::SmartTrace=config=myscript.conf script.pl
    perl -d:Devel::SmartTrace=trace=1,vars=0 script.pl

Config file (myscript.pl.trace or .conf):

    MODE=both
    main::foo:42:x,y,z
    My::Package::bar:17:request,response

=head1 DESCRIPTION

Professional, production-quality custom Perl debugger overriding DB::DB.

Features:
- Deduplicated line tracing (each source line printed at most once)
- Targeted variable inspection at exact package::sub:line points using PadWalker for lexicals + package vars
- Auto-loads config named after script (.trace or .conf)
- Command-line override via -d:Devel::SmartTrace=...
- Three modes: trace / vars / both
- Compatible with Devel::Trace usage patterns ($TRACE, trace('on'))

Requires PadWalker for variable mode: cpanm PadWalker

=head1 AUTHOR

Custom implementation for advanced debugging needs.

=cut