#!/usr/bin/perl

# this is the only stuff anyone should need to possibly change in this file
use constant PROGRAM_CONF => "kroll_parser.conf";			# the configuration file location relative to the present working directory

# to make dependency installation easy, just run:
#	PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install lazy'
# then uncomment this line:
# use lazy 				qw(-g --pp);						# install any missing modules, globally if possible
# then the script will auto-install all dependencies the first time you run it

# run "perldoc kroll_parser.pl" or "kroll_parser.pl --help" to read this documentation properly formatted
# generate README.pod by running "podselect kroll_parser.pl > README.pod"

=head1 NAME

CourtDrive Kroll Web Scraper

=head1 SYNOPSIS

Output a raw JSON file:

	perl kroll_parser.pl --url=https://cases.ra.kroll.com/seadrillpartners/Home-ClaimInfo --recursive=100 --format=json > B<2023-07-25.json> &

Optionally format the output:

	perl kroll_parser.pl B<--file=2023-07-25.json> --format=pdf > 2023-07-25.pdf
	perl kroll_parser.pl B<--file=2023-07-25.json> --format=xlsx > 2023-07-25.xlsx

=head1 DESCRIPTION

This script combines:

=over 4

=item * a web client which performs HTTP requests on behalf of a user

=item * a parser to find all claims in the scraped HTML and relevant meta data and build a tree

=back

=head1 OPTIONS

=over 4

=item B<--debug>=I<N>

=over 4

=item B<0> = no debugging output, non-verbose

=item B<1> = basic operational output

=item B<2> = technical debugging info

=item B<3> = in-depth debugging info

=back

=item B<--noverbose>

equivalent to debug=0

=item B<--verbose>

equivalent to debug=1

*note* make the debug or verbose option first to get debugging output on the remaining options

=item B<--url>=I<http://domain/path/to/scrape/>

this URL will be scraped for data

=item B<--recursive>=I<N>

follow links to nested HTML pages to this depth (defaults to zero/false)

=item B<--format>=I<html>

format of the report output -- options include txt, json, html, pdf, and xlsx

=item B<--file>=I<report.json>

import a report data tree from a json-formatted file (i.e. the output of I<perl kroll_parser.pl --format=json>), enabling multiple calculation and viewing options on the same data

=back

=head1 AUTHOR

	Thomas Anderson
	tanderson@orderamidchaos.com

=head1 COPYRIGHT

Copyright 2023

=cut

# use tab width = 4 for proper alignment of this code in a fixed-width font

use Pod::Usage			qw(pod2usage);							# print a usage message from embedded POD documentation
use Data::Dumper;												# stringify Perl data structures
use Data::URIEncode		qw(complex_to_flat);					# flatten data structures for POSTing
use POSIX				qw(strftime);							# Perl-ish interfaces to the standard POSIX 1003.1 identifiers
use Benchmark;													# benchmark running times of Perl code
use File::Basename		qw(dirname basename);					# file name routines
use Cwd					qw(abs_path);							# directory path module
use Fcntl 				qw(:DEFAULT :flock);					# file locking constants
use IO::Zlib;													# work with gz files
use List::Util			qw(reduce);								# sum values within complex data structures
use Hash::Merge 		qw(merge);								# deep merge two hashes
use JSON::XS			qw(decode_json);						# decode JSON objects into Perl objects

use constant PWD => dirname(abs_path __FILE__);					# program executable lives in PWD
use lib PWD;													# add our module directory to @INC (CourtDrive modules should live in PWD/CourtDrive)
use CourtDrive::Config		qw(read_config);					# load our modules during compile phase
use CourtDrive::Debug		qw(debug errlog is_array is_hash is_empty check_data check_conf);
use CourtDrive::Decode		qw(decode_utf_str encode_url);
use CourtDrive::Input		qw(get_params get_commandline_options);
use CourtDrive::Agent		qw(content protocol domain path report error has_error);
use CourtDrive::Transform	qw(coerce convert_json convert_pdf convert_xlsx);
use CourtDrive::File 		qw(list_files lock_file read_data);

use constant CONF 		=> read_config(PROGRAM_CONF);			# constant hashref CONF contains all of the configuration info from the PROGRAM_CONF file

																# basic script security stuff
