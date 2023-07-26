package CourtDrive::Input;

=head1 NAME
CourtDrive Input Module

=head2 SYNOPSIS
C<< use CourtDrive::Input qw(get_params get_commandline_options kill_params); >>

=head2 DESCRIPTION
Functions for obtaining input data.

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load public perl modules and import symbols into the namespace
use Modern::Perl;
use Getopt::Long			qw(GetOptions);
use JSON::XS;
use Data::Dumper;
use Encode;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Debug		qw(debug_type end_debug_type debug errlog is_array is_hash check_conf check_data);
use CourtDrive::Transform	qw(coerce);
use CourtDrive::Decode		qw(decode_utf_str decode_url);

# export public subroutine symbols
use Exporter				qw(import);
our @EXPORT_OK =			qw(get_params get_commandline_options kill_params);

# create list of reserved variable names that are not allowed to be used for parameters
use constant RESERVED_VARS => [qw(cgi get post querystring error)];	# "debug" is a special case we'll handle later and should not be added here

sub get_params {					# import the subroutine parameters into $data, perform validation, and return hash
	my $data = check_data(shift);	# ensure data object is reasonably complete for basic operations / set transaction name
									# take the first value off of the stack because we're going to loop through the rest of the values later
									# we can't assume that we've received a hashref, so we need to pass out a hashref as the known $data
	debug($data, "starting get_params... pass in debug_type=input for more debugging info\n", 2) unless $data->{debug_type} and $data->{debug_type} =~ /input/;
	debug_type($data, 'input');
	foreach my $param (@_) {
		if (is_array($param) and defined $param->[0] and defined $param->[2] and $param->[2] =~ /[[:alnum:]]/ and $param->[2] !~ /^\s*(?:null|undefined)\s*$/) {
			$data->{error} .= errlog($data, "You may not use \"".$param->[0]."\" as a subroutine parameter name because it is reserved.") if grep { $_ eq $param->[0] } @{+RESERVED_VARS};	# prevent collisions with our $data object by disallowing certain reserved names
			my $input_name	= coerce($param->[0], "printable", "blank");
			my $format 	= coerce($param->[2], "printable", "blank");
			my $required 	= coerce($param->[3], "num", "zero");
			my $output_name = $input_name;										# alias $param->[0] for readability and disambiguation
			if ($output_name eq "debug") { $output_name = "debug_level"; }		# special case for passing in the debug level and disambiguating it from our debug output

			$data->{$output_name} = $param->[1];								# extract the variable

			if (!defined $data->{$output_name}) {
				if ($format eq "bool") {										# for booleans, just define failed options as false if they're required
					$data->{$output_name} = 0 if $required; }
				elsif ($format eq "array") {									# for arrays, just define failed options as empty arrays
					$data->{$output_name} = [] if $required; }
				elsif ($format eq "hash") {										# for hashes, just define failed options as empty hashes
					$data->{$output_name} = {} if $required; }
				else {															# complain about non-boolean failed options if required
					$data->{error} .= errlog($data, "Failed to get required option ".$output_name,
					" in ".$data->{transaction}."(line ".$data->{line}.").") if $required; }}
			else {																# complain if there was an error extracting or untainting
				debug($data, "formatting ".$output_name." = ".$data->{$output_name}." = ".(Dumper $data->{$output_name}), 2) if $data->{transaction} !~ /(errlog|debug)/ and $output_name and defined $data->{$output_name};
				format_variable($data, $param, $data->{transaction}, $data->{line}, $output_name, $output_name) if $output_name and defined $data->{$output_name};
				$data->{error} .= errlog($data, $output_name."=".$data->{$output_name}." is not in the proper format.", " in ".$data->{transaction}."(line ".$data->{line}.").") if !defined $data->{$output_name} and $required; }}
		else { $data->{error} .= errlog($data, "bad request formatting param ".$param.": is_array? ".is_array($param).", defined param->[0]? ".(defined $param->[0]).", defined param->[1]? ".(defined $param->[2]).", param->[0]: ".($param->[0]).", param->[1]: ".($param->[2])); }}
	end_debug_type($data, 'input');
	$data->{got_params} = $data->{error}? 0:1;
	return $data->{got_params}; }					# return true on success or false on error

