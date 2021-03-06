#!/bin/sh
exec ${PERL-perl} -Swx $0 ${1+"$@"}
#!perl		  [perl will skip all lines in this file before this line]

# with --- run program with special properties

# Copyright (C) 1995, 2000, 2002 Noah S. Friedman

# Author: Noah Friedman <friedman@splode.com>
# Created: 1995-08-14

# $Id: with,v 1.12 2004/02/16 22:51:49 friedman Exp $

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, you can either send email to this
# program's maintainer or write to: The Free Software Foundation,
# Inc.; 59 Temple Place, Suite 330; Boston, MA 02111-1307, USA.

# Commentary:

# TODO: create optional socket streams for stdin or stdout before invoking
# subprocess.

# Code:

use Getopt::Long;
use POSIX qw(setsid);
use Symbol;
use strict;

(my $progname = $0) =~ s|.*/||;
my $bgfn;
my $bgopt = 0;

my $opt_cwd;
my $opt_egid;
my $opt_euid;
my $opt_gid;
my $opt_groups;
my @opt_include;
my $opt_name;
my $opt_pgrp;
my $opt_priority;
my $opt_root;
my $opt_uid;
my $opt_umask;
my $opt_foreground = 0;

sub err
{
  my $fh = (ref ($_[0]) ? shift : *STDERR{IO});
  print $fh join (": ", $progname, @_), "\n";
  exit (1);
}

sub get_includes
{
  unshift @INC, @_;
  push (@INC,
        "$ENV{HOME}/lib/perl",
        "$ENV{HOME}/lib/perl/include");

  eval { require "syscall.ph" } if defined $opt_groups;
}

sub numberp
{
  defined $_[0] && $_[0] =~ m/^-?\d+$/o;
}

sub group2gid
{
  my $g = shift;
  return $g if numberp ($g);
  my $gid = getgrnam ($g);
  return $gid if defined $gid && numberp ($gid);
  err ($g, "no such group");
}

sub user2uid
{
  my $u = shift;
  return $u if numberp ($u);
  my $uid = getpwnam ($u);
  return $uid if defined $uid && numberp ($uid);
  err ($u, "no such user");
}

sub set_cwd
{
  my $d = shift;
  chdir ($d) || err ("chdir", $d, $!);
}

sub set_egid
{
  my $sgid = group2gid (shift);
  my $egid = $) + 0;

  $) = $sgid;
  err ($sgid, "cannot set egid", $!) if ($) == $egid && $egid != $sgid);
}

sub set_gid
{
  my $sgid = group2gid (shift);
  my $rgid = $( + 0;
  my $egid = $) + 0;

  $( = $sgid;
  $) = $sgid;
  err ($sgid, "cannot set rgid", $!) if ($( == $rgid && $rgid != $sgid);
  err ($sgid, "cannot set egid", $!) if ($) == $egid && $egid != $sgid);
}

sub big_endian_p
{
  my $x = 1;
  my @y = unpack ("c2", pack ("i", $x));
  return ($y[0] == 1) ? 0 : 1;
}

