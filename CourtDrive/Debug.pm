package CourtDrive::Debug;

=head1 NAME
CourtDrive Debugging Module

=head2 SYNOPSIS
C<< use CourtDrive::Debug qw(debug_type end_debug_type debug errlog is_array is_hash is_scalar is_null is_empty check_data check_conf get_sub_name get_sub_chain); >>

=head2 DESCRIPTION
Functions for sanity checking and debug output

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use JSON::XS;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Config		qw(read_config);
use CourtDrive::File		qw(append_file);

# export public subroutine symbols
use Exporter				qw(import);
our @EXPORT_OK =			qw(debug_type end_debug_type debug errlog is_array is_hash is_scalar is_null is_empty check_conf check_data get_sub_name get_sub_chain strip_junk);

sub debug_type { my ($data, $type) = @_;	 # don't log anything if the types don't match
	my ($transaction, $line) = get_sub_name(2);
	if ($data->{debug_level} > 0 and (!$data->{debug_type} or ($type and $data->{debug_type} and $data->{debug_type} !~ /$type/))) {
		debug($data, "debug_level=$data->{debug_level} disabled for $transaction; to debug, pass in debug_type=$type", $data->{debug_level});
		$data->{paused_debug_level} = int($data->{debug_level});
		$data->{paused_debug_type} = $type;
		$data->{debug_level} = 0; }
	elsif ($data->{debug_level} > 0 and $data->{debug_type}) {
		debug($data, "debugging enabled for $transaction because [$data->{debug_type}] =~ '$type'", $data->{debug_level}); }}

sub end_debug_type { my ($data, $type) = @_;	# restore general debugging regardless of type specified
	if ($data->{paused_debug_type} and $data->{paused_debug_type} eq $type) {
		my ($transaction, $line) = get_sub_name(2);
		$data->{debug_level} = $data->{paused_debug_level} if $data->{paused_debug_level};
		$data->{paused_debug_level} = 0;
		$data->{paused_debug_type} = '';
		debug($data, "debugging restored to level $data->{debug_level} for $transaction at line $line", $data->{debug_level}); }}

sub debug {	# debug levels:
			# 0 => normal operation, no extra info or warnings provided
			# 1 => extra output on client-side console only, server warnings suppressed
			# 2 => first level of server warnings, basic debugging info
			# 3 => SQL statements
			# 4 => DBI benchmarking info
			# 5 => extra detail
	#warn "debug: not debugging" unless $data->{debug_level};

	my ($data, $message, $level, $details, $limit) = @_;
	return "" unless $data->{debug_level}; # don't log anything if not at least level 1
	$level = 1 unless $level;
	return "" unless $message or $details;

	$limit = 1000 * $data->{debug_level} unless $limit;
	$message =~ s/^(.{$limit}).*$/$1(TRUNCATED AT $limit CHARS)/gis if $message;
	$details =~ s/^(.{$limit}).*$/$1(TRUNCATED AT $limit CHARS)/gis if $details;

	print $message."\n" if $data->{debug_level} >= $level and $data->{print_debugging}; # output to the console

	$message = strip_junk($message);
	$details = strip_junk($details);

	#warn "debug: level = $level, message = $message";
	return "" unless $message or $details;
	return $message if $level == 1 and !$data->{print_debugging}; # only log to client-side at level 1

	my $caller = get_sub_chain();
	my $output = "[".localtime(time)."] ($$) ";
	$output .= " $data->{username}@" if $data->{username};
	$output .= "$data->{site_name}:".$data->{program_name}."$data->{forked}=>$caller" if $data->{site_name} and $data->{program_name} and $caller;
	$output .= ": $message" if $message;
	warn $output if $data->{debug_level} >= $level and !$data->{print_debugging}; # output to server according to debug level

	$data->{debug} .= $message if $data->{debug_level} >= $level and $data->{is_staff}; # so you can add the message also to $data->{debug} for instance
	# don't return to client anything if the debug level isn't reached

	return $message if $data->{debug_level} >= $level and $data->{is_staff}; # so you can add the message also to $data->{error} for instance
	return ""; } # don't return to client anything if the debug level isn't reached

sub errlog {
	# output to the error log regardless of debug status

	my ($data, $message, $details, $depth) = @_;
	$message = strip_junk($message);
	$details = strip_junk($details);
	$depth = 1 unless $depth;	# this is how far back in the call stack to look for the source of the error
					# this function is 0, it's immediate caller is 1
	my $caller = get_sub_chain();
	my $context = "";
	my $output = "";

	$data->{debug_level} = 3 unless defined $data->{debug_level} and $data->{debug_level} > 3; # elevate the debug level once an error is reported

	if ($message or $details) {
		$context = "[".localtime(time)."] ($$) ";
		$context .= " $data->{username}@" if $data->{username};
		$context .= "$data->{site_name}:".$data->{program_name}."$data->{forked}=>$caller" if $data->{site_name} and $data->{program_name} and $caller;
		$output = $context.($message? ": <<<$message>>>":"").($details? ": $details":"");
		warn $output; # output to error log with context first, then message, then details

		$output = "<<<".($message? $message:"").">>> ".($details? $details:"")." from $context"; # output with message first, then details, then context so you can add the message also to $data->{debug} for instance
		if (defined $data->{debug}) { $data->{debug} .= $output; }}

	return $output; } # generally this is appeneded to $data->{error} in the calling subroutine, but doesn't have to be if you just want to write the log without passing the error to the front end

