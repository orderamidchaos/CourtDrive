package CourtDrive::Decode;

=head1 NAME
CourtDrive Decoder Module

=head2 SYNOPSIS
C<< use CourtDrive::Decode qw(decode_utf_str decode_url encode_url); >>

=head2 DESCRIPTION
Functions for decoding text formats

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use utf8::all;
use PerlIO::encoding;
use Encode;
use Encode::Detect::Detector;
use Encode::Guess;
use Encode::Unicode;
use Encode::Byte;
use Unicode::UCD 			qw(charinfo);
use Encoding::FixLatin 		qw(fix_latin);
use Encode::ZapCP1252;
use Text::Unidecode 		qw(unidecode);
use JSON::XS;
use Data::Dumper::Names;
use File::Type;
use File::Temp				qw(tempfile tempdir);
use File::Basename 			qw(fileparse);
use DBI 					qw(:utils :sql_types);
use DBI::Profile;
use Scalar::Util;
use List::Util;
use List::MoreUtils;
use Try::Tiny;
use HTML::Entities;

# load CourtDrive perl modules and import symbols into the namespace
use CourtDrive::Debug 		qw(debug errlog);
use CourtDrive::Transform 	qw(coerce);

# export public subroutine symbols
use Exporter				qw(import);
our @EXPORT_OK =			qw(decode_utf_str decode_url encode_url);