$> = $<; $) = $(;												# set effective UID to real UID and effective GID to real GID to prevent masquerading as someone else
delete @ENV{qw(IFS CDPATH ENV BASH_ENV PATH SHELL)};			# make environment safer by deleting variables that may have been mucked with outside our control
$ENV{PATH}	= CONF->{system}->{PATH};							# instead, set the environment explicitely according to our strict definitions
$ENV{SHELL}	= CONF->{system}->{SHELL};

my $data = check_data({ failure=>0, error=>"", debug=>"", debug_level=>0, urls=>[], logs=>[]}, CONF);	# initialize global accumulator object

errlog($data, "failed to load configuration file") unless is_hash(CONF) and CONF->{VERSION};			# make sure we've loaded the configuration file

get_commandline_options($data,									# parse the command line options and return the results to $data
#	[var_name, 			placeholder,	format,		required]
	['debug',			'',				'num',		0],			# placeholder field allows us to share format_variables subroutine with get_commandline_options
	['verbose!',		'',				'bool',		0],			# exclamation point means it's a negatable option, i.e. --noverbose gets 0 value
	['help',			'',				'bool',		0],
	['url',				'',				'str',		0],
	['recursive!',		'',				'num',		0],
	['format',			'',				'str',		0],
	['file',			'',				'str',		0]);

errlog($data, $data->{error}) if $data->{error};				# report any errors getting command line options

pod2usage({-verbose => 2, -exitval => 1}) if $data->{help};
pod2usage({-verbose => 2, -exitval => 2, -message => "You must either pass in a URL to scan or a pre-compiled JSON file."}) unless $data->{file} or $data->{url};

##########################
########## MAIN ##########
##########################

my $merge = Hash::Merge->new( 'RIGHT_PRECEDENT' );						# initialize the deep merge function

if ($data->{file}) {
	my $saved_data = read_data($data->{file});							# get the data from a previously exported file
	delete @{$data}{ grep { not defined $data->{$_} } keys %{$data} };	# remove undef values from $data so they don't overwrite the merged values
	$data = $merge->merge( $saved_data, $data );						# merge the file data into the $data object
	debug($data, "Merged data object: ".Dumper($data), 1); }
else {
	my $start_time = new Benchmark;										# start timing the entire scraping process
	$data->{items}->{claims} = get_claims();							# parse the url for claims and return the results to $data->{items}
	my $end_time = new Benchmark;										# calculate total running time for scraping URLs and parsing
	my $td = timediff($end_time, $start_time);							# calculate benchmarking info
	$data->{wall_time}	= $td->[0];
	$data->{cpu_time}	= int(1000*($td->[1]+$td->[2]+$td->[3]+$td->[4]+0.0005))/1000; }

	$data->{format} = $data->{format}? $data->{format} : 'txt';			# default output format

if ($data->{format} eq 'txt' or $data->{format} eq 'html' or $data->{debug_level}) {
	say "Found ".$data->{claim_count}." claims at ".$data->{url}.($data->{recursive}? ", recursively" : "");
	say "Total time to scrape and analyze: ".$data->{wall_time}."s wall, ".$data->{cpu_time}."s cpu";
	say "Results: ".Dumper($data->{items}); }
if ($data->{format} eq 'json')	{ say convert_json($data->{items}); }
if ($data->{format} eq 'pdf')	{ binmode STDOUT; say convert_pdf($data->{items}); }
if ($data->{format} eq 'xlsx')	{ binmode STDOUT; say convert_xlsx($data->{items}); }

############################
######## GET CLAIMS ########
############################

sub get_claims {												# get_claims subroutine scrapes the given URL for claims
	my $url = shift || $data->{url} || return "";				# pass in the URL to scrape or get it from $data
	my $lvl = coerce(shift, "num", 1);							# start counting depth of recursion in order to impose the configured limits
	my $max = coerce($data->{recursive}, "num", "zero");

	# only follow down to the depth of the recursion specified or max limit
	$max = CONF->{thresholds}->{MAX_LINKS} if $max > CONF->{thresholds}->{MAX_LINKS};
	if ($lvl > $max) { debug($data, "Reached maximum recursion depth = ".$max, 1); return []; }

	my $claims = []; 											# create an arrayref to hold the list of claims discovered in the HTML
	my $start_time = new Benchmark;								# start timing the website scraping process
	my $params = CONF->{params};								# load the parameters specified in the configuration file
	$params->{page} = $lvl if $lvl;								# increment the page number if passed in

	# initialize the user agent and fetch the page
	my $agent = CourtDrive::Agent->new(CONF, $url, complex_to_flat($params), $data->{debug_level}) or errlog($data, CourtDrive::Agent->error);
	if ($agent->has_error) { errlog($data, "web client failed: ".$agent->error); } else { debug($data, "initialized web agent", 2); }
	debug($data, $agent->report, 2) if $data->{debug_level} and $agent->report;

	# parse the page content
	my $content = ($agent->has_error)? $agent->error : $agent->content;
	if (($agent->content_type =~ /text\//i and $content !~ /<frameset/i) and !$agent->has_error) { # parse HTML output
		my $total_pages = ($content =~ /<span id="p-total-pages" class="p-total-pages">(\d+?)<\/span>/)? $1 : 1;	# figure out how many pages of claims there are

		$content =~ s/^.*?<table id="results-table"[^>]*?>(.+?)<\\table>.*?$/$1/gis;	# get just the results table
		debug($data, "examining for claims: $content", 3);

		while (															# fetch any rows within the table
			$content =~ s/(?:<(tr) role="row"[^>]*?>)					# match an opening row tag						(group 1)
					((?:.(?!(?:<\/?\s*?(?:\1))))*?)						# any amount of anything not a row tag			(group 2)
					(?:$|(?:<\/\s*?(?:\1)\s*?>))						# matching close row tag or end of string		(non-capturing)
					//isx) { 											# consume the HTML so eventually the while loop exits
			my $claim_row = $2;
			my $claim = {}; $claim->{amounts} = [];
			while (														# fetch any columns within the row
				$claim_row =~ s/(?:<(td) role="gridcell"[^>]*?>)		# match an opening column tag					(group 1)
					.+?class="tablesaw-cell-label">(.+?)<\/[^>]+?>		# match a data label							(group 2)
					.+?class="tablesaw-cell-content">(.+?)<\/[^>]+?>	# match data content							(group 3)
					(?:.(?!(?:<\/?\s*?(?:\1))))*?						# any amount of anything not a column tag		(non-capturing)
					(?:$|(?:<\/\s*?(?:\1)\s*?>))						# matching close column tag or end of string	(non-capturing)
					//isx) {											# consume the HTML so eventually the while loop exits
				my $label = $2; my $value = $3;
				if ($value =~ /<a onclick="ShowClaims(.+?)"[^>]*?>(.+?)[^>]*?<\/a>/) {
						my $claim_id = $1; $value = $2;
							my $claim_url = $agent->protocol . $agent->domain . $agent->path . "/Home-CreditorDetailsForClaim";
							my $claim_params = "id=".encode_url($claim_id);
							get_claim_details($claim, $claim_url, $claim_params); }
				$claim->{$label} = $value; }
			push @{$claims}, $claim unless is_empty($claim); }

		if ($lvl < $total_pages and $lvl < $max) {		# iterate through the pages until completed
				$url = $agent->protocol . $agent->domain . $agent->path . "/Home-LoadClaimData";
				debug($data, "$lvl: following: $url to page ".($lvl+1)." (current level $lvl, authorized recursion $max)", 2);
				my $deeper_claims = get_claims($url, $lvl+1);
				$claims = $merge->merge($claims, $deeper_claims) if unless is_empty($deeper_claims);
		}}
	elsif ($agent->content_type =~ /application\/json/i and !$agent->has_error) {	# parse JSON output
		my $content_json = decode_json $content or return errlog($data, "URL $url cannot be decoded as JSON.");
		my $lvl = 1;															# start counting how many pages we parse in order to impose the configured limits
		my $total_pages = $content_json->{total}? $content_json->{total} : 1;		# figure out how many pages of claims there are

		foreach my $claim_row (@{$content_json->{rows}}) {										# iterate over the claim rows
			my $claim = {}; $claim->{amounts} = [];
			foreach my $column (keys %{$claim_row}) {											# iterate over the columns
				$claim_row->{$column} = decode_utf_str($claim_row->{$column});
				if ($claim_row->{$column} =~ /
						.+?class="tablesaw-cell-label">(.+?)<\/[^>]+?>							# match a data label	(group 1)
						.+?class="tablesaw-cell-content">(.+?)<\/[^>]+?>						# match data content	(group 2)
						/isx) {
					my $label = $1; my $value = $2;
					if ($value =~ /<a onclick="ShowClaims(.+?)"[^>]*?>(.+?)[^>]*?<\/a>/) {
							my $claim_id = $1; $value = $2;
							my $claim_url = $agent->protocol . $agent->domain . $agent->path . "/Home-CreditorDetailsForClaim";
							my $claim_params = "id=".encode_url($claim_id);
							get_claim_details($claim, $claim_url, $claim_params); }
					$claim->{$label} = $value; }
				else { $claim->{$column} = $claim_row->{$column}}}
			push @{$claims}, $claim unless is_empty($claim); }

		if ($lvl < $total_pages and $lvl < $max) {				# iterate through the pages until completed
				debug($data, "$lvl: following: $url to page ".($lvl+1)." (current level $lvl, authorized recursion $max)", 2);
				my $deeper_claims = get_claims($url, $lvl+1);
				$claims = $merge->merge($claims, $deeper_claims) if unless is_empty($deeper_claims);
		}}
	else { errlog($data, "URL $url could not be parsed."); }

	my $end_time = new Benchmark;								# calculate total running time
	my $td = timediff($end_time, $start_time);					# calculate benchmarking info
	debug($data, "Found ".(scalar @{$claims})." claims at this level, depth $lvl", 2);
	debug($data, "Total time to scrape: ".$td->[0]." wall, ". int(1000*($td->[1]+$td->[2]+$td->[3]+$td->[4]+0.0005))/1000 ." cpu", 2);

	return $claims; }

sub get_claim_details {											# get_claims subroutine scrapes the given URL for claims
	my $claim = shift;											# data structure for this claim
	my $url = shift;											# URL for the claim details
	my $params = shift;											# POST parameters

	# initialize the user agent and fetch the page
	my $agent = CourtDrive::Agent->new(CONF, $url, $params, $data->{debug_level}) or errlog($data, CourtDrive::Agent->error);
	if ($agent->has_error) { errlog($data, "web client failed: ".$agent->error); } else { debug($data, "initialized web agent", 2); }
	debug($data, $agent->report, 2) if $data->{debug_level} and $agent->report;

	# parse the page content
	my $content = ($agent->has_error)? $agent->error : $agent->content;
	if (($agent->content_type =~ /text\//i and $content !~ /<frameset/i) and !$agent->has_error) {
		while (															# fetch any columns within the row
				$content =~ s/
					.+?class="label label--small">(.+?)<\/[^>]+?>		# match a data label							(group 1)
					.+?class="value">(.+?)<\/[^>]+?>					# match data content							(group 2)
					//isx)												# consume the HTML so eventually the while loop exits
			{ $claim->{$1} = $2; }

		$content =~ s/^.*?<table id="claim-table [^>]*?>.+?<tbody>(.+?)<\\tbody>.*?$/$1/gis;	# get just the results table
		debug($data, "examining for claim details: $content", 3);
		$claim->{amounts} = [] unless is_array($claim->{amounts});

		while (															# fetch any rows within the table
			$content =~ s/(?:<(tr)[^>]*?>)								# match an opening row tag						(group 1)
					((?:.(?!(?:<\/?\s*?(?:\1))))*?)						# any amount of anything not a row tag			(group 2)
					(?:$|(?:<\/\s*?(?:\1)\s*?>))						# matching close row tag or end of string		(non-capturing)
					//isx) {											# consume the HTML so eventually the while loop exits
			my $amount_row = $2;
			my $amount = {};
			while 														# fetch any columns within the row
				$amount_row =~ s/(?:<(td) role="gridcell"[^>]*?>)		# match an opening column tag					(group 1)
					.+?class="tablesaw-cell-label">(.+?)<\/[^>]+?>		# match a data label							(group 2)
					.+?class="tablesaw-cell-content">(.+?)<\/[^>]+?>	# match data content							(group 3)
					(?:.(?!(?:<\/?\s*?(?:\1))))*?						# any amount of anything not a column tag		(non-capturing)
					(?:$|(?:<\/\s*?(?:\1)\s*?>))						# matching close column tag or end of string	(non-capturing)
					//isx) {											# consume the HTML so eventually the while loop exits
				$amount->{$1} = $2; }
			push @{$claim->{amounts}}, $amount if is_hash($amount); }}}
