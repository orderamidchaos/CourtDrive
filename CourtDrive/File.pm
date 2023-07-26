package CourtDrive::File;

=head1 NAME
CourtDrive Files Module

=head2 SYNOPSIS
C<< use CourtDrive::File qw(lock_file unlock_file append_file read_data); >>

=head2 DESCRIPTION
Functions for working with files

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use Fcntl 			qw(:DEFAULT :flock);
use Date::Manip		qw(ParseDate UnixDate ParseRecur);
use JSON::XS		qw(decode_json);
use Data::Dumper;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Debug 	qw(errlog debug check_data);

# export public subroutine symbols
use Exporter 		qw(import);
our @EXPORT_OK = 	qw(lock_file unlock_file append_file read_data);

sub lock_file { my ($data, $handle, $type, $counter, $timeout) = @_;
	unless ($handle) { debug($data, "Must specify filehandle for locking.", 2); return 0; }
	$counter = 0 unless $counter; $counter++;		# counter to ensure no runaway recursion
	$timeout = 3 unless $timeout;				# length of time between tries, in seconds
	$type = LOCK_EX unless $type;				# exclusive lock unless defined

	if (my $retval = flock ($handle, $type)) { return $retval; }
	else { 	debug($data, "Contention: cannot get a lock on $handle yet: $!",2);
		if ($counter > 5) {
			debug($data, "Timeout reached.  There seems to have been an error locking $handle: $!",2);
			return 0; }
		else {
			sleep $timeout;
			return lock_file($data, $handle, $type, $counter, $timeout); }}}

sub unlock_file { my ($data, $handle) = @_;
	unless (flock($handle, LOCK_UN)) { error($data, "die","File unlock error: $!"); }}

sub append_file {
	my ($data, $file, $text) = @_; #$data = check_data($data);
	unless (-e $file) { system $data->{TOUCH}, $file; }
	chmod (0774, $file) or die "Could not CHMOD file '$file': $!";
	open(my $fh, '>>', $file) or die "Could not open file '$file': $!";
	if (lock_file($data, $fh, LOCK_EX)) {
		say $fh $text;
		close $fh; }}

sub read_data {
	my ($data_file) = @_;														# pass in data file name
	my $data_text = "";

	if (-e $data_file) {
		if (open(my $fh, "<:encoding(UTF-8)", $data_file)) {					# open data file
			if (lock_file({}, $fh, LOCK_SH)) {
				local $/;														# locally undefine the input record seperator
				$data_text = <$fh>;												# read in the entire file and return it
				close $fh; }
			else { die("failed to lock $data_file: $!"); }}
		else { die("cannot open data file: $!"); }}
	else { die("data file does not exist."); }

	my $data_json = decode_json $data_text;										# deserialize the data object from the JSON source
	return $data_json; }

1;