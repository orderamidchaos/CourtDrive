package CourtDrive::Config;

=head1 NAME
CourtDrive Configuration Reader Module

=head2 SYNOPSIS
C<< use CourtDrive::Config qw(read_config); >>
C<< use constant CONFIG => read_config($config_file); >>

=head2 DESCRIPTION
Functions for dealing with configuration data.

=head2 AUTHOR
Thomas Anderson
tanderson@orderamidchaos.com

=head2 COPYRIGHT
Copyright 2023
=cut

# load perl modules and import symbols into the namespace
use Modern::Perl;
use JSON::XS		qw(decode_json);

# export public subroutine symbols
use Exporter 		qw(import);
our @EXPORT_OK = 	qw(read_config);

sub read_config {
	my ($config_file) = @_;												# pass in config file name
	my $config_text = do {
		if (-e $config_file) {
			if (open(my $fh, "<:encoding(UTF-8)", $config_file)) {		# open config file
				local $/;												# locally undefine the input record seperator
				<$fh>; }												# read in the entire file and return it
			else { die("Can't open config file: $!\n"); }}
		else { die("Config file $config_file does not exist.\n"); }};

	$config_text =~ s/([^#\n]*?)(#.*?)(\n|$)/$1/gis;					# remove comments
	$config_text =~ s/\s+(?=((\\[\\"]|[^\\"])*"(\\[\\"]|[^\\"])*")*(\\[\\"]|[^\\"])*$)//gis;	# remove spaces that aren't within quoted strings

	my $config_json = decode_json $config_text;							# deserialize the config object from the JSON source
	return $config_json; }

1;