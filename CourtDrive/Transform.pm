package CourtDrive::Transform;

=head1 NAME
CourtDrive Data Transformer Module

=head2 SYNOPSIS
C<< use CourtDrive::Transform qw(coerce strip_junk convert_json convert_pdf convert_xlsx); >>

=head2 DESCRIPTION
Functions for sanitizing and changing one format to another

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use JSON::XS;
use Data::Dumper;
use HTML::TableExtract;
use HTML::HTMLDoc;
use Excel::Writer::XLSX;
use Try::Tiny;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Debug 	qw(debug errlog is_array is_hash is_scalar is_null is_empty);

# export public subroutine symbols
use Exporter			qw(import);
our @EXPORT_OK =		qw(coerce convert_json convert_pdf convert_xlsx);

my $half = 0.50000000000008;	# as per Math::Round, this is the lowest value that gives acceptable results

sub coerce {													# replaces a string with the type specified or the passed-in default value if none
	my ($x, $type, $default, $len1, $len2, $round, $name) = @_;	# truncates it to the length indicated by the optional fourth value passed in
	my $default_defined = 0; 									# if a decimal, also truncates the decimal part by the fifth value

	$default = printable_or_blank($default);

	if ($default_defined == 0 and $default eq "zero" and $type eq "num") { $default = 0; $default_defined = 1; }
	if ($default_defined == 0 and $default eq "one" and $type eq "num") { $default = 1; $default_defined = 1; }
	if ($default_defined == 0 and $default =~ /^\s*?(\d+)\s*?$/ and $type eq "num") { $default = $1; $default_defined = 1; }

	if ($default_defined == 0 and ($default eq "zero"	or $default eq "0")	and ($type eq "dec"	or $type eq "rmoney"	or $type eq "money")) { $default = 0.0; $default_defined = 1; }
	if ($default_defined == 0 and ($default eq "one"	or $default eq "1")	and ($type eq "dec"	or $type eq "rmoney"	or $type eq "money")) { $default = 1.0; $default_defined = 1; }
	if ($default_defined == 0 and $default =~ /^\s*?(\d+?(\.\d+)?)\s*?$/	and ($type eq "dec"	or $type eq "rmoney"	or $type eq "money")) { $default = $1; $default_defined = 1; }

	if ($default_defined == 0 and $default eq "epoch_start") { $default = epoch_start(); $default_defined = 1; }
	if ($default_defined == 0 and ($default eq "blank" or is_blank($default))) { $default = ""; $default_defined = 1; }
	if ($default_defined == 0 and $type =~ /bool/ and $default eq "false") { $default = 0; $default_defined = 1; }
	if ($default_defined == 0 and $type =~ /bool/ and $default eq "true") { $default = 1; $default_defined = 1; }

	if ($default_defined == 0) { $default = undef; $default_defined = 1; }

	if ($type eq "rmoney") { $len1 = 64 if !$len1; $len2 = 2 if !$len2; $round = 1 if !$round; }

	$x = (defined $x and !is_null($x))?		$x:$default;					# if x is undefined or null, use the default

	$type = 'str' if $type =~ /^(html|report|url_encoded|ssn|fein|zip|password|csv|pipe-delim)/;

	$x = printable_or_blank($x)						if $type =~ /^(print|str)/;
	$x = words_or_blank($x)							if $type =~ /^word/;
	$x = num_or_undef($x, $len1)					if $type =~ /^(num|int)/;
	$x = dec_or_undef($x, $len1, $len2, $round)		if $type =~ /^(dec|money)/;
	$x = date_or_undef($x)							if $type =~ /^date/;
	$x = ((is_scalar($x) and $x) or
	      (!is_scalar($x) and !is_empty($x)))? 1:0	if $type =~ /^bool/;			# booleans are true for non-empty hashes or arrays or true scalars
	$x = $x											if $type =~ /^(hash|array)/;	# do not modify hashes or arrays with coerce although this function may receive hash or array types from get_cgi_params

	my $return = (defined $x and !is_null($x) and ($x or ($type =~ /(num|int|dec|money)/ and is_zero($x)) or ($type =~ /(print|word|str)/ and !is_blank($x))))? $x : $default;

	return $return; }

sub num_or_undef {										# replaces a string with the number value of digits it contains or undef if none
	my ($x, $len) = @_;									# truncates it to the length indicated by the optional second value passed in
	return undef unless defined $x and $x =~ /\d/;
	$len = 64 unless $len;								# maximum length of the number
	my $mult = ($x =~ /^\s*?-/)? -1 : 1;
	$x = sprintf("%.10f", $x) if $x =~ /e[+\-]?\d+$/;	# convert exponential notation to decimal notation
	$x =~ s/[^0-9]//gis;								# remove anything not a digit
	return (defined $x and $x =~ /^(\d{1,$len}).*?$/)? 1*$1*$mult : undef; }

sub is_zero { my ($x) = @_; return $x == 0? 1 : 0; }