sub is_array {	# determine whether a scalar reference refers to an array
	my $ref = $_[0];					# debug($data, "is_array: ref $ref = ".(ref $ref), 4) if defined $ref;
	unless (defined $ref and ref $ref)			{ return 0; }
	else { 	use warnings; use strict;
		eval { my $a = @$ref; };
		if ($@=~/^Not an ARRAY ref/)			{ return 0; }	# debug($data, "is_array: false, eval %\$ref = ".$@, 4);
		elsif ($@)					{ return 0; }	# error({is_logged_in => 1},"die","Unexpected error in eval",$@); }
		else						{ return 1; }}}	# debug($data, "is_array: true");

sub is_hash {	# determine whether a scalar reference refers to a hash
	my $ref = $_[0];					# debug({}, "is_hash: ".(defined $ref? "ref $ref = ".(ref $ref) : "reference is undefined"), 3);
	unless (defined $ref and ref $ref)			{ return 0; }
	else { 	use warnings; use strict;
		eval { my $h = %$ref; };
		if ($@=~/^Not a HASH ref|Can\'t use string/)	{ return 0; }	# debug({}, "is_hash: false, eval %\$ref = ".$@, 3);
		elsif ($@)					{ return 0; }	# error({is_logged_in => 1},"die","Unexpected error in eval",$@); }
		else						{ return 1; }}}	# debug({}, "is_hash: true", 3);

sub is_scalar {	# determine whether a scalar is indeed a scalar and not a reference to a hash or array
	my $ref = $_[0];
	return ((ref($ref) and ref($ref) eq "SCALAR") or
		(!is_array($ref) and !is_hash($ref)))? 1:0; }

sub is_null {	# determine whether a scalar reference is null
	my $ref = $_[0];
	if (!defined $ref)					{ return 1; }		#debug({debug_level=>3}, "is_null: true, not defined", 3);
	elsif ($ref =~ /^[\x00]/)				{ return 1; }		#debug({debug_level=>3}, "is_null: true, starts with a null character", 3);
	elsif (length($ref)>0 and $ref !~ /[[:print:]]/)	{ return 1; }		#debug({debug_level=>3}, "is_null: true, nonzero length string with nothing printable", 3);
	else {	use warnings; use strict;
		eval { my $r = $ref . ""; };			# try to generate an "uninitialized value" warning
		if ($@)						{ return 1; }		#debug({debug_level=>3}, "is_null: true, eval ref = ".$@, 3);
		else						{ return 0; }}}		#my $output = ($ref =~ /([[:print:]]{1,100})/)? $1 : "[NULL]";	#debug({debug_level=>3}, "is_null: false, ref contains $output", 3);

sub is_empty {	my $ref = $_[0];	# determine whether a scalar reference is either undefined, null, or refers a structure without defined values
	if (!defined $ref or is_null($ref))	{ return 1; }					# empty true if ref is undefined or null
	if (is_array($ref))			{ return scalar @$ref?		0:1; }		# empty true if array with no values
	if (is_hash($ref))			{ return scalar keys %$ref?	0:1; }		# empty true if hash with no values
	if ($ref eq "")				{ return 1; }					# empty true if empty string
	return 0; }										# otherwise false (e.g. defined scalar, function, or reference)

sub check_conf {	# make sure we're dealing with a valid conf hashref
	my $conf = $_[0];

	unless (is_hash($conf) and $conf->{VERSION} and $conf->{system} and $conf->{timeouts}) {
		# this is a non-blocking error (debug info only) because we can load the configuration if not provided
		my $json = new JSON::XS; $json->utf8(1)->allow_tags(1)->convert_blessed(1)->allow_blessed(1)->allow_nonref(1);
		my ($transaction, $line) = get_sub_name(2); my ($transaction3, $line3) = get_sub_name(3);
		debug({debug_level=>2}, "An incomplete 'conf' object was passed into $transaction ($line) from $transaction3 ($line3)", 2); #."; received: ".p($conf)

		$conf = { error=>"" };
		$conf->{error} .= errlog({}, "Configuration invalid. Cannot find configuration path.") unless $ENV{CONF_ROOT}; return $conf if $conf->{error};
		$conf->{error} .= errlog({}, "Configuration invalid. Cannot find configuration filename.") unless $ENV{CONF_FILE}; return $conf if $conf->{error};
		$conf->{error} .= errlog({}, "Configuration invalid. Configuration file ".$ENV{CONF_ROOT}."/".$ENV{CONF_FILE}." doesn't exist.") unless (-e ($ENV{CONF_ROOT}."/".$ENV{CONF_FILE})); return $conf if $conf->{error};
		$conf = read_config($ENV{CONF_ROOT}."/".$ENV{CONF_FILE});}
	return $conf; }

sub check_data { 	# make sure imported data object is reasonably complete for basic operations (contains the top-level initialization values)
	my $data = $_[0]; my $conf = $_[1];
	my ($transaction, $line) = get_sub_name(2); my ($transaction3, $line3) = get_sub_name(3);

	unless (is_hash($data) and $data->{program_name} and $data->{schema} and $data->{query_timeout}) {
		# this is a non-blocking error (debug info only) because the output of check_data may result in
		# a different but non-erroneous path of execution... if non-existence of data object is an error,
		# the error needs to be reported in the calling function; e.g. return error() if $data->{no_data};
		my $json = new JSON::XS; $json->utf8(1)->allow_tags(1)->convert_blessed(1)->allow_blessed(1)->allow_nonref(1);
		my $msg = "An incomplete 'data' object was passed into $transaction ($line) from $transaction3 ($line3)"."; received: ".((is_hash($data) && $data->{debug_level} >= 2)? p($data):"");

		unless ($data and is_hash($data)) { $data = { debug=>"", error=>"", debug_level=>2 }; }	# create the $data object if it doesn't exist at all or isn't a hashref
		$data->{no_data} = 1;									# record that this $data object is incomplete
		$data->{debug} .= debug($data, $msg, 2); }						# add the debug message to $data
	else { delete $data->{no_data} if $data->{no_data}; }

	$data->{debug} = "" unless $data->{debug}; # initialize with blank string so we can append if it doesn't exist
	$data->{error} = "" unless $data->{error}; # initialize with blank string so we can append if it doesn't exist

	# pass certain conf variables to $data so we don't have to pass $conf everywhere to get them
	unless ($data->{ISAAC_NAME})	{ $data->{ISAAC_NAME}	= (is_hash($conf) and $conf->{files}->{ISAAC_NAME})?		$conf->{files}->{ISAAC_NAME} 		: $0; }
	unless ($data->{ERROR_LOG})	{ $data->{ERROR_LOG}	= (is_hash($conf) and $conf->{files}->{ERROR_LOG})? 		$conf->{files}->{ERROR_LOG} 		: $0 =~ s/\.pl/.log/is; }
	unless ($data->{MAX_DEPTH})	{ $data->{MAX_DEPTH}	= (is_hash($conf) and $conf->{thresholds}->{MAX_DEPTH})?	$conf->{thresholds}->{MAX_DEPTH} 	: 10; }
	unless ($data->{TOUCH}) 	{ $data->{TOUCH}	= (is_hash($conf) and $conf->{system}->{TOUCH})? 		$conf->{system}->{TOUCH} 		: "/bin/touch"; }

	$data->{transaction} = $transaction;
	$data->{line} = $line;

	return $data; }

sub get_sub_name {	# returns the name of the calling subroutine
	my $x = $_[0];  $x = 1 unless $x;	# how far back to go

	#my ($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require) = caller(1);
	my $subroutine = (caller($x))[3] || "main";
	$subroutine =~ s/^.*::([^:]+?)$/$1/gis;
	my $line = (caller($x-1))[2] || 1;

	if ($subroutine =~ /execute/) {		# if this is an "execute" subroutine, get the caller of that one
		my $subroutine2 = (caller($x+1))[3] || "main";
		$subroutine2 =~ s/^.*::([^:]+?)$/$1/gis;
		my $line2 = (caller($x))[2] || 1;
		$subroutine = "$subroutine2(line $line2)->$subroutine"; }
	return ($subroutine, $line); }

sub get_sub_chain {	# returns the chain of the calling subroutines
	my $x = $_[0];  $x = 1 unless $x;	# how far back to go
	my $reverse = $_[1] || 0;
	my $caller = "";
	while (caller($x) and $x < 10) {
		if (my $subroutine = (caller($x))[3]) {
			$subroutine =~ s/^.*::([^:]+?)$/$1/gis;
			my $line = (caller($x-1))[2] || 1;
			if ($subroutine !~ /^(handler|default_handler|run|\(?eval)/) { $caller = ($reverse? $caller."<-" : "->").$subroutine."(line $line)".($reverse? "" : $caller); } }
		$x++; }
	$caller = $reverse? $caller."<-main" : "main".$caller;
	return $caller; }

sub strip_junk { my ($x) = @_;
	$x = "" unless $x;
	$x =~ s/[^[:print:]]//gs;			# remove non-printable characters
	$x =~ s/[^\x00-\xB1]/?/g;			# include just the ASCII range
	$x =~ s/\s+/ /gs;					# reduce multiple spaces to one space
	return $x; }

1;