sub get_commandline_options {		# import the commandline options into $data, perform validation, and return hash
	my $data = check_data(shift);	# ensure data object is reasonably complete for basic operations / set transaction name
									# take the first value off of the stack because we're going to loop through the rest of the values later
									# we can't assume that we've received a hashref, so we need to pass out a hashref as the known $data
	my $optdef = {}; 				# create a structure to store the option processing definition
	my $params = [];				# save the input parameter definition list
	debug($data, "starting get_commandline_options... pass in debug_type=input for more debugging info\n", 2) unless $data->{debug_type} and $data->{debug_type} =~ /input/;
	debug_type($data, 'input');
	foreach my $param (@_) {		# build the option processing definition for GetOptions by looping through the input stack
		if (is_array($param) and defined $param->[0] and defined $param->[2] and $param->[2] =~ /[[:alnum:]]/ and $param->[2] !~ /^\s*(?:null|undefined)\s*$/) {
			my $input_name	= coerce($param->[0], "printable", "blank");
			my $format 	= coerce($param->[2], "printable", "blank");
			my $required 	= coerce($param->[3], "num", "zero");

			my $output_name = $input_name;										# alias $param->[0] for readability and disambiguation
			$output_name =~ s/([^|\|]*?)debug([^|\|]*?)/$1debug_level$2/gis;	# special case for passing in the debug level and disambiguating it from our debug output
			$data->{$output_name} = undef if !defined $data->{$output_name};	# set to undef if no valid data was passed in

			# prevent collisions with our $data object by disallowing certain reserved names
			$data->{error} .= errlog($data, "You may not use \"".$input_name."\" as a commandline option name because it is reserved.") if grep { $_ eq $input_name } @{+RESERVED_VARS};

			# get the type of option based on the format
			my $type = $format =~ /(str|date|pipe|file)/? "s" : $format eq "num"? "i" : $format eq "dec"? "f" : ""; # bools are left blank (no = value)

			my $op = $required? "=" : ":";										# get the operation (whether the option is required or optional)

			$optdef->{$input_name.($type? $op.$type : "")} = sub {				# extract the variable # define value-assigning subroutine to pass to GetOptions
										my ($opt_name, $opt_value) = @_;
										warn "Assigning data->{$output_name} = $opt_value from input $opt_name";
										$data->{$output_name} = $opt_value; };
			push @{$params}, $param; }											# add this parameter to the array so we can loop through and format later
		else { $data->{error} .= errlog($data, "bad request formatting param ".$param.": is_array? ".is_array($param).", defined param->[0]? ".(defined $param->[0]).", defined param->[1]? ".(defined $param->[2]).", param->[0]: ".($param->[0]).", param->[1]: ".($param->[2])); }}

	if (GetOptions(%{$optdef})) {												# get the options from the commandline
		foreach my $param (@{$params}) {										# untaint and format each retrieved value
			if (is_array($param) and defined $param->[0] and defined $param->[2] and $param->[2] =~ /[[:alnum:]]/ and $param->[2] !~ /^\s*(?:null|undefined)\s*$/) { # and $param->[1] !~ /^\s*(?:null|undefined)\s*$/i
				my $input_name	= coerce($param->[0], "printable", "blank");
				my $format 	= coerce($param->[2], "printable", "blank");
				my $required 	= coerce($param->[3], "num", "zero");

				my $output_name = $input_name;										# alias $param->[0] for readability and disambiguation
				$output_name =~ s/([^|\|]*?)debug([^|\|]*?)/$1debug_level$2/gis;	# special case for passing in the debug level and disambiguating it from our debug output
				$data->{$output_name} = undef if !defined $data->{$output_name};	# set to undef if no valid data was passed in

				if (!defined $data->{$output_name}) {
					if ($format eq "bool") {									# for booleans, just define failed options as false if they're required
						$data->{$output_name} = 0 if $required; }
					else {														# complain about non-boolean failed options if required
						$data->{error} .= errlog($data, "Failed to get required option ".$output_name,
						" in ".$data->{transaction}."(line ".$data->{line}.").") if $required; }}
				else {															# complain if there was an error extracting or untainting
					debug($data, "formatting ".$output_name." = ".$data->{$output_name}." = ".(Dumper $data->{$output_name}), 2) if $data->{transaction} !~ /(errlog|debug)/ and $output_name and defined $data->{$output_name};
					format_variable($data, $param, $data->{transaction}, $data->{line}, $output_name, $output_name) if $output_name and defined $data->{$output_name};
					$data->{error} .= errlog($data, $output_name."=".$data->{$output_name}." is not in the proper format.", " in ".$data->{transaction}."(line ".$data->{line}.").") if !defined $data->{$output_name} and $required; }}
			else { $data->{error} .= errlog($data, "bad request formatting ".$data->{transaction}."."); }}}
	else { $data->{error} .= errlog($data, "error in commandline argument processing: $!"); }
	end_debug_type($data, 'input'); }