sub dec_or_undef {										# replaces a string with the best representation of a decimal number it contains, adding padding if necessary
	my ($x, $len1, $len2, $round) = @_;					# truncates both before and after the decimal point to the lengths indicated by the 2nd and 3rd values passed in
	return undef unless defined $x and $x =~ /\d/;
	my $mult = ($x =~ /^\s*?-/)? -1 : 1;
	$len1 = 64 unless defined $len1;					# length of the integer portion
	$len2 = 64 unless defined $len2;					# length of the fractional portion
	$round = 1 unless defined $round;					# how to treat the truncation of the fractional part -- default to rounding
	$x = sprintf("%.10f", $x) if $x =~ /e[+\-]?\d+$/;	# convert exponential notation to decimal notation
	$x =~ s/[^0-9.]//gis;								# remove anything not a digit or decimal point
	$x .= ".0" unless $x =~ /\./ or !$len2;				# ensure there's a decimal point if there's a non-zero $len2 precision argument
	$x = "0".$x unless $x =~ /^\d/ or !$len1;			# ensure there's a digit at the front if there's a non-zero $len1 argument
	$x .= "0" unless $x =~ /\d$/ or !$len2;				# ensure there's a digit at the end if there's a non-zero $len2 precision argument
	$x =~ s/.*?(\d+?\.\d+?).*?/$1/gis;					# remove extraneous characters (periods) around the number
	my $x1 = ($len1 and $x =~ /^(\d{1,$len1})/)? $1*1.0 : 0+0; # restrict size of whole number
	my $x2 = ($len2 and !$round and $x =~ /(\.\d{1,$len2})/)? $1 : ($len2 and $round and $x =~ /(\.\d+?)$/)? bankers_round($1,$len2) : 0+0; # restrict size of fractional part
	return	(($x1 or is_zero($x1)) and ($x2 or is_zero($x2)))? ($x1+$x2)*$mult*1.0 :
		(($x1 or is_zero($x1)) and !$x2 and !is_zero($x2))? $x1*$mult*1.0 :
		(!$x1 and !is_zero($x1) and ($x2 or is_zero($x2)))? $x2*$mult*1.0 :
		($x or is_zero($x))? $x*$mult*1.0 : undef; }

sub bankers_round { my ($n, $d) = @_;					# perform banker's round, aka Gaussian round, aka round half to even
	return undef unless defined $n;
	my $sign = ($n < 0) ? -1 : 1;
	my $x = $n * (10**$d);
	my $r = int(abs($x)+$half);
	my $br = (abs($x) - abs(int($x))) == 0.5? ($r % 2 == 0? $r : $r - 1) : $r;
	return $sign * ($br / 10**$d) * 1.0; }

sub epoch_start { return "1970-01-01 00:00:00.00"; }		# the beginning of Unix time

sub date_or_undef { my ($x) = @_;
	unless ($x and $x =~ /\d{4}\-\d{1,2}\-\d{1,2}(\s+?\d{1,2}:\d{1,2}:\d{1,2}(?:\.\d+?)?)?/) { $x = undef; } #$x = "1970-01-01 00:00:00.00";
	return $x; }

sub is_blank { my ($x) = @_; return $x =~ /[[:print:]]/? 0 : 1; }

sub printable_or_blank { my ($x) = @_;
	return "" unless defined $x;
	$x =~ s/[ \t\r\f]+?/ /gs;				# reduce multiple spaces (except newlines) to one space
	$x =~ s/[^[:print:]\n]//gs;				# remove non-printable characters other than newlines
	#errlog({}, "printable_or_blank($x) ==> ".($x=~/^\s*?([[:print:]\n]+).*?$/? $1 : ""));
	return $x=~/^\s*?([[:print:]\s*?\n]+).*?$/? $1 : ""; }

sub words_or_blank { my ($x) = @_;
	return "" unless defined $x;
	return $x=~/[A-Za-z]+?/? $x : ""; }

##########################
###### CONVERT JSON ######
##########################

sub convert_json {						# convert the data structure to JSON format
	my $data = shift; my $json_utf8_text = "";

	try {
		my $json = new JSON::XS;
		$json->utf8(1)->pretty(1);
		$json_utf8_text = $json->encode($data); }
	catch {
		my $error = "JSON::XS->new->utf8->encode() failed: $_\n$json_utf8_text";
		if ($error =~ /maximum nesting level/) { $error .= "dumping data: ".(Dumper $data); }
		return $error; }
	finally {
		unless ($@) { return $json_utf8_text; }
		else { return "convert_json failed: ".(Dumper $@); }}; }

##########################
####### CONVERT PDF ######
##########################

sub convert_pdf {					# convert an html-formatted string to pdf format
	my $str = shift; my $error = ""; my $pdf_content;
	my $htmldoc = new HTML::HTMLDoc('mode'=>'file', 'tmpdir'=>'/tmp') or $error .= "Couldn't load HTMLDoc: $!\n\n";

	unless ($error) {
		$htmldoc->set_html_content($str) or $error .= "Couldn't set HTML content: $!\n\n";
		$htmldoc->set_permissions('annotate', 'print', 'no-modify');
		$htmldoc->links();
		$htmldoc->title();
		$htmldoc->set_browserwidth(1024);
		$htmldoc->set_fontsize(6);
		$htmldoc->set_compression(6);
		$htmldoc->set_header('.', '.', '.');
		$htmldoc->set_footer('t', 'D', '/');
		$htmldoc->set_pagemode('document');
		$htmldoc->landscape();

		my $pdf = $htmldoc->generate_pdf() or $error .= "Couldn't generate PDF: $!\n\n";
		$pdf_content = $pdf->to_string() or $error .= "Couldn't create string from PDF: $!\n\n"; }

	unless ($error) { return $pdf_content; }
	else { return "Error Creating PDF:\n\n $error"; }}