# This function is more complex than it ought to be because perl does not
# export the setgroups function.  It exports the getgroups function by
# making $( and $) return multiple values in the form of a space-separated
# string, but you cannot *set* the group list by assigning those variables.
# There is no portable way to determine what size gid_t is, so we must guess.
sub set_groups
{
  my @glist = sort { $a <=> $b } map { group2gid ($_) } split (/[ ,]/, shift);

  my $expected = join (" ", $(+0, reverse @glist);
  my @p = (big_endian_p() ? ("n", "N", "i") : ("v", "V", "i"));

  for my $c (@p)
    {
      err ("setgroups", $!)
        if (syscall (&SYS_setgroups, @glist+0, pack ("$c*", @glist)) == -1);
      return if ("$(" eq $expected);
    }
  err ("setgroups", "Could not determine gid_t");
}

sub set_pgrp
{
  setpgrp ($$, shift) || err ("setpgrp", $!);
}

sub set_priority
{
  my $prio = shift () + 0;
  setpriority (0, 0, $prio) || err ("setpriority", $prio, $!);
}

sub set_root
{
  my $d = shift;
  chroot ($d) || err ("chroot", $d, $!);
  chdir ("/");
}

sub set_euid
{
  my $suid = user2uid (shift);
  my $euid = $>;

  $> = $suid;
  err ($suid, "cannot set euid", $!) if ($> == $euid && $euid != $suid);
}

sub set_uid
{
  my $suid = user2uid (shift);
  my $ruid = $<;
  my $euid = $>;

  $< = $suid;
  $> = $suid;
  err ($suid, "cannot set ruid", $!) if ($< == $ruid && $ruid != $suid);
  err ($suid, "cannot set euid", $!) if ($> == $euid && $euid != $suid);
}


sub background
{
  my $pid = fork;
  die "$@" if $pid < 0;
  if ($pid == 0)
    {
      # Backgrounded programs may expect to be able to read input from the
      # user if stdin is a tty, but we will no longer have any job control
      # management because of the double fork and exit.  This can result in
      # a program either blocking on input (if still associated with a
      # controlling terminal) and stopping, or stealing input from a
      # foreground process (e.g. a shell).  So redirect stdin to /dev/null.
      open (STDIN, "< /dev/null") if (-t STDIN);
      return *STDERR{IO};
    }

  exit (0) unless $opt_foreground;
  wait;
  exit ($?);
}

sub dosetsid
{
  background ();
  setsid (); # dissociate from controlling terminal
  return *STDERR{IO};
}

sub daemon
{
  # Don't allow any file descriptors, including stdin, stdout, or
  # stderr to be propagated to children.
  $^F = -1;
  dosetsid ();
  # Duped in case we've closed stderr but can't exec anything.
  my $saved_stderr = gensym;
  open ($saved_stderr, ">&STDERR");
  close (STDERR);
  close (STDOUT);
  close (STDIN);
  return $saved_stderr;
}

sub notty
{
  # Don't allow any file descriptors other than stdin, stdout, or stderr to
  # be propagated to children.
  $^F = 2;
  dosetsid ();
  # Duped in case we've closed stderr but can't exec anything.
  my $saved_stderr = gensym;
  open ($saved_stderr, ">&STDERR");
  open (STDIN,  "+</dev/null");
  open (STDERR, "+<&STDIN");
  open (STDOUT, "+<&STDIN");
  return $saved_stderr;
}


sub set_bg_option
{
  my %bgfntbl =
    ( 1 => \&background,
      2 => \&daemon,
      4 => \&notty,
      8 => \&dosetsid,
    );

  $bgopt = $_[0];
  $bgfn  = $bgfntbl{$bgopt};
}

sub parse_options
{
  Getopt::Long::config (qw(bundling autoabbrev require_order));
  my $succ = GetOptions
    ("h|help",          sub { usage () },
     "c|cwd=s",         \$opt_cwd,
     "d|display=s",     \$ENV{DISPLAY},
     "H|home=s",        \$ENV{HOME},
     "G|egid=s",        \$opt_egid,
     "g|gid=s",         \$opt_gid,
     "I|include=s@",    \@opt_include,
     "l|groups=s",      \$opt_groups,
     "m|umask=s",       \$opt_umask,
     "n|name=s",        \$opt_name,
     "P|priority=i",    \$opt_priority,
     "p|pgrp=i",        \$opt_pgrp,
     "r|root=s",        \$opt_root,
     "U|euid=s",        \$opt_euid,
     "u|uid=s",         \$opt_uid,

     "f|fg|foreground", \$opt_foreground,

     "b|bg|background", sub { set_bg_option (1); $opt_foreground = 0 },
     "a|daemon|demon",  sub { set_bg_option (2) },
     "N|no-tty|notty",  sub { set_bg_option (4) },
     "s|setsid",        sub { set_bg_option (8) },
    );
  usage () unless $succ;

  my $n = 0;
  do { $n++ if $bgopt & 1 } while ($bgopt >>= 1);
  err ("Can only specify one of --background, --daemon, --notty, or --setsid")
    if ($n > 1);
}

sub usage
{
  print STDERR "$progname: @_\n\n" if @_;
  print STDERR "Usage: $progname {options} [command {args...}]\n
Options are:
-h, --help            You're looking at it.
-D, --debug           Turn on interactive debugging in perl.
-I, --include   DIR   Include DIR in \@INC path for perl.
                      This option may be specified multiple times to append
                      search paths to perl.

-d, --display   DISP  Run with DISP as the X server display.
-H, --home      HOME  Set \$HOME.
-n, --name      ARGV0 Set name of running program (argv[0]).

-c, --cwd       DIR   Run with DIR as the current working directory.
                      This directory is relative to the root directory as
                      specified by \`--root', or \`/'.
-r, --root      ROOT  Set root directory (via \`chroot' syscall) to ROOT.

-G, --egid      EGID  Set \`effective' group ID.
-g, --gid       GID   Set both \`real' and \`effective' group ID.
-l, --groups    GLIST Set group list to comma-separated GLIST.
-U, --euid      EUID  Set \`effective' user ID.
-u, --uid       UID   Set both \`real' and \`effective' user ID.

-m, --umask     UMASK Set umask.
-P, --priority  NICE  Set scheduling priority to NICE (-20 to 20).
-p, --pgrp      PGRP  Set process group.

The following options cause the resulting process to be backgrounded
automatically but differ in various ways:

-b, --background      Run process in background.  This is the default with
                      the --daemon, --no-tty, and --setsid options.

-f, --foreground      Do not put process into the background when using
                      the --daemon, --no-tty, and --setsid options.
                      In all other cases the default is to remain in the
                      foreground.

-a, --daemon          Run process in \"daemon\" mode.
                      This closes stdin, stdout, and stderr, dissociates
                      the process from any controlling terminal, and
                      backgrounds the process.

-N, --no-tty          Run process in background with no controlling
                      terminal and with stdin, stdout, and stderr
                      redirected to /dev/null.

-s, --setsid          Dissociate from controlling terminal.
                      This automatically backgrounds the process but
                      does not redirect any file descriptors.\n";
  exit (1);
}

sub main
{
  parse_options ();
  usage () unless @ARGV;

  get_includes (@opt_include);

  umask        (oct ($opt_umask)) if defined $opt_umask;
  set_gid      ($opt_gid)         if defined $opt_gid;
  set_egid     ($opt_egid)        if defined $opt_egid;
  set_groups   ($opt_groups)      if defined $opt_groups;
  set_root     ($opt_root)        if defined $opt_root;
  set_cwd      ($opt_cwd)         if defined $opt_cwd;
  set_priority ($opt_priority)    if defined $opt_priority;
  set_uid      ($opt_uid)         if defined $opt_uid;
  set_euid     ($opt_euid)        if defined $opt_euid;

  my $stderr = $bgfn ? &$bgfn () : *STDERR{IO};

  my $runprog = $ARGV[0];
  if ($opt_name)
    {
      shift   @ARGV;
      unshift @ARGV, $opt_name;
    }
  local $^W = 0; # avoid implicit warnings from exec
  exec ($runprog @ARGV) || err ($stderr, "exec", $runprog, $!);
}

main ();

# local variables:
# mode: perl
# eval: (auto-fill-mode 1)
# end:

# with ends here