sub decode_utf_str {
	my ($data, $x, $force_utf8) = @_;
	my $encoding	= "";
	my $mime	= "";
	my $dbi_desc	= "";
	my $chars	= "";
	my $bytes	= "";
	my $wide	= "";

	unless (defined $data and defined $x) {
		debug($data, "exiting decode_utf_str because no".((!defined $x)? "input string" : "data object"), 3);
		return (undef, undef, 0); }

	my $ox = $x; # copy of $x which never gets manipulated by string functions
	debug($data, "running decode_utf_str with input string of length: ".length($x), 3);
	if (length($x) and $x !~ /^[\x00]/) { # make sure the value exists and does not start with a null character (ghost data)
		my $test = substr($x,0,1000); # take a sample of the string so as to speed up detection
		debug($data, "using test substring: $test", 4);

		$encoding = Encode::Detect::Detector::detect($test);	# try to detect the character encoding using Mozilla's universal charset detector
		my $decoded = $encoding? eval { decode($encoding, $test, Encode::FB_CROAK); } : undef;	# test the encoding detected

		if (!$decoded) { # if the encoding failed, try an alternate method
			debug($data, ($encoding? "Detected encoding $encoding failed" : "Failed to detect encoding")." with Encode::Detect::Detector::detect, trying another method.", 5);
			my $decoder = guess_encoding($test);
			unless (ref($decoder)) { debug($data, "Error decoding with guess_encoding(): $!", 5); }

			if (ref($decoder)) { 					$encoding = $decoder->mime_name; }  #$decoder->name .", ". $decoder->mime_name; }
			elsif ($decoder =~ /ambiguous between UTF/i) {		$encoding = "utf8"; debug($data, "Ambiguous encoding; trying utf8...", 5); }
			else {							$encoding = "raw"; debug($data, "Encoding detection failed; defaulted to raw binary", 5); }

			if ($encoding and $encoding ne "raw") {
				$decoded = eval { decode($encoding, $test, Encode::FB_CROAK); };
				debug($data, ((defined $decoded)? "Successfully decoded $encoding with guess_encoding()" : "Detected encoding $encoding failed with guess_encoding(), setting to raw binary"), 5);
				$encoding = (defined $decoded)? $encoding : "raw"; }}
		else { debug($data, "Successfully decoded $encoding using Encode::Detect::Detector::detect", 5); }

		# test against the DBI description
			$dbi_desc = DBI::data_string_desc($x); debug($data, "Testing against DBI description: $dbi_desc",5);
			$chars = coerce($1, "num", "zero") if $dbi_desc =~ /\s(\d+)\s*?characters/i;
			$bytes = coerce($1, "num", "zero") if $dbi_desc =~ /\s(\d+)\s*?bytes/i;
			$wide = $bytes > $chars;
			debug($data, (($encoding =~ /ascii/i and ($dbi_desc =~ /non-ascii/i or $wide))? "Encoding $encoding disagrees with DBI detection, setting to UTF8" : "Detected encoding $encoding agrees with DBI ASCII detection"), 5);
			$encoding = ($encoding =~ /ascii/i and $dbi_desc =~ /non-ascii/i)? "utf8" : $encoding;
			#debug($data, (($encoding =~ /utf\-?8/i and $dbi_desc =~ /UTF8 off/i)? "Encoding $encoding disagrees with DBI detection, setting to raw binary" : "Detected encoding $encoding agrees with DBI UTF8 detection"), 5);
			#$encoding = ($encoding =~ /utf\-?8/i and $dbi_desc =~ /UTF8 off/i)? "raw" : $encoding;

		# file type detector
		if ($test and !$decoded) {
			my $ft = new File::Type or $data->{error} .= $!;
			$mime = $ft->checktype_contents($test); }

		debug($data, "encoding: $encoding, content type: $mime, length: ".length($x).", ".($wide? "wide characters, ":"")." value: ".(($encoding =~ /(?:text|ascii|utf)/i)? substr($x,0,1000) : "unprintable binary"),5);

		if ($data->{debug_level} and $data->{debug_level} > 4) {
			my $hstr = ""; my $bstr = ""; my $nstr = "";
			my $str = substr($x,0,100);
			foreach my $c (split(//, $str)) {
				$nstr .= charinfo(ord($c))->{name} . " ";
				my @octets = unpack 'C*', encode_utf8($c);
				$hstr .= (join ' ', map { sprintf '%02X', $_ } @octets) . " ";
				$bstr .= (join ' ', map { sprintf '%08b', $_ } @octets) . " "; }
			debug($data, "UTF hex value (first 100 chars): $hstr", 5);
			debug($data, "UTF bin value (first 100 chars): $bstr", 5);
			debug($data, "Unicode names (first 100 chars): $nstr", 5); }

		if ($encoding =~ /(?:text|ascii|utf\-?8)/i or $force_utf8) { # try to decode/upgrade text and octet strings, but not file blobs
			debug($data, "pre-decode: ".((length($x)>1000)? substr($x,0,1000)."<truncated>" : $x),5);
			if (my @matches = ($x =~ /([\xB2-\xFF])/gs)) { debug($data, "matched high characters: ".(map{ord($_)} @matches),5); }
			if (my @matches = ($x =~ /([^\x00-\xFF])/gs)) { debug($data, "matched wide characters: ".(map{ord($_)} @matches),5); }

			if ($x =~ /[^\x00-\xB1]/) { # if there are high characters, above ASCII range, decode as utf8
				$x = decode('utf8', $x, Encode::FB_PERLQQ) unless Encode::is_utf8($x, Encode::FB_PERLQQ); # treat string as utf8 format
				debug($data, "post-decode: ".((length($x)>1000)? substr($x,0,1000)."<truncated>" : $x),5);

				# use ZapCP1252 to fix CP1252 encoded bytes to valid UTF-8
				$x = fix_cp1252 $x;
				debug($data, "post-fix_cp1252: ".((length($x)>1000)? substr($x,0,1000)."<truncated>" : $x),5);

				# use Encoding::FixLatin to force CP1252 and ISO8859-1 encoded bytes to UTF-8
				$x = fix_latin($x, ascii_hex => 0);
				debug($data, "post-fix_latin: ".((length($x)>1000)? substr($x,0,1000)."<truncated>" : $x),5);

				# strip out wide characters remaining that go beyond a byte, replacing multi-byte characters with a quote
				#$x =~ s/([\x300-\x337])([\x200-\x227])/chr((ord($1)-192)*64+(ord($2)-128))/gis;
				#$x =~ s/[^\x00-\xFF]/\"/gis;
				#debug($data, "post-strip_wide: ".((length($x)>1000)? substr($x,0,1000)."<truncated>" : $x),4);

				debug($data, "Decoded string to UTF8",3); }
			else { # otherwise, simply upgrade the ASCII to utf8 identification
				my $octets = utf8::upgrade($x); debug($data, "Upgraded string idenfication to UTF8",5); }

			debug($data, "Stripping any non-printable characters from string (".$x.")...",4);
			$x = coerce($x, "printable", "blank"); # strip any control characters, nulls, etc., from text strings
			debug($data, "Final value: (".$x.")",4); }

		if ($data->{debug_level} and $data->{debug_level} > 4) {
			my $hstr = ""; my $bstr = ""; my $nstr = "";
			my $str = substr($x,0,100);
			foreach my $c (split(//, $str)) {
				$nstr .= charinfo(ord($c))->{name} . " ";
				my @octets = unpack 'C*', encode_utf8($c);
				$hstr .= (join ' ', map { sprintf '%02X', $_ } @octets) . " ";
				$bstr .= (join ' ', map { sprintf '%08b', $_ } @octets) . " "; }
			debug($data, "UTF hex value (first 100 chars): $hstr",5);
			debug($data, "UTF bin value (first 100 chars): $bstr",5);
			debug($data, "Unicode names (first 100 chars): $nstr",5); }

		# test by printing string to a filehandle if the content is large
		$encoding = print_test($x, $encoding) if $chars > 5000; }
	else { $x = ""; $encoding = "utf8"; debug($data, "Variable is empty or not defined; setting to blank string.", 3); }

	if ($encoding=~/raw/) { return ($ox, $encoding, length($x)); } else { return ($x, $encoding, length($x)); }}

sub decode_url {
	my ($str) = @_;
	$str =~ tr/+/ /;
	$str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/egis;
	return $str; }

sub encode_url {
    my ($str) = @_;
    $str =~ s/ /+/g;
    $str =~ s/([^A-Za-z0-9\+-])/sprintf("%%%02X", ord($1))/seg;
    return $str; }

sub print_test {
	my ($x, $encoding) = @_;
	my $err = ""; my $data = {};
	my $dbg = $encoding? debug($data, "Trying print test with $encoding", 4) : debug($data, "No encoding for print test; setting encoding to 'raw'", 4);

	return ":raw" unless $encoding;

	local $PerlIO::encoding::fallback = Encode::FB_DEFAULT|Encode::STOP_AT_PARTIAL;

	if (open(TEST, '>', '/dev/null')) {
		$dbg .= debug($data, "Successfully opened TEST filehandle", 4);

		my $test_encoding = ($encoding =~ /(?:text|ascii|utf\-?8)/i)? ":utf8" :
							($encoding !~ /(raw|BLOB)$/i)? ":raw:bytes:encoding($encoding)" : ":raw";
		$encoding = "";

		unless ($test_encoding eq ":utf8") {
			$dbg .= debug($data, "Trying set binmode with $test_encoding", 4);
			if (binmode( TEST, $test_encoding )) { $dbg .= debug($data, "Successfully set binmode using $test_encoding", 4); }
			else { $dbg .= debug($data, "Failed to set binmode using $test_encoding: $!; setting encoding to 'raw'", 3); close(TEST); return ":raw"; }}

		local $SIG{__DIE__} = 'DEFAULT';
		try { print TEST $x; }
		catch {
			$dbg .= debug($data, "Failed to output to TEST using $test_encoding: @_", 4);
			@_ = undef;
			close(TEST);
			$encoding = ":raw"; }
		finally {
			$dbg .= debug($data, (@_? "Failed to output to TEST using $test_encoding: @_" : "Successfully output to TEST using $test_encoding"), 4);
			@_ = undef;
			close (TEST);
			$encoding = $test_encoding; };}
	else { $dbg .= debug($data, "Failed to open TEST filehandle; setting encoding to 'raw'", 4); return ":raw"; }

	if ($encoding) { return $encoding; }
	else { $dbg .= debug($data, "Something went wrong with print test; setting encoding to 'raw'", 4); return ":raw"; }}

1;