sub format_variable { my ($data, $param, $subroutine, $line, $input_name, $output_name) = @_;
	unless (is_array($param)) { $data->{debug} = debug($data, "input param was not an array", 3); return; }
	$data->{transaction} = $subroutine if $subroutine;
	$data->{line}	= $line if $line;
	$input_name		= $param->[0] unless defined $input_name;
	$output_name	= $param->[0] unless defined $output_name;
	my $format		= coerce($param->[2], "printable", "blank");
	my $required 	= coerce($param->[3], "num", "zero");
	my $max_len		= coerce($param->[4], "num", "zero");

	if (defined $data->{$output_name} and defined $format) {
		unless (is_array($data->{$output_name}) or is_hash($data->{$output_name}) or Encode::is_utf8($data->{$output_name}, Encode::FB_PERLQQ)) { # decode UTF
			debug($data, "Decoding $output_name as $format...",3) if $data->{transaction} !~ /(errlog|debug)/;
			($data->{$output_name}, $data->{$output_name."_encoding"}, $data->{$output_name."_length"}) = decode_utf_str($data, $data->{$output_name}, 1); }

		unless ($data->{error}) {
			if ($max_len) {																		# truncate variables that explicitly call for it
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len); }

			if ($format eq 'num') {																# format numbers
				$data->{$output_name} =~ s/\D//gis;												# strip non-digits
				$data->{$output_name} = coerce($data->{$output_name}, "num", "zero"); }			# ensure it is a number

			elsif ($format eq 'int') {															# format integers
				$data->{$output_name} =~ s/[^\-[:digit:]]//gis;									# strip non-integer
				$data->{$output_name} = coerce($data->{$output_name}, "num", "zero"); }			# ensure it is an integer

			elsif ($format eq 'dec') {															# format decimals
				$data->{$output_name} =~ s/[^\-[:digit:].]//gis;								# strip non-decimal
				$data->{$output_name} = coerce($data->{$output_name}, "dec", "zero"); }			# ensure it is a decimal

			elsif ($format eq 'bool') {															# format booleans
				$data->{$output_name} = ($data->{$output_name} =~ /true|on|checked|yes/i || ($data->{$output_name} =~ /^\s*?(\d+?)\s*$/ and $1>0))? 1 : 0; }

			elsif ($format eq 'str') {															# format strings
				$max_len = $max_len? $max_len : 1000;
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len);				# ensure it is a sane length
				$data->{$output_name} .= qq~ (input truncated after \$max_len characters)~ if $2; }

			elsif ($format eq 'html') {															# format HTML strings
				$max_len = $max_len? $max_len : 32766;
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len);				# ensure it is a sane length
				$data->{$output_name} .= qq~ (input truncated after \$max_len characters)~ if $2; }

			elsif ($format eq 'date') {															# format dates
				$data->{$output_name} = ($data->{$output_name} =~ /^\s*([0-9\\\/\-\.:\s]+)\s*$/)? $1 : undef; }

			elsif ($format eq 'report') {														# format printable reports
				$max_len = $max_len? $max_len : 32766;
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len);				# ensure it is a sane length
				$data->{$output_name} .= qq~ (input truncated after \$max_len characters)~ if $2;
				$data->{$output_name} = decode_url($data->{$output_name}); }					# convert url-encoded characters

			elsif ($format eq 'url_encoded') {													# format url encoded strings
				$max_len = $max_len? $max_len : 1000;
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len);				# ensure it is a sane length
				$data->{$output_name} .= qq~ (input truncated after \$max_len characters)~ if $2;
				$data->{$output_name} = decode_url($data->{$output_name}); }					# convert url-encoded characters

			elsif ($format eq 'ssn') {															# format Social Security Numbers
				$data->{$output_name} =~ s/\D//gis;												# strip non-digits
				if ($data->{$output_name} =~ /\d/) {											# only add zeros if there's some digits, otherwise allow undef error below
					while ($data->{$output_name} !~ /^\d{1,9}$/) {								# pad short SSNs with leading zeros
						$data->{$output_name} = "0".$data->{$output_name}; }}
				$data->{$output_name} = ($data->{$output_name} =~ qr/^\s*?${\($data->{get_ssn})}\s*?$/)? $1 : undef; }

			elsif ($format eq 'fein') {															# format Federal Employer Identification Numbers
				$data->{$output_name} =~ s/\D//gis;												# strip non-digits
				if ($data->{$output_name} =~ /\d/) {											# only add zeros if there's some digits, otherwise allow undef error below
					while ($data->{$output_name} !~ /^\d{1,9}$/) {								# pad short FEINs with leading zeros
						$data->{$output_name} = "0".$data->{$output_name}; }}}

			elsif ($format eq 'zip') {															# format zip codes
				$data->{$output_name} =~ s/\D//gis;												# strip non-digits
				if ($data->{$output_name} =~ /\d/) {											# only add zeros if there's some digits, otherwise allow undef error below
					while ($data->{$output_name} =~ /^\d{6,8}$/ or								# pad short zips with leading zeros
						   $data->{$output_name} =~ /^\d{1,4}$/) { $data->{$output_name} = "0".$data->{$output_name}; }}}

			elsif ($format eq 'password') {														# format passwords
				$max_len = $max_len? $max_len : 20;
				$data->{debug} .= errlog($data, "$output_name length ".$data->{$output_name."_length"}." is more than $max_len characters ","on line ".$data->{line}." in ".$data->{transaction}.".") if $data->{$output_name."_length"} > $max_len;
				$data->{$output_name} = substr($data->{$output_name}, 0, $max_len);				# ensure it is a sane length
				debug($data, "input truncated after $max_len characters",2) if $2;
				$data->{$output_name} =~ s/[^[:print:]]//; }									# strip out non-printable characters

			elsif ($format eq 'hash') {															# format/initialize hash refs
				unless (exists $data->{$output_name} and defined $data->{$output_name} and is_hash($data->{$output_name})) {
					$data->{$output_name} = {};
					if ($required) { $data->{error} .= errlog($data,$output_name." is required and must be a hashref","on line ".$data->{line}." in ".$data->{transaction}."."); }}}

			elsif ($format eq 'array') {														# format/initialize array refs
				unless (exists $data->{$output_name} and defined $data->{$output_name} and is_array($data->{$output_name})) {
					$data->{$output_name} = [];
					if ($required) { $data->{error} .= errlog($data,$output_name." is required and must be an arrayref","on line ".$data->{line}." in ".$data->{transaction}."."); }}}

			elsif ($format eq 'csv') {															# format/initialize comma separated value lists
				unless (exists $data->{$output_name} and defined $data->{$output_name}) { $data->{$output_name} = []; }
				@{$data->{$output_name}} = split /,/, $data->{$output_name}; }

			elsif ($format eq 'pipe-delim') {													# format pipe-delimited lists
				$data->{$output_name} =~ s/\s/_/gis;
				$data->{$output_name."_array"} = [];
				@{$data->{$output_name."_array"}} = split(/\|/, $data->{$output_name});
				@{$data->{$output_name."_array"}} = grep /[[:alnum:]]/, @{$data->{$output_name."_array"}}; # only keep array elements which have alphanumeric content
				$data->{$output_name."_array"} = [] unless is_array($data->{$output_name."_array"});
				$data->{$output_name."_placeholders"} = join(',', ('?') x @{$data->{$output_name."_array"}});
				debug($data, $output_name."_array: ".join(",",@{$data->{$output_name."_array"}}), 2);
				debug($data, $output_name."_placeholders: ".$data->{$output_name."_placeholders"}, 2); }

			elsif ($format eq 'blob') {															# (don't) format blobs
				debug($data, $output_name." is being passed as a binary large object.", 2); }}}}

sub kill_params { 						# delete any input parameters that you don't want to pass back out through the data object via JSON
	my $data = shift;					# get the hashref, which modifies $data in the calling subroutine
	foreach my $param (@_) {			# loop through the parameters you want to squash and clean up related hash keys
		$data->{$param} 				= undef;
		$data->{$param.'_type'} 		= undef;
		$data->{$param.'_length'} 		= undef;
		$data->{$param.'_upload'} 		= undef;
		$data->{$param.'_tmpfile'}		= undef;
		$data->{$param.'_name'} 		= undef;
		$data->{$param.'_filename'} 	= undef;
		$data->{$param.'_format'} 		= undef;
		$data->{$param.'_array'} 		= undef;
		$data->{$param.'_placeholders'}	= undef; }}

1;