##########################
###### CONVERT XLSX ######
##########################

sub convert_xlsx {					# convert an html-formatted string to xlsx (MS Excel) format
	my $str = shift; my $error = ""; my $xlsx_content;

	my @xlsx_write_error = (
		"success",
		"insufficient number of arguments",
		"row or column out of bounds",
		"string too long");

	my $rs = 0; 											# row start index
	my $re = 0; 											# row end index

	my @colID = ("A".."ZZ"); 								# array to hold up to 52 column letters

	if (open my $fh, '>', \$xlsx_content) {					# open a filehandle to which to write the Excel document as a string
		binmode $fh; #, ":utf8";
		my $workbook  = Excel::Writer::XLSX->new( $fh );	# create a new Excel workbook linked to the file handle
		$error .= "Error creating new Excel file: $!" unless defined $workbook;
		my $worksheet;

		unless ($error) {
			my $title = $str =~ /<title>(.*?)<\/title>/is? $1 : "";	# fetch the page title if there is one
			$title = substr $title, 0, 31;								# truncate to fit worksheet limits
			$worksheet = $workbook->add_worksheet( $title );			# create a new worksheet using the title of the report
			$error .= "Error creating new Excel worksheet: $!" unless defined $worksheet; }

		my $te = HTML::TableExtract->new();								# extract the tables from the HTML
		$error.= "Error extracting tables from HTML: $!" unless defined $te;

		unless ($error) {
			$te->parse($str);
			foreach my $table ($te->tables)	{							# insert any tables into the Excel worksheet
				my $rcount = scalar @{$table->rows};					# count the rows
				my $ccount = $table->columns; 							# count the columns
				my $ce = $ccount-1; 									# number index of the last column
				my $cel = $colID[$ce]; 									# letter index of the last column

				$rs = $re+1; 											# set the beginning of this table to after the end of the last one
				$re = $rs+$rcount-1; 									# set the end of this table to the starting row plus the row count

				my @columns = $table->columns(); 						# extract the columns as an array of arrayrefs
				my $header_row = []; 									# define the arrayref to hold the header row
				my @col_width; 											# define the array to hold the calculated widths of each column

				for my $col (0 .. $ce) {								# write and format columns
					my $hformat	= $workbook->add_format( color=>'black', bold=>1, font=>'Calibri', size=>11 ); 	# header format
					my $format	= $workbook->add_format( color=>'black', bold=>0, font=>'Calibri', size=>11 ); 	# data format
					$format->set_align( 'left' );
					if ($table->cell(0,$col) and $table->cell(0,$col) =~ /amount|total|cost|price/i) { $format->set_num_format( '$#,##0.00' ); $format->set_align( 'right' ); }	# define format for currency columns
					elsif ($table->cell(1,$col) and $table->cell(1,$col) =~ /^\d+?$/i) { $format->set_num_format( 'General' ); $format->set_align( 'right' ); }					# define format for number columns
					$col_width[$col] = col_width(@{$columns[$col]}); 	# find the widest item in the column
					push @$header_row, { header => (shift @{$columns[$col]}) }; # take the header off of the column for proper formatting of numbers
					my $err = $worksheet->write( $rs, $col, $header_row->[$col]->{header}, $hformat );	# write the header
					if ($err<0) { $error .= "Failed to write header row '".$header_row->[$col]->{header}."' because ".$xlsx_write_error[0-$err]."."; }
					$err = $worksheet->write_col( ($rs+1), $col, $columns[$col], $format );
					if ($err<0) { $error .= "Failed to write column under '".$header_row->[$col]->{header}."' because ".$xlsx_write_error[0-$err]."."; }
					$worksheet->set_column( ($rs+1), $col, $col_width[$col] ); } # set the width to the widest item

				$worksheet->add_table( $rs, 0, $re, $ce, { total_row => 0, banded_rows => 1, banded_columns => 0, columns => $header_row } ); }	# add the table
			$workbook->close(); }} 										# $xlsx_content does not get written until this point
	else { $error .= "Failed to open filehandle: $!"; }

	unless ($error) { return $xlsx_content; }
	else { return "Error Creating XLSX:\n\n $error"; }}

sub col_width {
	my $limit = 60;
	my $max = 10;								# default column width
	for (0 .. $#_) {							# for each index in the column array passed in
		my $len = length $_[$_] || 0;  			# get length once per item
		if ($len > $max) { $max = $len; }}		# update max if larger
	return $max+3>$limit? $limit : $max+3; }	# return the largest width with some padding, up to the limit

1;